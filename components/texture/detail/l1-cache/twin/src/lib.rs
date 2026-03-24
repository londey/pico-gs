#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]
#![allow(dead_code)]
#![allow(unused_crate_dependencies)]

//! L1 decoded texture block cache — EBR-mapped 4-way set-associative model.
//!
//! Each texture sampler (TEX0, TEX1) has an independent L1 cache that stores
//! decompressed 4×4 texel blocks in [`TexelUq18`] format (9 bits per channel,
//! 36 bits per texel).
//!
//! The cache uses XOR-folded set indexing and pseudo-LRU replacement.
//!
//! # EBR Geometry
//!
//! 4 banks × 1 PDPW16KD 512×36 each = 4 EBR per sampler.
//! Address: `{cache_line_index[6:0], texel_within_bank[1:0]}` = 9 bits → 512 entries.
//! All 512 entries per bank are utilized (128 lines × 4 texels/bank).
//!
//! # 4-Bank Bilinear Interleaving
//!
//! Internally, each cache line stores its 16 texels across 4 banks,
//! indexed by `{local_y[0], local_x[0]}`:
//! - Bank 0: even_x, even_y (positions (0,0), (2,0), (0,2), (2,2))
//! - Bank 1: odd_x, even_y (positions (1,0), (3,0), (1,2), (3,2))
//! - Bank 2: even_x, odd_y (positions (0,1), (2,1), (0,3), (2,3))
//! - Bank 3: odd_x, odd_y (positions (1,1), (3,1), (1,3), (3,3))
//!
//! This models the RTL's PDPW16KD EBR bank interleaving, which allows
//! any 2×2 bilinear quad to be read in a single cycle (one texel per bank).
//!
//! # Cache Parameters (matching RTL)
//!
//! | Parameter | Value | RTL Reference |
//! |-----------|-------|---------------|
//! | Sets | 32 | 5-bit XOR-folded index |
//! | Ways | 4 | 4-way set-associative |
//! | Lines | 128 | 32 × 4 = 128 (2048 texels) |
//! | EBR/bank | 512×36 | PDPW16KD, 128 lines × 4 texels/bank = 512 entries |
//! | Set index | 5 bits | `block_x[4:0] ^ block_y[4:0]` |
//! | LRU | 3-bit pseudo-LRU | Binary tree for 4 ways |
//! | Banks | 4 | `{local_y[0], local_x[0]}` interleaving |
//!
//! See: INT-032 (Texture Cache Architecture), UNIT-006 (Pixel Pipeline).

use gs_twin_core::texel::TexelUq18;

/// Number of cache sets (5-bit index).
const NUM_SETS: usize = 32;

/// Number of ways per set.
const NUM_WAYS: usize = 4;

/// Total cache lines (`NUM_SETS × NUM_WAYS`).
const NUM_LINES: usize = NUM_SETS * NUM_WAYS;

/// Number of bilinear interleave banks.
const NUM_BANKS: usize = 4;

/// Number of texels per bank per cache line (16 texels / 4 banks).
const TEXELS_PER_BANK: usize = 4;

/// Entries per PDPW16KD bank (512×36 mode, fully utilized).
///
/// 128 cache lines × 4 texels/bank = 512 entries.
#[allow(dead_code)]
const L1_ENTRIES_PER_BANK: usize = NUM_LINES * TEXELS_PER_BANK;

// ── DecodedBlockProvider trait ─────────────────────────────────────────────

/// Provides decoded 4×4 texel blocks, with caching.
///
/// Implementations manage storage of decompressed texel blocks and
/// support both full-block lookup and single-cycle bilinear quad gather.
pub trait DecodedBlockProvider {
    /// Look up a decoded block.
    ///
    /// On hit, returns the 16 texels in row-major order.
    /// On miss, returns `None`.
    fn lookup(&mut self, base_words: u32, block_x: u32, block_y: u32) -> Option<[TexelUq18; 16]>;

    /// Fill a cache line with a decoded block (row-major order).
    fn fill(&mut self, base_words: u32, block_x: u32, block_y: u32, data: [TexelUq18; 16]);

    /// Invalidate all entries (called on TEXn_CFG write).
    fn invalidate(&mut self);

    /// Gather a bilinear quad: 4 texels from potentially different blocks,
    /// one from each bank, in a single call.
    ///
    /// Each coordinate is `(base_words, block_x, block_y, local_index)`
    /// where `local_index` is the row-major offset within the 4×4 block.
    ///
    /// Returns `None` if any of the 4 blocks is not cached.
    /// Does **not** update LRU or statistics — the caller must have
    /// already ensured the blocks are cached via [`lookup`](Self::lookup)
    /// or [`fill`](Self::fill).
    fn gather_bilinear_quad(&self, coords: &[(u32, u32, u32, u32); 4]) -> Option<[TexelUq18; 4]>;

    /// Count the number of valid cache lines.
    fn valid_line_count(&self) -> usize;
}

// ── Cache statistics ────────────────────────────────────────────────────────

/// Cumulative cache statistics for diagnostics.
///
/// All counters are monotonically increasing and reset only on
/// [`TextureBlockCache::reset_stats`].
#[derive(Debug, Clone, Copy, Default)]
pub struct CacheStats {
    /// Number of cache hits (block found in cache).
    pub hits: u64,

    /// Number of cache misses (block not found, must fill from SDRAM).
    pub misses: u64,

    /// Number of evictions (valid line replaced by a new fill).
    pub evictions: u64,

    /// Number of full-cache invalidations (triggered by TEXn_CFG write).
    pub invalidations: u64,
}

// ── Bank interleaving helpers ─────────────────────────────────────────────

/// Compute the bank index for a texel at local position within a 4×4 block.
///
/// Bank assignment matches RTL: `bank = {local_y[0], local_x[0]}`.
///
/// # Arguments
///
/// * `local` - Row-major offset within the 4×4 block (0..16).
///
/// # Returns
///
/// Bank index (0..4).
fn bank_index(local: u32) -> usize {
    let lx = local & 3; // local_x = local % 4
    let ly = local >> 2; // local_y = local / 4
    ((ly & 1) << 1 | (lx & 1)) as usize
}

/// Compute the intra-bank slot for a texel at local position.
///
/// Within each bank, texels are stored in order of their local position
/// divided by their parity group.
/// For a 4×4 block, each bank gets exactly 4 texels.
///
/// Bank 0 (even_x, even_y): positions 0, 2, 8, 10 → slots 0, 1, 2, 3
/// Bank 1 (odd_x, even_y): positions 1, 3, 9, 11 → slots 0, 1, 2, 3
/// Bank 2 (even_x, odd_y): positions 4, 6, 12, 14 → slots 0, 1, 2, 3
/// Bank 3 (odd_x, odd_y): positions 5, 7, 13, 15 → slots 0, 1, 2, 3
fn bank_slot(local: u32) -> usize {
    let lx = local & 3;
    let ly = local >> 2;
    // Slot = (ly/2)*2 + (lx/2), giving 0..4 within the bank.
    ((ly >> 1) * 2 + (lx >> 1)) as usize
}

// ── Cache tag ───────────────────────────────────────────────────────────────

/// Cache tag uniquely identifying a 4×4 texel block within SDRAM.
///
/// With 32 sets (5-bit XOR index), block coordinate bits `[4:0]` are
/// consumed by the set index, so the tag stores the full base address
/// and the remaining upper block coordinate bits.
/// The tag width is `{tex_base[23:12], block_y[6:5], block_x[6:5]}` = 16 bits
/// (12 + 2 + 2), but we store the full coordinates for clarity and
/// compare them directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct CacheTag {
    /// Upper 12 bits of the texture base address (`tex_base_addr[23:12]`).
    base_addr_hi: u16,

    /// Block Y coordinate (bits above the 5-bit set index).
    block_y: u8,

    /// Block X coordinate (bits above the 5-bit set index).
    block_x: u8,
}

impl CacheTag {
    /// Construct a tag from the base word address and block coordinates.
    ///
    /// The lower 5 bits of `block_x` and `block_y` are consumed by the
    /// set index; the tag stores bits `[6:5]` for disambiguation.
    fn new(base_words: u32, block_x: u32, block_y: u32) -> Self {
        Self {
            base_addr_hi: ((base_words >> 12) & 0xFFF) as u16,
            block_y: (block_y & 0x7F) as u8,
            block_x: (block_x & 0x7F) as u8,
        }
    }
}

// ── Cache line ──────────────────────────────────────────────────────────────

/// One cache line: tag + valid bit + 16 decompressed texels in 4 banks.
///
/// The 4-bank layout models the RTL's PDPW16KD interleaving:
/// `banks[{ly[0], lx[0]}][slot]` where slot indexes within the bank.
#[derive(Debug, Clone, Default)]
struct CacheLine {
    /// Tag identifying the cached block.
    tag: CacheTag,

    /// Valid bit — cleared on invalidation, set on fill.
    valid: bool,

    /// 4 bilinear-interleaved banks, each holding 4 texels.
    banks: [[TexelUq18; TEXELS_PER_BANK]; NUM_BANKS],
}

impl CacheLine {
    /// Store a row-major `[TexelUq18; 16]` block into the 4-bank layout.
    fn store_row_major(&mut self, data: &[TexelUq18; 16]) {
        for (local, texel) in data.iter().enumerate() {
            let bank = bank_index(local as u32);
            let slot = bank_slot(local as u32);
            self.banks[bank][slot] = *texel;
        }
    }

    /// Read the 4-bank layout back as a row-major `[TexelUq18; 16]` block.
    fn to_row_major(&self) -> [TexelUq18; 16] {
        let mut out = [TexelUq18::default(); 16];
        for local in 0..16u32 {
            let bank = bank_index(local);
            let slot = bank_slot(local);
            out[local as usize] = self.banks[bank][slot];
        }
        out
    }

    /// Read a single texel by its row-major local index.
    fn read_texel(&self, local: u32) -> TexelUq18 {
        let bank = bank_index(local);
        let slot = bank_slot(local);
        self.banks[bank][slot]
    }
}

// ── Pseudo-LRU helpers ──────────────────────────────────────────────────────

/// Select the victim way from the 3-bit pseudo-LRU state.
///
/// Matches the RTL truth table in `texture_cache.sv` lines 282–290:
///
/// ```text
/// LRU[2:0] → victim_way
/// 000 → 0    001 → 0    010 → 1    011 → 1
/// 100 → 2    101 → 3    110 → 2    111 → 3
/// ```
fn victim_way(lru_bits: u8) -> usize {
    match lru_bits & 0x7 {
        0b000 | 0b001 => 0,
        0b010 | 0b011 => 1,
        0b100 | 0b110 => 2,
        0b101 | 0b111 => 3,
        _ => unreachable!(),
    }
}

/// Update the pseudo-LRU state after accessing a given way.
///
/// Marks the accessed way as most-recently-used by updating the
/// binary tree bits.
/// Matches the RTL logic in `texture_cache.sv` lines 706–740:
///
/// ```text
/// way 0: set bits [2],[1]
/// way 1: set [2], clear [1]
/// way 2: clear [2], set [0]
/// way 3: clear [2], clear [0]
/// ```
fn update_lru(lru: &mut u8, way: usize) {
    match way {
        0 => *lru |= 0b110,
        1 => *lru = (*lru | 0b100) & !0b010,
        2 => *lru = (*lru & !0b100) | 0b001,
        3 => *lru &= !0b101,
        _ => unreachable!(),
    }
}

// ── Texture block cache ─────────────────────────────────────────────────────

/// L1 decoded texture block cache (4-way set-associative, EBR-mapped).
///
/// Stores decompressed 4×4 texel blocks in [`TexelUq18`] format across
/// 4 bilinear-interleaved PDPW16KD banks (512×36 each).
/// Uses 32 sets × 4 ways = 128 lines (2048 texels), with XOR-folded
/// set indexing and 3-bit pseudo-LRU replacement per set.
///
/// Each bank holds 512 entries (128 lines × 4 texels/bank), fully
/// utilizing the PDPW16KD 512×36 capacity with zero waste.
pub struct TextureBlockCache {
    /// Fixed-size cache lines, indexed as `set * 4 + way`.
    lines: Vec<CacheLine>,

    /// 3-bit pseudo-LRU state per set (only bits `[2:0]` used).
    lru: [u8; NUM_SETS],

    /// Cumulative statistics.
    pub stats: CacheStats,
}

impl Default for TextureBlockCache {
    fn default() -> Self {
        Self::new()
    }
}

impl TextureBlockCache {
    /// Create a new cache with all lines invalid and LRU bits zeroed.
    #[must_use]
    pub fn new() -> Self {
        Self {
            lines: vec![CacheLine::default(); NUM_LINES],
            lru: [0u8; NUM_SETS],
            stats: CacheStats::default(),
        }
    }

    /// Reset statistics counters to zero.
    pub fn reset_stats(&mut self) {
        self.stats = CacheStats::default();
    }

    /// Compute the 5-bit XOR-folded set index.
    ///
    /// Matches RTL: `set_index = block_x[4:0] ^ block_y[4:0]`.
    fn set_index(block_x: u32, block_y: u32) -> usize {
        ((block_x & 0x1F) ^ (block_y & 0x1F)) as usize
    }

    /// Find the way containing the given tag in the given set, if valid.
    fn find_way(&self, set: usize, tag: &CacheTag) -> Option<usize> {
        let base_idx = set * NUM_WAYS;
        for way in 0..NUM_WAYS {
            let idx = base_idx + way;
            if self.lines[idx].valid && self.lines[idx].tag == *tag {
                return Some(way);
            }
        }
        None
    }
}

impl DecodedBlockProvider for TextureBlockCache {
    fn lookup(&mut self, base_words: u32, block_x: u32, block_y: u32) -> Option<[TexelUq18; 16]> {
        let set = Self::set_index(block_x, block_y);
        let tag = CacheTag::new(base_words, block_x, block_y);

        if let Some(way) = self.find_way(set, &tag) {
            update_lru(&mut self.lru[set], way);
            self.stats.hits += 1;
            let idx = set * NUM_WAYS + way;
            Some(self.lines[idx].to_row_major())
        } else {
            self.stats.misses += 1;
            None
        }
    }

    fn fill(&mut self, base_words: u32, block_x: u32, block_y: u32, data: [TexelUq18; 16]) {
        let set = Self::set_index(block_x, block_y);
        let tag = CacheTag::new(base_words, block_x, block_y);
        let way = victim_way(self.lru[set]);
        let idx = set * NUM_WAYS + way;

        if self.lines[idx].valid {
            self.stats.evictions += 1;
        }

        self.lines[idx].tag = tag;
        self.lines[idx].valid = true;
        self.lines[idx].store_row_major(&data);

        update_lru(&mut self.lru[set], way);
    }

    fn invalidate(&mut self) {
        for line in &mut self.lines {
            line.valid = false;
        }
        self.lru = [0u8; NUM_SETS];
        self.stats.invalidations += 1;
    }

    fn gather_bilinear_quad(&self, coords: &[(u32, u32, u32, u32); 4]) -> Option<[TexelUq18; 4]> {
        let mut result = [TexelUq18::default(); 4];
        for (i, &(base_words, block_x, block_y, local)) in coords.iter().enumerate() {
            let set = Self::set_index(block_x, block_y);
            let tag = CacheTag::new(base_words, block_x, block_y);

            let way = self.find_way(set, &tag)?;
            let idx = set * NUM_WAYS + way;
            result[i] = self.lines[idx].read_texel(local);
        }
        Some(result)
    }

    fn valid_line_count(&self) -> usize {
        self.lines.iter().filter(|l| l.valid).count()
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use qfixed::UQ;

    /// Verify victim selection truth table matches RTL.
    #[test]
    fn victim_selection_truth_table() {
        assert_eq!(victim_way(0b000), 0);
        assert_eq!(victim_way(0b001), 0);
        assert_eq!(victim_way(0b010), 1);
        assert_eq!(victim_way(0b011), 1);
        assert_eq!(victim_way(0b100), 2);
        assert_eq!(victim_way(0b101), 3);
        assert_eq!(victim_way(0b110), 2);
        assert_eq!(victim_way(0b111), 3);
    }

    /// Verify LRU update logic matches RTL.
    #[test]
    fn lru_update_logic() {
        let mut lru = 0b000;
        update_lru(&mut lru, 0);
        assert_eq!(lru, 0b110);

        let mut lru = 0b000;
        update_lru(&mut lru, 1);
        assert_eq!(lru, 0b100);

        let mut lru = 0b111;
        update_lru(&mut lru, 2);
        assert_eq!(lru, 0b011);

        let mut lru = 0b111;
        update_lru(&mut lru, 3);
        assert_eq!(lru, 0b010);
    }

    /// Verify 5-bit XOR-folded set indexing.
    #[test]
    fn set_index_xor_folding() {
        assert_eq!(TextureBlockCache::set_index(0, 0), 0);
        assert_eq!(TextureBlockCache::set_index(1, 0), 1);
        assert_eq!(TextureBlockCache::set_index(0, 1), 1);
        assert_eq!(TextureBlockCache::set_index(1, 1), 0);
        assert_eq!(TextureBlockCache::set_index(0x1F, 0x1F), 0);
        assert_eq!(TextureBlockCache::set_index(0x15, 0x0A), 0x1F);
        assert_eq!(
            TextureBlockCache::set_index(0x20, 0),
            0,
            "bit 5 should be masked"
        );
    }

    /// Verify tag construction with 7-bit block coords.
    #[test]
    fn tag_construction() {
        let tag = CacheTag::new(0x1234_000, 5, 10);
        assert_eq!(tag.base_addr_hi, ((0x1234_000u32 >> 12) & 0xFFF) as u16);
        assert_eq!(tag.block_x, 5);
        assert_eq!(tag.block_y, 10);

        // Block coords are masked to 7 bits.
        let tag = CacheTag::new(0, 0xFF, 0xFF);
        assert_eq!(tag.block_x, 0x7F);
        assert_eq!(tag.block_y, 0x7F);
    }

    /// Verify bank index assignment matches RTL interleaving.
    #[test]
    fn bank_index_assignment() {
        // Bank 0: even_x, even_y → positions 0, 2, 8, 10
        assert_eq!(bank_index(0), 0); // (0,0)
        assert_eq!(bank_index(2), 0); // (2,0)
        assert_eq!(bank_index(8), 0); // (0,2)
        assert_eq!(bank_index(10), 0); // (2,2)

        // Bank 1: odd_x, even_y → positions 1, 3, 9, 11
        assert_eq!(bank_index(1), 1); // (1,0)
        assert_eq!(bank_index(3), 1); // (3,0)
        assert_eq!(bank_index(9), 1); // (1,2)
        assert_eq!(bank_index(11), 1); // (3,2)

        // Bank 2: even_x, odd_y → positions 4, 6, 12, 14
        assert_eq!(bank_index(4), 2); // (0,1)
        assert_eq!(bank_index(6), 2); // (2,1)
        assert_eq!(bank_index(12), 2); // (0,3)
        assert_eq!(bank_index(14), 2); // (2,3)

        // Bank 3: odd_x, odd_y → positions 5, 7, 13, 15
        assert_eq!(bank_index(5), 3); // (1,1)
        assert_eq!(bank_index(7), 3); // (3,1)
        assert_eq!(bank_index(13), 3); // (1,3)
        assert_eq!(bank_index(15), 3); // (3,3)
    }

    /// Verify each bank gets exactly 4 texels with unique slots.
    #[test]
    fn bank_slot_coverage() {
        let mut bank_slots: [Vec<usize>; 4] = [vec![], vec![], vec![], vec![]];
        for local in 0..16u32 {
            let bank = bank_index(local);
            let slot = bank_slot(local);
            bank_slots[bank].push(slot);
        }
        for (b, slots) in bank_slots.iter().enumerate() {
            assert_eq!(slots.len(), 4, "bank {b} should have 4 texels");
            let mut sorted = slots.clone();
            sorted.sort();
            sorted.dedup();
            assert_eq!(sorted.len(), 4, "bank {b} slots should be unique");
        }
    }

    /// Verify round-trip: store row-major → read back row-major.
    #[test]
    fn row_major_round_trip() {
        let mut data = [TexelUq18::default(); 16];
        for (i, texel) in data.iter_mut().enumerate() {
            texel.r = UQ::from_bits(i as u64);
        }

        let mut line = CacheLine::default();
        line.store_row_major(&data);
        let out = line.to_row_major();

        for i in 0..16 {
            assert_eq!(
                out[i].r.to_bits(),
                data[i].r.to_bits(),
                "texel {i} mismatch"
            );
        }
    }

    /// Basic hit and miss behavior.
    #[test]
    fn basic_hit_and_miss() {
        let mut cache = TextureBlockCache::new();
        let data = [TexelUq18::default(); 16];

        assert!(cache.lookup(256, 0, 0).is_none());
        assert_eq!(cache.stats.misses, 1);
        assert_eq!(cache.stats.hits, 0);

        cache.fill(256, 0, 0, data);
        assert!(cache.lookup(256, 0, 0).is_some());
        assert_eq!(cache.stats.hits, 1);
        assert_eq!(cache.stats.misses, 1);

        assert!(cache.lookup(256, 1, 0).is_none());
        assert_eq!(cache.stats.misses, 2);
    }

    /// Invalidation clears all lines.
    #[test]
    fn invalidation_clears_cache() {
        let mut cache = TextureBlockCache::new();
        let data = [TexelUq18::default(); 16];

        cache.fill(256, 0, 0, data);
        cache.fill(256, 1, 1, data);
        assert_eq!(cache.valid_line_count(), 2);

        cache.invalidate();
        assert_eq!(cache.valid_line_count(), 0);
        assert_eq!(cache.stats.invalidations, 1);

        assert!(cache.lookup(256, 0, 0).is_none());
        assert!(cache.lookup(256, 1, 1).is_none());
    }

    /// Eviction occurs when 5th block maps to the same set.
    #[test]
    fn eviction_on_fifth_fill() {
        let mut cache = TextureBlockCache::new();
        let data = [TexelUq18::default(); 16];

        let coords: [(u32, u32); 5] = [(0, 0), (1, 1), (2, 2), (3, 3), (4, 4)];

        for &(bx, by) in &coords[..4] {
            cache.fill(256, bx, by, data);
        }
        assert_eq!(cache.stats.evictions, 0, "no eviction with 4 ways");

        cache.fill(256, coords[4].0, coords[4].1, data);
        assert_eq!(cache.stats.evictions, 1);
    }

    /// Verify LRU-directed eviction order.
    #[test]
    fn lru_eviction_order() {
        let mut cache = TextureBlockCache::new();
        let data = [TexelUq18::default(); 16];

        let coords: [(u32, u32); 4] = [(0, 0), (1, 1), (2, 2), (3, 3)];
        for &(bx, by) in &coords {
            cache.fill(256, bx, by, data);
        }

        cache.lookup(256, 0, 0);

        cache.fill(256, 4, 4, data);

        assert!(
            cache.lookup(256, 0, 0).is_some(),
            "recently accessed block should survive eviction"
        );
    }

    /// Verify data integrity through fill and lookup round-trip.
    #[test]
    fn data_integrity_round_trip() {
        let mut cache = TextureBlockCache::new();
        let mut data = [TexelUq18::default(); 16];
        for (i, texel) in data.iter_mut().enumerate() {
            texel.r = UQ::from_bits(i as u64 * 16);
            texel.g = UQ::from_bits(i as u64 * 8);
        }

        cache.fill(256, 5, 3, data);
        let result = cache.lookup(256, 5, 3).expect("should hit");

        for i in 0..16 {
            assert_eq!(
                result[i].r.to_bits(),
                data[i].r.to_bits(),
                "R mismatch at {i}"
            );
            assert_eq!(
                result[i].g.to_bits(),
                data[i].g.to_bits(),
                "G mismatch at {i}"
            );
        }
    }

    /// Verify gather_bilinear_quad reads one texel from each bank.
    #[test]
    fn gather_bilinear_quad_single_block() {
        let mut cache = TextureBlockCache::new();
        let mut data = [TexelUq18::default(); 16];
        for (i, texel) in data.iter_mut().enumerate() {
            texel.r = UQ::from_bits(i as u64 + 1);
        }

        cache.fill(256, 0, 0, data);

        // Bilinear quad at (0,0): texels at local positions 0, 1, 4, 5
        // These are in banks 0, 1, 2, 3 respectively.
        let coords = [
            (256u32, 0u32, 0u32, 0u32), // (0,0) → bank 0
            (256, 0, 0, 1),             // (1,0) → bank 1
            (256, 0, 0, 4),             // (0,1) → bank 2
            (256, 0, 0, 5),             // (1,1) → bank 3
        ];
        let result = cache.gather_bilinear_quad(&coords).expect("all cached");
        assert_eq!(result[0].r.to_bits(), 1); // local 0
        assert_eq!(result[1].r.to_bits(), 2); // local 1
        assert_eq!(result[2].r.to_bits(), 5); // local 4
        assert_eq!(result[3].r.to_bits(), 6); // local 5
    }

    /// Verify gather_bilinear_quad returns None on miss.
    #[test]
    fn gather_bilinear_quad_miss() {
        let cache = TextureBlockCache::new();
        let coords = [
            (256u32, 0u32, 0u32, 0u32),
            (256, 0, 0, 1),
            (256, 0, 0, 4),
            (256, 0, 0, 5),
        ];
        assert!(cache.gather_bilinear_quad(&coords).is_none());
    }
}
