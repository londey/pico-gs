//! Color-buffer tile cache — 4-way set-associative write-back cache
//! with per-tile uninitialized flag tracking.
//!
//! This crate models the RTL `color_tile_cache.sv` module including
//! the internal uninit flag EBR.
//! On a cache miss, the per-tile uninit flag selects between lazy-fill
//! with `0x0000` (no SDRAM read) and a 16-word burst read from SDRAM.
//! Dirty lines are written back to SDRAM on eviction.
//! `flush()` writes back all dirty lines without invalidating; the
//! lines remain valid and absorb post-flush traffic.
//! `invalidate()` drops all valid+dirty bits and resets every uninit
//! flag to `true` so first-touch writes to a freshly bound render
//! target lazy-fill with zeros instead of reading stale SDRAM data.
//!
//! See UNIT-013 (Color-buffer tile cache).

// Spec-ref: unit_013_color_tile_cache.md

use gs_memory::GpuMemory;

/// Number of ways per set.
pub const NUM_WAYS: usize = 4;

/// Number of sets (5-bit set index).
pub const NUM_SETS: usize = 32;

/// Words per cache line (4x4 tile of RGB565 pixels).
pub const LINE_WORDS: usize = 16;

/// Total tiles tracked by the uninit-flag array (covers a 512x512
/// surface = 128x128 tiles = 16,384 entries).
const NUM_TILES: usize = 16384;

/// Lazy-fill value for an uninitialized tile (RGB565 black).
const LAZYFILL_VALUE: u16 = 0x0000;

/// Backing-store context passed to cache read/write operations.
///
/// Bundles the SDRAM model and the framebuffer configuration needed
/// for tiled address calculation when the cache fills or evicts a
/// line.
pub struct ColorCacheContext<'a> {
    /// SDRAM backing store.
    pub memory: &'a mut GpuMemory,

    /// Color-buffer base register value (units of 256 16-bit words).
    pub color_base: u16,

    /// Framebuffer width log2 (e.g. 9 for a 512-wide surface).
    pub wl2: u8,
}

/// A single cache line: one 4x4 color tile.
#[derive(Clone)]
struct CacheLine {
    /// 9-bit tile-index tag (`tile_idx[13:5]`), stored zero-extended.
    tag: u16,
    /// Line contains valid data.
    valid: bool,
    /// Line has been written (needs write-back on eviction).
    dirty: bool,
    /// 4x4 RGB565 pixel values (row-major).
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

/// 4-way set-associative color-buffer tile cache with pseudo-LRU
/// eviction, lazy-fill, and write-back.
///
/// Owns the per-tile uninit flag array internally as a plain
/// `[bool; 16384]`.
/// The flag array models the RTL uninit flag EBR (UNIT-013) and stays
/// crate-local until DD-043 promotes a shared implementation to
/// `gs-twin-core`.
pub struct ColorTileCache {
    /// Cache lines: `lines[set][way]`.
    lines: [[CacheLine; NUM_WAYS]; NUM_SETS],
    /// 3-bit pseudo-LRU state per set (binary tree).
    lru: [u8; NUM_SETS],
    /// Per-tile uninitialized flags (`true` = lazy-fill on miss).
    uninit_flags: [bool; NUM_TILES],
}

impl Default for ColorTileCache {
    fn default() -> Self {
        Self::new()
    }
}

impl ColorTileCache {
    /// Create a new empty cache (all lines invalid, all uninit flags
    /// set).
    pub fn new() -> Self {
        Self {
            lines: std::array::from_fn(|_| std::array::from_fn(|_| CacheLine::default())),
            lru: [0; NUM_SETS],
            uninit_flags: [true; NUM_TILES],
        }
    }

    /// Read the RGB565 pixel at `(tile_idx, pixel_off)`.
    ///
    /// On a cache miss the line is filled from SDRAM, or lazy-filled
    /// with `0x0000` if the per-tile uninit flag is set.
    ///
    /// # Arguments
    ///
    /// * `tile_idx` - 14-bit tile index.
    /// * `pixel_off` - Pixel offset within the tile (0..16).
    /// * `ctx` - SDRAM + framebuffer-config context.
    pub fn read(
        &mut self,
        tile_idx: u32,
        pixel_off: usize,
        ctx: &mut ColorCacheContext<'_>,
    ) -> u16 {
        debug_assert!(pixel_off < LINE_WORDS, "pixel_off out of range");
        let set = Self::set_of(tile_idx);
        let tag = Self::tag_of(tile_idx);

        let way = if let Some(way) = self.find_way(set, tag) {
            way
        } else {
            let way = self.lru_victim_or_invalid(set);
            self.evict(set, way, ctx);
            self.fill(set, way, tile_idx, ctx);
            way
        };

        self.update_lru(set, way);
        self.lines[set][way].data[pixel_off]
    }

    /// Write the RGB565 pixel at `(tile_idx, pixel_off)`.
    ///
    /// On a cache miss the line is allocated (evicting if necessary)
    /// and filled before the write.
    /// Sets the line's dirty bit and clears the per-tile uninit flag
    /// (the tile is no longer empty).
    ///
    /// # Arguments
    ///
    /// * `tile_idx` - 14-bit tile index.
    /// * `pixel_off` - Pixel offset within the tile (0..16).
    /// * `data` - RGB565 pixel value.
    /// * `ctx` - SDRAM + framebuffer-config context.
    pub fn write(
        &mut self,
        tile_idx: u32,
        pixel_off: usize,
        data: u16,
        ctx: &mut ColorCacheContext<'_>,
    ) {
        debug_assert!(pixel_off < LINE_WORDS, "pixel_off out of range");
        let set = Self::set_of(tile_idx);
        let tag = Self::tag_of(tile_idx);

        let way = if let Some(way) = self.find_way(set, tag) {
            way
        } else {
            let way = self.lru_victim_or_invalid(set);
            self.evict(set, way, ctx);
            self.fill(set, way, tile_idx, ctx);
            way
        };

        self.lines[set][way].data[pixel_off] = data;
        self.lines[set][way].dirty = true;
        self.uninit_flags[tile_idx as usize] = false;
        self.update_lru(set, way);
    }

    /// Write back every dirty line to SDRAM and clear the dirty bits.
    ///
    /// Lines remain valid after the flush so subsequent accesses still
    /// hit and absorb traffic.
    ///
    /// # Arguments
    ///
    /// * `ctx` - SDRAM + framebuffer-config context.
    pub fn flush(&mut self, ctx: &mut ColorCacheContext<'_>) {
        for set_idx in 0..NUM_SETS {
            self.flush_set(set_idx, ctx);
        }
    }

    /// Write back any dirty lines in the given set and clear their
    /// dirty bits.  Lines remain valid after the flush.
    fn flush_set(&mut self, set_idx: usize, ctx: &mut ColorCacheContext<'_>) {
        for way in 0..NUM_WAYS {
            let line = &self.lines[set_idx][way];
            if !(line.valid && line.dirty) {
                continue;
            }
            self.write_back_line(set_idx, way, ctx);
            self.lines[set_idx][way].dirty = false;
        }
    }

    /// Drop all valid+dirty bits and reset every uninit flag to `true`.
    ///
    /// No SDRAM access is performed.
    /// Models the RTL `INVALIDATE_TRIGGER` path used by the driver
    /// after retargeting `FB_CONFIG.COLOR_BASE` to a new framebuffer.
    pub fn invalidate(&mut self) {
        for set in &mut self.lines {
            for line in set {
                line.valid = false;
                line.dirty = false;
            }
        }
        self.uninit_flags.fill(true);
    }

    /// Return whether the per-tile uninit flag is set for `tile_idx`.
    ///
    /// # Arguments
    ///
    /// * `tile_idx` - 14-bit tile index.
    #[must_use]
    pub fn is_uninit(&self, tile_idx: u32) -> bool {
        self.uninit_flags[tile_idx as usize]
    }

    // ── private helpers ────────────────────────────────────────────

    /// Set index from the tile index (`tile_idx[4:0]`, 5 bits).
    fn set_of(tile_idx: u32) -> usize {
        (tile_idx as usize) & (NUM_SETS - 1)
    }

    /// Tag from the tile index (`tile_idx[13:5]`, 9 bits, zero-extended).
    fn tag_of(tile_idx: u32) -> u16 {
        ((tile_idx >> 5) & 0x1FF) as u16
    }

    /// Find a hit way in the given set.
    fn find_way(&self, set: usize, tag: u16) -> Option<usize> {
        (0..NUM_WAYS).find(|&way| self.lines[set][way].valid && self.lines[set][way].tag == tag)
    }

    /// Pick an invalid way if available, else the pseudo-LRU victim.
    fn lru_victim_or_invalid(&self, set: usize) -> usize {
        (0..NUM_WAYS)
            .find(|&way| !self.lines[set][way].valid)
            .unwrap_or_else(|| self.lru_victim(set))
    }

    /// Select eviction victim using the 3-bit pseudo-LRU binary tree.
    ///
    /// Tree structure (matches RTL):
    /// - bit 2: left subtree (ways 0,1) when 0; right (ways 2,3) when 1
    /// - bit 1: way 0 when 0; way 1 when 1
    /// - bit 0: way 2 when 0; way 3 when 1
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

    /// Update pseudo-LRU state after touching the given way.
    ///
    /// Pointers are flipped to point *away* from the just-accessed way
    /// at every level of the tree, so the victim path naturally
    /// migrates to the least recently touched leaf.
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

    /// Evict the line at `(set, way)` if it is valid and dirty.
    fn evict(&mut self, set: usize, way: usize, ctx: &mut ColorCacheContext<'_>) {
        if self.lines[set][way].valid && self.lines[set][way].dirty {
            self.write_back_line(set, way, ctx);
        }
        self.lines[set][way].valid = false;
        self.lines[set][way].dirty = false;
    }

    /// Fill `(set, way)` with the tile identified by `tile_idx`.
    ///
    /// Reads 16 words from SDRAM via tiled addressing, or lazy-fills
    /// with `0x0000` when the per-tile uninit flag is set.
    fn fill(&mut self, set: usize, way: usize, tile_idx: u32, ctx: &mut ColorCacheContext<'_>) {
        let tag = Self::tag_of(tile_idx);

        if self.uninit_flags[tile_idx as usize] {
            // Lazy-fill: tile has never been written; no SDRAM read.
            self.lines[set][way].data = [LAZYFILL_VALUE; LINE_WORDS];
        } else {
            // Burst-fill from SDRAM (16 words via tiled addressing).
            let (base_x, base_y) = tile_base_xy(tile_idx, ctx.wl2);
            for off in 0..LINE_WORDS {
                let (px, py) = pixel_xy(base_x, base_y, off);
                self.lines[set][way].data[off] =
                    ctx.memory.read_tiled(ctx.color_base, ctx.wl2, px, py);
            }
        }

        self.lines[set][way].tag = tag;
        self.lines[set][way].valid = true;
        self.lines[set][way].dirty = false;
    }

    /// Burst-write the cache line at `(set, way)` to SDRAM.
    ///
    /// Reconstructs the tile index from the line's tag plus its set
    /// index, then writes the 16 words via tiled addressing.
    fn write_back_line(&self, set: usize, way: usize, ctx: &mut ColorCacheContext<'_>) {
        let tile_idx = ((self.lines[set][way].tag as u32) << 5) | (set as u32);
        let (base_x, base_y) = tile_base_xy(tile_idx, ctx.wl2);
        for off in 0..LINE_WORDS {
            let (px, py) = pixel_xy(base_x, base_y, off);
            ctx.memory.write_tiled(
                ctx.color_base,
                ctx.wl2,
                px,
                py,
                self.lines[set][way].data[off],
            );
        }
    }
}

/// Compute the absolute pixel `(x, y)` for a 4x4 tile-local offset.
fn pixel_xy(base_x: u32, base_y: u32, off: usize) -> (u32, u32) {
    let lx = (off & 3) as u32;
    let ly = (off >> 2) as u32;
    (base_x + lx, base_y + ly)
}

/// Compute the top-left pixel coordinate of a tile.
fn tile_base_xy(tile_idx: u32, wl2: u8) -> (u32, u32) {
    let tile_cols_log2 = wl2 as u32 - 2;
    let tile_cols_mask = (1u32 << tile_cols_log2) - 1;
    let block_x = tile_idx & tile_cols_mask;
    let block_y = tile_idx >> tile_cols_log2;
    (block_x << 2, block_y << 2)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 512-wide framebuffer at color_base = 0.
    const WL2: u8 = 9;
    const COLOR_BASE: u16 = 0;

    fn make_ctx(memory: &mut GpuMemory) -> ColorCacheContext<'_> {
        ColorCacheContext {
            memory,
            color_base: COLOR_BASE,
            wl2: WL2,
        }
    }

    /// Compute the tile index for pixel (x, y) at WL2.
    fn tile_idx_of(x: u32, y: u32) -> u32 {
        let tile_cols_log2 = WL2 as u32 - 2;
        ((y >> 2) << tile_cols_log2) | (x >> 2)
    }

    /// Compute the pixel offset within a tile for pixel (x, y).
    fn pixel_off_of(x: u32, y: u32) -> usize {
        ((y & 3) * 4 + (x & 3)) as usize
    }

    #[test]
    fn new_has_all_uninit_flags_set() {
        let cache = ColorTileCache::new();
        for idx in 0..NUM_TILES as u32 {
            assert!(
                cache.is_uninit(idx),
                "tile {idx} should be uninit after new()"
            );
        }
    }

    #[test]
    fn new_has_no_valid_lines() {
        let cache = ColorTileCache::new();
        for set in &cache.lines {
            for line in set {
                assert!(!line.valid);
                assert!(!line.dirty);
            }
        }
    }

    #[test]
    fn first_write_does_not_read_sdram() {
        // Seed SDRAM at the tile address with a sentinel pattern; if
        // the cache reads SDRAM during fill, the pattern would leak
        // into the unwritten pixels of the tile.  After a single
        // pixel write we flush and verify only the written pixel
        // changed in SDRAM — every other pixel is `LAZYFILL_VALUE`,
        // proving the fill path took the lazy-fill branch.
        let mut memory = GpuMemory::new();
        let tile_x = 4;
        let tile_y = 8;
        let pixel_x = tile_x + 1;
        let pixel_y = tile_y + 2;
        let tile_idx = tile_idx_of(pixel_x, pixel_y);
        let off = pixel_off_of(pixel_x, pixel_y);

        // Pre-seed every word in the tile with a sentinel so we can
        // detect any SDRAM read.
        for ly in 0..4u32 {
            for lx in 0..4u32 {
                memory.write_tiled(COLOR_BASE, WL2, tile_x + lx, tile_y + ly, 0xBEEF);
            }
        }

        let mut cache = ColorTileCache::new();
        {
            let mut ctx = make_ctx(&mut memory);
            cache.write(tile_idx, off, 0x1234, &mut ctx);
            cache.flush(&mut ctx);
        }

        // The written pixel must be in SDRAM with the new value.
        assert_eq!(memory.read_tiled(COLOR_BASE, WL2, pixel_x, pixel_y), 0x1234);
        // Every other pixel in the tile must be the lazy-fill value
        // (i.e. SDRAM was *not* read into the cache during fill).
        for off in 0..LINE_WORDS {
            let (px, py) = pixel_xy(tile_x, tile_y, off);
            if (px, py) == (pixel_x, pixel_y) {
                continue;
            }
            let observed = memory.read_tiled(COLOR_BASE, WL2, px, py);
            assert_eq!(
                observed, LAZYFILL_VALUE,
                "pixel ({px},{py}) should be lazy-filled, got 0x{observed:04X}",
            );
        }
    }

    #[test]
    fn write_then_read_returns_written_value() {
        let mut memory = GpuMemory::new();
        let mut cache = ColorTileCache::new();
        let mut ctx = make_ctx(&mut memory);

        let tile_idx = tile_idx_of(20, 20);
        let off = pixel_off_of(20, 20);

        cache.write(tile_idx, off, 0xABCD, &mut ctx);
        let read_back = cache.read(tile_idx, off, &mut ctx);
        assert_eq!(read_back, 0xABCD);
    }

    #[test]
    fn write_clears_uninit_flag() {
        let mut memory = GpuMemory::new();
        let mut cache = ColorTileCache::new();
        let mut ctx = make_ctx(&mut memory);

        let tile_idx = tile_idx_of(8, 12);
        assert!(cache.is_uninit(tile_idx));

        cache.write(tile_idx, 0, 0x1111, &mut ctx);
        assert!(!cache.is_uninit(tile_idx));
    }

    #[test]
    fn flush_writes_back_dirty_lines_and_clears_dirty_bit() {
        let mut memory = GpuMemory::new();
        let mut cache = ColorTileCache::new();

        let tile_idx = tile_idx_of(40, 60);
        let off = pixel_off_of(40, 60);
        {
            let mut ctx = make_ctx(&mut memory);
            cache.write(tile_idx, off, 0x4242, &mut ctx);
        }

        // Before flush, SDRAM has not been updated yet (cache is dirty).
        // (Lazy-fill leaves SDRAM untouched, so read 0xBEEF would not
        // be definitive — instead, mutate SDRAM directly to a sentinel
        // to detect a write-back.)
        memory.write_tiled(COLOR_BASE, WL2, 40, 60, 0xDEAD);

        {
            let mut ctx = make_ctx(&mut memory);
            cache.flush(&mut ctx);
        }

        // Flush must have written 0x4242 back to SDRAM.
        assert_eq!(memory.read_tiled(COLOR_BASE, WL2, 40, 60), 0x4242);

        // Dirty bits cleared, lines remain valid.
        let set = ColorTileCache::set_of(tile_idx);
        let tag = ColorTileCache::tag_of(tile_idx);
        let way = cache
            .find_way(set, tag)
            .expect("line should still be valid");
        assert!(!cache.lines[set][way].dirty);
        assert!(cache.lines[set][way].valid);
    }

    #[test]
    fn invalidate_drops_valid_dirty_and_resets_uninit_flags() {
        let mut memory = GpuMemory::new();
        let mut cache = ColorTileCache::new();

        let tile_idx = tile_idx_of(16, 16);
        let off = pixel_off_of(16, 16);
        {
            let mut ctx = make_ctx(&mut memory);
            cache.write(tile_idx, off, 0x9999, &mut ctx);
        }
        assert!(!cache.is_uninit(tile_idx));

        cache.invalidate();

        // All lines invalid + clean.
        for set in &cache.lines {
            for line in set {
                assert!(!line.valid);
                assert!(!line.dirty);
            }
        }
        // Uninit flags reset to all-true.
        for idx in 0..NUM_TILES as u32 {
            assert!(cache.is_uninit(idx));
        }

        // Subsequent read misses (line is invalid) and lazy-fills with
        // zeros, so we read 0x0000 even though SDRAM still holds the
        // pre-invalidate write that never got flushed.
        let mut ctx = make_ctx(&mut memory);
        let v = cache.read(tile_idx, off, &mut ctx);
        assert_eq!(v, LAZYFILL_VALUE);
    }

    #[test]
    fn pseudo_lru_evicts_way3_after_writing_0_2_1() {
        // Pick four tile indices that map to the same set (set 0) but
        // have distinct tags.  set = tile_idx[4:0], tag = tile_idx[13:5].
        // Use tile_idx = 0, 32, 64, 96, 128 (set 0, tags 0..=4).
        let mut memory = GpuMemory::new();
        let mut cache = ColorTileCache::new();
        let mut ctx = make_ctx(&mut memory);

        // Write four distinct tiles to set 0 — they fill ways 0, 1, 2, 3
        // in the order they are first inserted (find_way returns the
        // first invalid way, which scans 0..4).
        cache.write(0, 0, 0xAA00, &mut ctx); // way 0
        cache.write(32, 0, 0xAA01, &mut ctx); // way 1
        cache.write(64, 0, 0xAA02, &mut ctx); // way 2
        cache.write(96, 0, 0xAA03, &mut ctx); // way 3

        // Touch ways 0, 2, 1 in that order (writes update LRU).
        cache.write(0, 0, 0xBB00, &mut ctx); // way 0
        cache.write(64, 0, 0xBB02, &mut ctx); // way 2
        cache.write(32, 0, 0xBB01, &mut ctx); // way 1

        // Now insert a 5th tile in the same set — way 3 should be the
        // pseudo-LRU victim because it has been least recently touched.
        cache.write(128, 0, 0xCC04, &mut ctx); // evicts some way

        // The new line must occupy way 3 (where tile 96 used to live).
        let set = ColorTileCache::set_of(128);
        let tag_new = ColorTileCache::tag_of(128);
        let tag_evicted = ColorTileCache::tag_of(96);
        let way_new = cache
            .find_way(set, tag_new)
            .expect("new line must be present");
        assert_eq!(way_new, 3, "way 3 should be the LRU victim");
        assert!(
            cache.find_way(set, tag_evicted).is_none(),
            "tile 96 (way 3) must have been evicted"
        );
    }
}
