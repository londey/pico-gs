//! Z-buffer tile cache — 4-way set-associative write-back cache.
//!
//! Matches the RTL `zbuf_tile_cache.sv` module.  Each cache line holds
//! one 4x4 tile of 16-bit Z values (16 words = 32 bytes).
//!
//! On a cache miss the fill source depends on the per-tile uninitialized
//! flag (`UninittedFlagArray`):
//! - **Uninitialized tile** (flag set): lazy-fill with `0x0000` (no SDRAM read).
//! - **Initialized tile** (flag clear): read 16 words from SDRAM.
//!
//! Dirty lines are written back to SDRAM on eviction.
//! Invalidation clears all valid bits without write-back (used on
//! `FB_CONFIG` writes when the Z-buffer is reconfigured).

// Spec-ref: unit_012_zbuf_tile_cache.md `cdf298cadd037658` 2026-04-04

use crate::uninit_flags::UninittedFlagArray;
use gs_memory::GpuMemory;

/// Number of ways per set.
const NUM_WAYS: usize = 4;

/// Number of sets.
const NUM_SETS: usize = 32;

/// Words per cache line (4x4 tile).
const LINE_WORDS: usize = 16;

/// Backing-store context passed to cache read/write operations.
pub struct ZbufContext<'a> {
    /// Per-tile uninitialized flags (checked on miss for lazy-fill decision).
    pub uninit_flags: &'a UninittedFlagArray,

    /// SDRAM backing store.
    pub memory: &'a mut GpuMemory,

    /// Z-buffer base register value (units of 256 words).
    pub z_base: u16,

    /// Framebuffer width log2.
    pub wl2: u8,
}

/// A single cache line: one 4x4 Z-buffer tile.
#[derive(Clone)]
struct CacheLine {
    /// Tile index (14-bit) stored as tag.
    tag: u16,
    /// Line contains valid data.
    valid: bool,
    /// Line has been written (needs write-back on eviction).
    dirty: bool,
    /// 4x4 Z values.
    data: [u16; LINE_WORDS],
}

impl Default for CacheLine {
    fn default() -> Self {
        Self {
            tag: 0,
            valid: false,
            dirty: false,
            data: [0; LINE_WORDS],
        }
    }
}

/// 4-way set-associative Z-buffer tile cache with pseudo-LRU eviction.
pub struct ZbufTileCache {
    /// Cache lines: `lines[set][way]`.
    lines: [[CacheLine; NUM_WAYS]; NUM_SETS],
    /// 3-bit pseudo-LRU state per set (binary tree).
    lru: [u8; NUM_SETS],
}

impl Default for ZbufTileCache {
    fn default() -> Self {
        Self::new()
    }
}

impl ZbufTileCache {
    /// Create a new empty cache (all lines invalid).
    pub fn new() -> Self {
        Self {
            lines: std::array::from_fn(|_| std::array::from_fn(|_| CacheLine::default())),
            lru: [0; NUM_SETS],
        }
    }

    /// Read a Z value at pixel coordinates `(x, y)`.
    ///
    /// On a cache miss, fills the line from SDRAM or lazy-fills with
    /// zeros if the Hi-Z metadata indicates the tile is uninitialized.
    pub fn read(&mut self, x: u32, y: u32, ctx: &mut ZbufContext<'_>) -> u16 {
        let (tile_idx, pixel_off) = tile_coords(x, y, ctx.wl2);
        let set = (tile_idx as usize) & (NUM_SETS - 1);

        // Check for hit.
        for way in 0..NUM_WAYS {
            if self.lines[set][way].valid && self.lines[set][way].tag == tile_idx {
                self.update_lru(set, way);
                return self.lines[set][way].data[pixel_off];
            }
        }

        // Miss — fill the line.
        let way = self.fill_line(set, tile_idx, ctx);
        self.update_lru(set, way);
        self.lines[set][way].data[pixel_off]
    }

    /// Write a Z value at pixel coordinates `(x, y)`.
    ///
    /// On a cache miss, allocates a line (evicting if necessary) and
    /// fills it before writing.
    pub fn write(&mut self, x: u32, y: u32, value: u16, ctx: &mut ZbufContext<'_>) {
        let (tile_idx, pixel_off) = tile_coords(x, y, ctx.wl2);
        let set = (tile_idx as usize) & (NUM_SETS - 1);

        // Check for hit.
        for way in 0..NUM_WAYS {
            if self.lines[set][way].valid && self.lines[set][way].tag == tile_idx {
                self.lines[set][way].data[pixel_off] = value;
                self.lines[set][way].dirty = true;
                self.update_lru(set, way);
                return;
            }
        }

        // Miss — fill then write.
        let way = self.fill_line(set, tile_idx, ctx);
        self.lines[set][way].data[pixel_off] = value;
        self.lines[set][way].dirty = true;
        self.update_lru(set, way);
    }

    /// Flush all dirty lines to SDRAM (write-back).
    pub fn flush(&mut self, memory: &mut GpuMemory, z_base: u16) {
        for set in &mut self.lines {
            for line in set.iter_mut().filter(|l| l.valid && l.dirty) {
                write_back_line(line, memory, z_base);
                line.dirty = false;
            }
        }
    }

    /// Invalidate all cache lines without write-back.
    ///
    /// Used on `FB_CONFIG` write when the entire Z-buffer is being
    /// reconfigured and old data is stale.
    pub fn invalidate(&mut self) {
        for set in &mut self.lines {
            for line in set {
                line.valid = false;
            }
        }
    }

    /// Fill a cache line on miss: evict victim if necessary, then fill.
    ///
    /// Returns the way index of the newly filled line.
    fn fill_line(&mut self, set: usize, tile_idx: u16, ctx: &mut ZbufContext<'_>) -> usize {
        let way = self.find_invalid_or_victim(set);

        // Evict dirty victim.
        if self.lines[set][way].valid && self.lines[set][way].dirty {
            write_back_line(&self.lines[set][way], ctx.memory, ctx.z_base);
        }

        // Fill: check uninitialized flag for lazy-fill decision.
        // tile_idx encodes the tile position; the flag index is the same value.
        if ctx.uninit_flags.is_set(tile_idx as usize) {
            // Lazy-fill: tile is uninitialized, fill with zeros (no SDRAM read).
            self.lines[set][way].data = [0u16; LINE_WORDS];
        } else {
            // Read 16 words from SDRAM.
            let base_word = (ctx.z_base as usize) << 8;
            let tile_base = base_word + (tile_idx as usize) * LINE_WORDS;
            for i in 0..LINE_WORDS {
                self.lines[set][way].data[i] = ctx.memory.sdram[tile_base + i];
            }
        }

        self.lines[set][way].tag = tile_idx;
        self.lines[set][way].valid = true;
        self.lines[set][way].dirty = false;
        way
    }

    /// Find an invalid way in the set, or select a victim via pseudo-LRU.
    fn find_invalid_or_victim(&self, set: usize) -> usize {
        for way in 0..NUM_WAYS {
            if !self.lines[set][way].valid {
                return way;
            }
        }
        self.lru_victim(set)
    }

    /// Select eviction victim using 3-bit pseudo-LRU binary tree.
    ///
    /// Tree structure (same as RTL `zbuf_tile_cache.sv`):
    /// - bit 2: left (ways 0,1) vs right (ways 2,3)
    /// - bit 1: way 0 vs way 1
    /// - bit 0: way 2 vs way 3
    fn lru_victim(&self, set: usize) -> usize {
        let s = self.lru[set];
        if s & 0b100 == 0 {
            if s & 0b010 == 0 {
                0
            } else {
                1
            }
        } else if s & 0b001 == 0 {
            2
        } else {
            3
        }
    }

    /// Update pseudo-LRU state after accessing a way.
    fn update_lru(&mut self, set: usize, way: usize) {
        let s = &mut self.lru[set];
        match way {
            0 => *s |= 0b110,
            1 => *s = (*s | 0b100) & !0b010,
            2 => *s = (*s & !0b100) | 0b001,
            3 => *s &= !0b101,
            _ => unreachable!(),
        }
    }
}

/// Write back a cache line's 16 words to SDRAM.
fn write_back_line(line: &CacheLine, memory: &mut GpuMemory, z_base: u16) {
    let base_word = (z_base as usize) << 8;
    let tile_base = base_word + (line.tag as usize) * LINE_WORDS;
    for i in 0..LINE_WORDS {
        memory.sdram[tile_base + i] = line.data[i];
    }
}

/// Compute tile index and pixel offset from pixel coordinates.
///
/// Returns `(tile_idx, pixel_off)` where:
/// - `tile_idx` = `(block_y << (wl2-2)) | block_x` (14-bit)
/// - `pixel_off` = `local_y * 4 + local_x` (0..15)
fn tile_coords(x: u32, y: u32, wl2: u8) -> (u16, usize) {
    let block_x = x >> 2;
    let block_y = y >> 2;
    let local_x = (x & 3) as usize;
    let local_y = (y & 3) as usize;
    let tile_cols_log2 = wl2 as u32 - 2;
    let tile_idx = ((block_y << tile_cols_log2) | block_x) as u16;
    let pixel_off = local_y * 4 + local_x;
    (tile_idx, pixel_off)
}
