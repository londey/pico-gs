// Spec-ref: unit_011.03_index_cache.md
#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]

//! Index cache for the INDEXED8_2X2 texture pipeline (UNIT-011.03).
//!
//! Per-sampler direct-mapped cache that stores 8-bit palette indices at half
//! the apparent texture resolution.
//! Each cache line covers a 4×4 block of index entries (16 bytes total),
//! corresponding to an 8×8 apparent-texel area.
//!
//! # Cache Geometry
//!
//! - 32 sets × 1 way × 16 indices per line = 512 index entries per sampler
//! - 8-bit raw index per entry (no decoding — palette lookup happens in UNIT-011.06)
//! - EBR primitive: one DP16KD in 2048×9 mode per sampler
//!
//! # Address Decomposition
//!
//! For an incoming index-resolution coordinate `(u_idx, v_idx)`:
//!
//! ```text
//! block_x = u_idx >> 2          // 4×4 index block column
//! block_y = v_idx >> 2          // 4×4 index block row
//! set     = block_x[4:0] ^ block_y[4:0]   // XOR-folded 5-bit set index
//! line_offset = (v_idx[1:0] << 2) | u_idx[1:0]
//!                                // 4-bit row-major offset in the 4×4 line
//! tag     = (tex_base, block_x, block_y)
//! ```
//!
//! XOR set indexing distributes spatially adjacent index blocks across
//! different sets, preventing systematic aliasing for row-major access patterns.
//! The tag carries the full `(block_x, block_y)` because two distinct blocks
//! can XOR-fold to the same set (e.g. `(0,0)` and `(1,1)`); storing only the
//! upper bits would alias every small-texture access pair that shares a set.
//!
//! # Replacement and Invalidation
//!
//! Direct-mapped (one way per set) — a miss always overwrites the resident
//! line in the addressed set, no replacement policy required.
//! `invalidate()` clears every valid bit in a single pass and is invoked by
//! UNIT-003 on `TEXn_CFG` writes.
//!
//! See: UNIT-011.03 (Index Cache), UNIT-011 (Texture Sampler), REQ-003.08.

// ── Cache geometry constants ────────────────────────────────────────────────

/// Number of cache sets (5-bit XOR-folded index).
pub const NUM_SETS: usize = 32;

/// Number of ways per set (direct-mapped).
pub const NUM_WAYS: usize = 1;

/// Number of 8-bit indices per cache line (4×4 index block).
pub const INDICES_PER_LINE: usize = 16;

// ── Cache tag ───────────────────────────────────────────────────────────────

/// Cache tag identifying a 4×4 index block within a texture.
///
/// XOR-folded set indexing maps multiple `(block_x, block_y)` pairs onto the
/// same set, so the tag carries the full block coordinates (alongside the
/// texture base) to disambiguate them.
/// Storing only the upper bits would collapse pairs like `(0,0)` and `(1,1)`
/// to identical tags whenever both coordinates sit below the 5-bit fold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct CacheTag {
    /// Texture base address (lower 16 bits of `tex_base[15:0]`, in u16 words).
    tex_base_lo: u16,

    /// Full `block_x` coordinate of the cached 4×4 index block.
    block_x: u32,

    /// Full `block_y` coordinate of the cached 4×4 index block.
    block_y: u32,
}

impl CacheTag {
    /// Construct a tag from base address and full block coordinates.
    fn new(tex_base: u32, block_x: u32, block_y: u32) -> Self {
        Self {
            tex_base_lo: (tex_base & 0xFFFF) as u16,
            block_x,
            block_y,
        }
    }
}

// ── Cache line ──────────────────────────────────────────────────────────────

/// One direct-mapped cache line: tag + valid bit + 16 raw index bytes.
#[derive(Debug, Clone, Copy)]
struct CacheLine {
    /// Tag identifying the cached 4×4 index block.
    tag: CacheTag,

    /// Valid bit — cleared on `invalidate`, set on `fill_line`.
    valid: bool,

    /// 16 raw 8-bit palette indices in row-major order within the 4×4 block.
    indices: [u8; INDICES_PER_LINE],
}

impl Default for CacheLine {
    fn default() -> Self {
        Self {
            tag: CacheTag::default(),
            valid: false,
            indices: [0u8; INDICES_PER_LINE],
        }
    }
}

// ── IndexCache ──────────────────────────────────────────────────────────────

/// Per-sampler direct-mapped index cache.
///
/// Models the bit-accurate behavior of the `texture_index_cache.sv` RTL
/// module: XOR-folded 5-bit set indexing, single-way storage, 16-byte
/// cache-line fills sourced from an SDRAM burst, and full-cache invalidation
/// on `TEXn_CFG` writes.
#[derive(Debug, Clone)]
pub struct IndexCache {
    /// 32 cache lines, one per set.
    lines: [CacheLine; NUM_SETS],

    /// Texture base address currently associated with this sampler, in u16
    /// words.
    /// Used to compute the cache tag; updated externally and folded into the
    /// tag whenever a fill or lookup is performed.
    tex_base_words: u32,
}

impl Default for IndexCache {
    fn default() -> Self {
        Self::new()
    }
}

impl IndexCache {
    /// Create a new cache with all valid bits cleared and base address zero.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            lines: [CacheLine {
                tag: CacheTag {
                    tex_base_lo: 0,
                    block_x: 0,
                    block_y: 0,
                },
                valid: false,
                indices: [0u8; INDICES_PER_LINE],
            }; NUM_SETS],
            tex_base_words: 0,
        }
    }

    /// Set the texture base address (in u16 words) used for tag construction.
    ///
    /// # Arguments
    ///
    /// * `tex_base_words` - Texture base address as a u16-word offset within
    ///   SDRAM.
    pub fn set_tex_base(&mut self, tex_base_words: u32) {
        self.tex_base_words = tex_base_words;
    }

    /// Compute the 5-bit XOR-folded set index for a `(u_idx, v_idx)` pair.
    ///
    /// # Arguments
    ///
    /// * `u_idx` - Horizontal index-resolution coordinate.
    /// * `v_idx` - Vertical index-resolution coordinate.
    ///
    /// # Returns
    ///
    /// Set index in `0..NUM_SETS`.
    #[must_use]
    pub fn set_index(u_idx: u16, v_idx: u16) -> usize {
        let block_x = (u_idx >> 2) as u32;
        let block_y = (v_idx >> 2) as u32;
        ((block_x & 0x1F) ^ (block_y & 0x1F)) as usize
    }

    /// Compute the 4-bit line offset within a 16-entry cache line.
    ///
    /// Indices within a 4×4 block are stored in row-major order:
    /// `offset = (v_idx[1:0] << 2) | u_idx[1:0]`.
    ///
    /// # Arguments
    ///
    /// * `u_idx` - Horizontal index-resolution coordinate.
    /// * `v_idx` - Vertical index-resolution coordinate.
    ///
    /// # Returns
    ///
    /// Line offset in `0..INDICES_PER_LINE`.
    #[must_use]
    pub fn line_offset(u_idx: u16, v_idx: u16) -> usize {
        (((v_idx & 0x3) << 2) | (u_idx & 0x3)) as usize
    }

    /// Look up the palette index at the given index-resolution coordinate.
    ///
    /// Returns `Some(idx)` on cache hit, `None` on miss.
    /// On miss the caller is responsible for performing an SDRAM burst read
    /// and calling [`fill_line`](Self::fill_line) before retrying.
    ///
    /// # Arguments
    ///
    /// * `u_idx` - Horizontal index-resolution coordinate.
    /// * `v_idx` - Vertical index-resolution coordinate.
    ///
    /// # Returns
    ///
    /// `Some(idx)` if the addressed line is resident; `None` otherwise.
    #[must_use]
    pub fn lookup(&self, u_idx: u16, v_idx: u16) -> Option<u8> {
        let set = Self::set_index(u_idx, v_idx);
        let block_x = (u_idx >> 2) as u32;
        let block_y = (v_idx >> 2) as u32;
        let tag = CacheTag::new(self.tex_base_words, block_x, block_y);

        let line = &self.lines[set];
        if line.valid && line.tag == tag {
            Some(line.indices[Self::line_offset(u_idx, v_idx)])
        } else {
            None
        }
    }

    /// Fill the cache line for the set that maps `(u_idx, v_idx)`.
    ///
    /// Writes a 16-byte SDRAM burst into the resident line, sets the valid
    /// bit, and updates the tag.
    /// Any previously cached line in the same set is overwritten.
    ///
    /// # Arguments
    ///
    /// * `u_idx` - Horizontal index-resolution coordinate that triggered the
    ///   fill.
    /// * `v_idx` - Vertical index-resolution coordinate that triggered the
    ///   fill.
    /// * `indices` - 16 raw 8-bit indices in row-major order within the 4×4
    ///   block (matching the SDRAM burst payload).
    pub fn fill_line(&mut self, u_idx: u16, v_idx: u16, indices: &[u8; INDICES_PER_LINE]) {
        let set = Self::set_index(u_idx, v_idx);
        let block_x = (u_idx >> 2) as u32;
        let block_y = (v_idx >> 2) as u32;
        let tag = CacheTag::new(self.tex_base_words, block_x, block_y);

        let line = &mut self.lines[set];
        line.tag = tag;
        line.valid = true;
        line.indices = *indices;
    }

    /// Clear all valid bits.
    ///
    /// Triggered by UNIT-003 on `TEXn_CFG` writes; the next access after
    /// invalidation is guaranteed to miss and trigger an SDRAM fill.
    pub fn invalidate(&mut self) {
        for line in &mut self.lines {
            line.valid = false;
        }
    }

    /// Number of currently valid cache lines (diagnostic).
    #[must_use]
    pub fn valid_line_count(&self) -> usize {
        self.lines.iter().filter(|l| l.valid).count()
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Cold cache: every lookup misses.
    #[test]
    fn cold_cache_misses() {
        let cache = IndexCache::new();
        assert!(cache.lookup(0, 0).is_none());
        assert!(cache.lookup(15, 23).is_none());
        assert!(cache.lookup(0xFFFF, 0xFFFF).is_none());
        assert_eq!(cache.valid_line_count(), 0);
    }

    /// Fill then lookup at the same coordinate returns the stored byte.
    #[test]
    fn fill_then_lookup_hit() {
        let mut cache = IndexCache::new();
        let mut payload = [0u8; INDICES_PER_LINE];
        for (i, slot) in payload.iter_mut().enumerate() {
            *slot = (0x10 + i) as u8;
        }
        cache.fill_line(0, 0, &payload);

        // Each of the 16 (u_idx, v_idx) positions in the 4×4 block hits its
        // corresponding payload byte.
        for v in 0u16..4 {
            for u in 0u16..4 {
                let expected = payload[IndexCache::line_offset(u, v)];
                assert_eq!(cache.lookup(u, v), Some(expected));
            }
        }
    }

    /// Different base addresses produce distinct tags — a fill at one base
    /// must not satisfy a lookup at another.
    #[test]
    fn base_addr_disambiguation() {
        let mut cache = IndexCache::new();
        let payload = [0xAAu8; INDICES_PER_LINE];

        cache.set_tex_base(0x1000);
        cache.fill_line(0, 0, &payload);
        assert_eq!(cache.lookup(0, 0), Some(0xAA));

        cache.set_tex_base(0x2000);
        assert!(
            cache.lookup(0, 0).is_none(),
            "different tex_base must miss the existing line"
        );
    }

    /// Small-texture XOR aliasing: blocks `(0,0)` and `(1,1)` fold to set 0
    /// but are physically distinct.
    /// A fill at one must not satisfy a lookup at the other, even though the
    /// `block_x >> 5` / `block_y >> 5` upper bits are both zero.
    /// This is the regression case for the cache-tag bug that masked the
    /// VER-012 INDEXED8_2X2 left-half rendering as black.
    #[test]
    fn small_texture_xor_aliased_blocks_do_not_collide() {
        let mut cache = IndexCache::new();
        let payload = [0xCDu8; INDICES_PER_LINE];

        // Block (0,0) → u_idx=0, v_idx=0; set 0.
        cache.fill_line(0, 0, &payload);
        assert_eq!(cache.lookup(0, 0), Some(0xCD));

        // Block (1,1) → u_idx=4, v_idx=4; set 0 ^ 1 ^ 1 ... wait,
        // (block_x=1 ^ block_y=1) = 0 → also set 0.
        assert_eq!(IndexCache::set_index(4, 4), 0);
        assert!(
            cache.lookup(4, 4).is_none(),
            "block (1,1) must miss even though it shares set 0 with block (0,0)"
        );
    }

    /// XOR set-index aliasing: two coordinates that map to the same set but
    /// have different tags evict each other on fill.
    #[test]
    fn xor_aliased_addresses_evict() {
        let mut cache = IndexCache::new();

        // (block_x, block_y) = (0, 0) → set 0
        // (block_x, block_y) = (32, 32) → block_x[4:0]^block_y[4:0] = 0 → also set 0
        // but tag differs because block_x_upper / block_y_upper differ.
        let u_a = 0u16;
        let v_a = 0u16;
        let u_b = 32u16 << 2; // block_x = 32
        let v_b = 32u16 << 2; // block_y = 32

        assert_eq!(IndexCache::set_index(u_a, v_a), 0);
        assert_eq!(IndexCache::set_index(u_b, v_b), 0);

        let payload_a = [0x11u8; INDICES_PER_LINE];
        let payload_b = [0x22u8; INDICES_PER_LINE];

        cache.fill_line(u_a, v_a, &payload_a);
        assert_eq!(cache.lookup(u_a, v_a), Some(0x11));

        cache.fill_line(u_b, v_b, &payload_b);
        // Second fill evicts the first — A is gone, B is resident.
        assert!(
            cache.lookup(u_a, v_a).is_none(),
            "first fill should be evicted by aliased second fill"
        );
        assert_eq!(cache.lookup(u_b, v_b), Some(0x22));
    }

    /// Invalidation clears every valid bit; subsequent lookups all miss.
    #[test]
    fn invalidate_clears_all_lines() {
        let mut cache = IndexCache::new();
        let payload = [0x55u8; INDICES_PER_LINE];

        // Fill several distinct sets.
        cache.fill_line(0, 0, &payload); // set 0
        cache.fill_line(4, 0, &payload); // set 1
        cache.fill_line(0, 4, &payload); // set 1 again — overwrites

        cache.fill_line(8, 0, &payload); // set 2
        cache.fill_line(12, 0, &payload); // set 3

        assert!(cache.valid_line_count() > 0);

        cache.invalidate();
        assert_eq!(cache.valid_line_count(), 0);
        assert!(cache.lookup(0, 0).is_none());
        assert!(cache.lookup(4, 0).is_none());
        assert!(cache.lookup(8, 0).is_none());
        assert!(cache.lookup(12, 0).is_none());
    }

    /// XOR set-index formula matches UNIT-011.03 §"Set index (XOR folding)".
    #[test]
    fn set_index_formula() {
        // block_x = u_idx >> 2, block_y = v_idx >> 2
        // set = block_x[4:0] ^ block_y[4:0]
        assert_eq!(IndexCache::set_index(0, 0), 0);
        assert_eq!(IndexCache::set_index(4, 0), 1);
        assert_eq!(IndexCache::set_index(0, 4), 1);
        assert_eq!(IndexCache::set_index(4, 4), 0);
        // block_x = 0x15 (=21), block_y = 0x0A (=10) → 0x1F
        assert_eq!(IndexCache::set_index(0x15 << 2, 0x0A << 2), 0x1F);
        // bit 5 of block_x (= u_idx[7]) is masked out of the set index but
        // present in the tag.
        assert_eq!(IndexCache::set_index(0x80, 0), 0); // block_x = 0x20
    }

    /// Line-offset formula matches the row-major 4×4 layout.
    #[test]
    fn line_offset_formula() {
        assert_eq!(IndexCache::line_offset(0, 0), 0);
        assert_eq!(IndexCache::line_offset(1, 0), 1);
        assert_eq!(IndexCache::line_offset(2, 0), 2);
        assert_eq!(IndexCache::line_offset(3, 0), 3);
        assert_eq!(IndexCache::line_offset(0, 1), 4);
        assert_eq!(IndexCache::line_offset(3, 3), 15);
        // Bits above [1:0] are ignored — they are absorbed into block_x/block_y.
        assert_eq!(IndexCache::line_offset(0x1234, 0x5678), {
            ((0x5678 & 0x3) << 2) | (0x1234 & 0x3)
        } as usize);
    }
}
