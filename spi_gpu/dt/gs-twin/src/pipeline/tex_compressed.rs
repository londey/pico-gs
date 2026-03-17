//! L2 compressed texture block cache — EBR-mapped model.
//!
//! Caches raw (compressed or uncompressed) SDRAM block data before decoding,
//! modelling the RTL's 4 × DP16KD in 1024×16 configuration (1024 × 64-bit
//! entries per sampler).
//!
//! # EBR Geometry
//!
//! | Parameter | Value | RTL Primitive |
//! |-----------|-------|---------------|
//! | Entries | 1024 | 4 × DP16KD 1024×16 = 1024 × 64 bits |
//! | Entry width | 64 bits | 4 × 16-bit words |
//! | Total capacity | 8 KiB | 1024 × 8 bytes |
//!
//! # Format-Aware Packing
//!
//! Each texture format occupies a different number of 64-bit entries per
//! 4×4 block, yielding format-dependent cache capacity:
//!
//! | Format | Entries/block | Capacity (blocks) |
//! |----------|---------------|-------------------|
//! | BC1 | 1 | 1024 |
//! | BC4 | 1 | 1024 |
//! | BC2 | 2 | 512 |
//! | BC3 | 2 | 512 |
//! | R8 | 2 | 512 |
//! | RGB565 | 4 | 256 |
//! | RGBA8888 | 8 | 128 |
//!
//! A 128×128 BC1 texture (32×32 = 1024 blocks) fits entirely in L2.
//!
//! # Addressing
//!
//! Direct-mapped with format-dependent slot count:
//! `slot = (base_words ^ block_index) % num_slots(format)`.
//!
//! See: INT-032 (Texture Cache Architecture).

use gpu_registers::components::tex_format_e::TexFormatE;

use super::tex_decode;

// ── EBR geometry constants ───────────────────────────────────────────────────

/// Total 64-bit entries in the L2 backing store.
///
/// Matches 4 × DP16KD in 1024×16 mode (4 × 16 bits = 64 bits per entry).
const L2_TOTAL_ENTRIES: usize = 1024;

// ── CompressedBlockProvider trait ────────────────────────────────────────────

/// Provide raw compressed/uncompressed block data from SDRAM, with caching.
///
/// Implementations may cache the raw SDRAM words to avoid redundant reads,
/// or pass through directly to SDRAM with no caching.
pub trait CompressedBlockProvider {
    /// Fetch raw block data for a 4×4 texel block.
    ///
    /// Returns a slice of `block_size_words(format)` u16 words containing the
    /// raw (possibly compressed) block data.
    ///
    /// # Arguments
    ///
    /// * `base_words` - Texture base address in u16 words.
    /// * `block_index` - Block index within the mip level (row-major).
    /// * `format` - Texture format (determines block size and L2 packing).
    /// * `sdram` - Flat SDRAM backing store.
    fn fetch_compressed(
        &mut self,
        base_words: u32,
        block_index: u32,
        format: TexFormatE,
        sdram: &[u16],
    ) -> &[u16];

    /// Invalidate all cached entries.
    fn invalidate(&mut self);
}

// ── Format-aware packing helpers ─────────────────────────────────────────────

/// Number of 64-bit L2 entries consumed by one 4×4 block of the given format.
///
/// Each entry holds 4 u16 words (64 bits).
/// Block size in u16 words divided by 4 gives entries per block.
const fn entries_per_block(format: TexFormatE) -> usize {
    // block_size_words: BC1=4, BC4=4, BC2=8, BC3=8, R8=8, RGB565=16, RGBA8888=32
    // entries = block_size_words / 4
    match format {
        TexFormatE::Bc1 | TexFormatE::Bc4 => 1, // 4 words / 4
        TexFormatE::Bc2 | TexFormatE::Bc3 | TexFormatE::R8 => 2, // 8 words / 4
        TexFormatE::Rgb565 => 4,                // 16 words / 4
        TexFormatE::Rgba8888 => 8,              // 32 words / 4
    }
}

/// Number of block slots available for the given format.
const fn num_slots(format: TexFormatE) -> usize {
    L2_TOTAL_ENTRIES / entries_per_block(format)
}

/// Pack 4 u16 words into one u64 (little-endian).
fn pack_u64(words: &[u16]) -> u64 {
    debug_assert!(words.len() >= 4);
    u64::from(words[0])
        | (u64::from(words[1]) << 16)
        | (u64::from(words[2]) << 32)
        | (u64::from(words[3]) << 48)
}

/// Unpack one u64 into 4 u16 words (little-endian), appending to `buf`.
fn unpack_u64(val: u64, buf: &mut Vec<u16>) {
    buf.push(val as u16);
    buf.push((val >> 16) as u16);
    buf.push((val >> 32) as u16);
    buf.push((val >> 48) as u16);
}

// ── Direct pass-through (no caching) ────────────────────────────────────────

/// Pass-through provider that reads directly from SDRAM with no caching.
///
/// This is useful for testing decoders in isolation without cache effects.
pub struct DirectSdramProvider {
    /// Scratch buffer for returning slices from SDRAM data.
    buf: Vec<u16>,
}

impl Default for DirectSdramProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl DirectSdramProvider {
    /// Create a new pass-through provider.
    #[must_use]
    pub fn new() -> Self {
        Self {
            buf: Vec::with_capacity(32), // Max block size (RGBA8888 = 32 words)
        }
    }
}

impl CompressedBlockProvider for DirectSdramProvider {
    fn fetch_compressed(
        &mut self,
        base_words: u32,
        block_index: u32,
        format: TexFormatE,
        sdram: &[u16],
    ) -> &[u16] {
        let block_size_words = tex_decode::block_size_words(format) as usize;
        let offset = base_words as usize + block_index as usize * block_size_words;
        let end = (offset + block_size_words).min(sdram.len());
        self.buf.clear();
        if offset < sdram.len() {
            self.buf.extend_from_slice(&sdram[offset..end]);
        }
        // Pad with zeros if SDRAM is too small.
        while self.buf.len() < block_size_words {
            self.buf.push(0);
        }
        &self.buf
    }

    fn invalidate(&mut self) {
        // No cached state to clear.
    }
}

// ── L2 cached compressed block provider ──────────────────────────────────────

/// Tag for one L2 cache slot.
#[derive(Clone, Copy, Default)]
struct L2Tag {
    /// Texture base address in u16 words.
    base_words: u32,
    /// Block index within the mip level.
    block_index: u32,
    /// Valid bit.
    valid: bool,
}

/// L2 compressed block cache statistics.
#[derive(Clone, Copy, Debug, Default)]
pub struct L2CacheStats {
    /// Number of L2 cache hits.
    pub hits: u64,
    /// Number of L2 cache misses (SDRAM fetches).
    pub misses: u64,
    /// Number of evictions (valid slot overwritten).
    pub evictions: u64,
}

/// L2 compressed block cache — 1024 × 64-bit entries matching 4 × DP16KD.
///
/// Direct-mapped with format-aware packing.
/// Each 4×4 compressed block occupies 1–8 consecutive 64-bit entries
/// depending on the texture format.
///
/// The backing store is a fixed `[u64; 1024]` array modelling the EBR
/// geometry exactly.
/// Tag storage uses a separate array sized to the maximum slot count (1024
/// for BC1/BC4).
pub struct CompressedBlockCache {
    /// Fixed 1024 × u64 backing store (4 × DP16KD 1024×16).
    data: Box<[u64; L2_TOTAL_ENTRIES]>,

    /// Per-slot tags.
    /// Sized to maximum slot count (1024); only `num_slots(format)` are active.
    tags: Box<[L2Tag; L2_TOTAL_ENTRIES]>,

    /// Scratch buffer for unpacking u64 → &[u16] return slices.
    buf: Vec<u16>,

    /// Cache statistics.
    pub stats: L2CacheStats,
}

impl Default for CompressedBlockCache {
    fn default() -> Self {
        Self::new()
    }
}

impl CompressedBlockCache {
    /// Create a new empty L2 compressed block cache.
    #[must_use]
    pub fn new() -> Self {
        Self {
            data: Box::new([0u64; L2_TOTAL_ENTRIES]),
            tags: Box::new([L2Tag::default(); L2_TOTAL_ENTRIES]),
            buf: Vec::with_capacity(32),
            stats: L2CacheStats::default(),
        }
    }

    /// Compute the slot index for a given block.
    fn slot_index(base_words: u32, block_index: u32, format: TexFormatE) -> usize {
        ((base_words ^ block_index) as usize) % num_slots(format)
    }

    /// Reset cache statistics.
    pub fn reset_stats(&mut self) {
        self.stats = L2CacheStats::default();
    }
}

impl CompressedBlockProvider for CompressedBlockCache {
    fn fetch_compressed(
        &mut self,
        base_words: u32,
        block_index: u32,
        format: TexFormatE,
        sdram: &[u16],
    ) -> &[u16] {
        let epb = entries_per_block(format);
        let slot = Self::slot_index(base_words, block_index, format);
        let tag = &self.tags[slot];

        // Hit check.
        if tag.valid && tag.base_words == base_words && tag.block_index == block_index {
            self.stats.hits += 1;
            // Unpack from backing store.
            self.buf.clear();
            let data_base = slot * epb;
            for i in 0..epb {
                unpack_u64(self.data[data_base + i], &mut self.buf);
            }
            return &self.buf;
        }

        // Miss: fetch from SDRAM.
        self.stats.misses += 1;
        if tag.valid {
            self.stats.evictions += 1;
        }

        let block_size_words = tex_decode::block_size_words(format) as usize;
        let offset = base_words as usize + block_index as usize * block_size_words;
        let end = (offset + block_size_words).min(sdram.len());

        // Read SDRAM words into scratch buffer.
        self.buf.clear();
        if offset < sdram.len() {
            self.buf.extend_from_slice(&sdram[offset..end]);
        }
        // Pad with zeros if SDRAM is too small.
        while self.buf.len() < block_size_words {
            self.buf.push(0);
        }

        // Pack into L2 backing store.
        let data_base = slot * epb;
        for i in 0..epb {
            let word_offset = i * 4;
            self.data[data_base + i] = pack_u64(&self.buf[word_offset..]);
        }

        // Update tag.
        self.tags[slot] = L2Tag {
            base_words,
            block_index,
            valid: true,
        };

        &self.buf
    }

    fn invalidate(&mut self) {
        for tag in self.tags.iter_mut() {
            tag.valid = false;
        }
    }
}

// ── Public helpers for external use ──────────────────────────────────────────

/// Number of 64-bit L2 entries per block for the given format.
///
/// Useful for callers that need to reason about L2 capacity.
#[must_use]
pub const fn l2_entries_per_block(format: TexFormatE) -> usize {
    entries_per_block(format)
}

/// Number of block slots in L2 for the given format.
#[must_use]
pub const fn l2_num_slots(format: TexFormatE) -> usize {
    num_slots(format)
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_provider_returns_correct_data() {
        let sdram: Vec<u16> = (0..256).collect();
        let mut provider = DirectSdramProvider::new();

        // Fetch BC1 block at offset 0 (4 words).
        let data = provider.fetch_compressed(0, 0, TexFormatE::Bc1, &sdram);
        assert_eq!(data.len(), 4);
        assert_eq!(data[0], 0);
        assert_eq!(data[3], 3);

        // Fetch RGB565 block at index 2 (16 words per block, offset = 32).
        let data = provider.fetch_compressed(0, 2, TexFormatE::Rgb565, &sdram);
        assert_eq!(data.len(), 16);
        assert_eq!(data[0], 32);
        assert_eq!(data[15], 47);
    }

    #[test]
    fn cached_provider_hit_and_miss_bc1() {
        let sdram: Vec<u16> = (0..4096).collect();
        let mut cache = CompressedBlockCache::new();

        // First access: miss.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Bc1, &sdram);
        assert_eq!(data.len(), 4);
        assert_eq!(data[0], 0);
        assert_eq!(data[3], 3);
        assert_eq!(cache.stats.misses, 1);
        assert_eq!(cache.stats.hits, 0);

        // Second access: hit.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Bc1, &sdram);
        assert_eq!(data[0], 0);
        assert_eq!(data[3], 3);
        assert_eq!(cache.stats.hits, 1);
        assert_eq!(cache.stats.misses, 1);

        // Different block: miss.
        let data = cache.fetch_compressed(0, 1, TexFormatE::Bc1, &sdram);
        assert_eq!(data[0], 4);
        assert_eq!(data[3], 7);
        assert_eq!(cache.stats.misses, 2);
    }

    #[test]
    fn cached_provider_hit_and_miss_bc3() {
        let sdram: Vec<u16> = (0..4096).collect();
        let mut cache = CompressedBlockCache::new();

        // BC3: 8 words per block, 2 entries per block, 512 slots.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Bc3, &sdram);
        assert_eq!(data.len(), 8);
        assert_eq!(data[0], 0);
        assert_eq!(data[7], 7);
        assert_eq!(cache.stats.misses, 1);

        // Hit.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Bc3, &sdram);
        assert_eq!(data[0], 0);
        assert_eq!(data[7], 7);
        assert_eq!(cache.stats.hits, 1);
    }

    #[test]
    fn cached_provider_hit_and_miss_rgba8888() {
        let sdram: Vec<u16> = (0..8192).collect();
        let mut cache = CompressedBlockCache::new();

        // RGBA8888: 32 words per block, 8 entries per block, 128 slots.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Rgba8888, &sdram);
        assert_eq!(data.len(), 32);
        assert_eq!(data[0], 0);
        assert_eq!(data[31], 31);
        assert_eq!(cache.stats.misses, 1);

        // Hit.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Rgba8888, &sdram);
        assert_eq!(data[0], 0);
        assert_eq!(data[31], 31);
        assert_eq!(cache.stats.hits, 1);
    }

    #[test]
    fn cached_provider_invalidation() {
        let sdram: Vec<u16> = (0..256).collect();
        let mut cache = CompressedBlockCache::new();

        cache.fetch_compressed(0, 0, TexFormatE::Bc1, &sdram);
        assert_eq!(cache.stats.misses, 1);

        cache.invalidate();

        // After invalidation, same block is a miss.
        cache.fetch_compressed(0, 0, TexFormatE::Bc1, &sdram);
        assert_eq!(cache.stats.misses, 2);
    }

    #[test]
    fn cached_provider_eviction() {
        let sdram: Vec<u16> = (0..=65535u16).collect();
        let mut cache = CompressedBlockCache::new();

        // BC1: 1024 slots. Fill slot 0 with block_index=0.
        cache.fetch_compressed(0, 0, TexFormatE::Bc1, &sdram);
        assert_eq!(cache.stats.evictions, 0);

        // Block_index=1024 maps to same slot (1024 % 1024 = 0). Evicts block 0.
        cache.fetch_compressed(0, 1024, TexFormatE::Bc1, &sdram);
        assert_eq!(cache.stats.evictions, 1);
        assert_eq!(cache.stats.misses, 2);
    }

    #[test]
    fn out_of_bounds_sdram_padded() {
        let sdram: Vec<u16> = vec![0xAAAA; 4];
        let mut provider = DirectSdramProvider::new();

        // Request RGB565 block (16 words) but only 4 available.
        let data = provider.fetch_compressed(0, 0, TexFormatE::Rgb565, &sdram);
        assert_eq!(data.len(), 16);
        assert_eq!(data[0], 0xAAAA);
        assert_eq!(data[3], 0xAAAA);
        assert_eq!(data[4], 0, "should be zero-padded");
    }

    #[test]
    fn format_capacity() {
        // Verify slot counts match documented capacity.
        assert_eq!(l2_num_slots(TexFormatE::Bc1), 1024);
        assert_eq!(l2_num_slots(TexFormatE::Bc4), 1024);
        assert_eq!(l2_num_slots(TexFormatE::Bc2), 512);
        assert_eq!(l2_num_slots(TexFormatE::Bc3), 512);
        assert_eq!(l2_num_slots(TexFormatE::R8), 512);
        assert_eq!(l2_num_slots(TexFormatE::Rgb565), 256);
        assert_eq!(l2_num_slots(TexFormatE::Rgba8888), 128);
    }

    #[test]
    fn data_integrity_round_trip() {
        // Store a compressed block, read it back, verify exact u16 match.
        let mut sdram = vec![0u16; 1024];
        // Write recognizable pattern at block 0 (BC3 = 8 words).
        for i in 0..8 {
            sdram[i] = 0xBEEF_u16.wrapping_add(i as u16);
        }

        let mut cache = CompressedBlockCache::new();

        // Miss → fills L2.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Bc3, &sdram);
        let first_read: Vec<u16> = data.to_vec();

        // Hit → reads from L2 backing store.
        let data = cache.fetch_compressed(0, 0, TexFormatE::Bc3, &sdram);
        let second_read: Vec<u16> = data.to_vec();

        assert_eq!(first_read, second_read, "round-trip data mismatch");
        for i in 0..8 {
            assert_eq!(
                first_read[i],
                0xBEEF_u16.wrapping_add(i as u16),
                "word {i} mismatch"
            );
        }
    }

    #[test]
    fn pack_unpack_round_trip() {
        let words = [0x1234u16, 0x5678, 0x9ABC, 0xDEF0];
        let packed = pack_u64(&words);
        let mut buf = Vec::new();
        unpack_u64(packed, &mut buf);
        assert_eq!(&buf, &words);
    }
}
