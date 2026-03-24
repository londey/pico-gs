//! Block fetcher — orchestrates two-level cache lookup, decode, and fill.
//!
//! The [`BlockFetcher`] trait provides the interface for obtaining decoded
//! 4×4 texel blocks.
//! [`ConcreteFetcher`] is the standard implementation that
//! owns a [`DecodedBlockProvider`] (L1 decoded cache) and a
//! [`CompressedBlockProvider`] (L2 compressed block cache), wiring them
//! together with the format decoders in `tex_decode`.
//!
//! # Data flow
//!
//! ```text
//! BlockFetcher::get_block()
//!   → L1: DecodedBlockProvider::lookup() — hit? return
//!   → L2: CompressedBlockProvider::fetch_compressed() — hit L2 or fetch SDRAM
//!   → tex_decode::TexelDecoder::decode_block() — decompress to UQ1.8
//!   → L1: DecodedBlockProvider::fill() — store in decoded cache
//!   → return decoded block
//! ```

use gpu_registers::components::tex_format_e::TexFormatE;

use gs_tex_l1_cache::{CacheStats, DecodedBlockProvider, TextureBlockCache};
use gs_tex_l2_cache::{CompressedBlockCache, CompressedBlockProvider, L2CacheStats};
use gs_twin_core::texel::TexelUq18;

use crate::tex_decode;

// ── BlockFetcher trait ──────────────────────────────────────────────────────

/// Fetch decoded 4×4 texel blocks, using caches on hit and decoding
/// from SDRAM on miss.
pub trait BlockFetcher {
    /// Fetch a decoded 4×4 block.
    ///
    /// On cache hit, returns immediately.
    /// On miss, fetches compressed data, decodes, fills the cache, and returns.
    ///
    /// # Arguments
    ///
    /// * `base_words` - Texture base address in u16 words.
    /// * `block_x` - Block X coordinate (texel X / 4).
    /// * `block_y` - Block Y coordinate (texel Y / 4).
    /// * `block_index` - Block index within the mip level (row-major).
    /// * `format` - Texture pixel format.
    /// * `sdram` - Flat SDRAM backing store.
    fn get_block(
        &mut self,
        base_words: u32,
        block_x: u32,
        block_y: u32,
        block_index: u32,
        format: TexFormatE,
        sdram: &[u16],
    ) -> [TexelUq18; 16];

    /// Invalidate all caches (called on TEXn_CFG write).
    fn invalidate(&mut self);

    /// Return L1 decoded cache statistics.
    fn cache_stats(&self) -> &CacheStats;

    /// Return L2 compressed cache statistics.
    fn l2_stats(&self) -> &L2CacheStats;

    /// Return the number of valid L1 decoded cache lines.
    fn cached_block_count(&self) -> usize;
}

// ── ConcreteFetcher ─────────────────────────────────────────────────────────

/// Standard block fetcher owning L1 (decoded) and L2 (compressed) caches.
///
/// Orchestrates the two-level fetch pipeline:
/// L1 decoded lookup → L2 compressed lookup/SDRAM fetch → format decode → L1 fill.
pub struct ConcreteFetcher {
    /// L1 decoded texel block cache (4-way set-associative).
    cache: TextureBlockCache,

    /// L2 compressed block cache (1024 × 64-bit, format-aware packing).
    compressed: CompressedBlockCache,
}

impl Default for ConcreteFetcher {
    fn default() -> Self {
        Self::new()
    }
}

impl ConcreteFetcher {
    /// Create a new fetcher with empty caches.
    #[must_use]
    pub fn new() -> Self {
        Self {
            cache: TextureBlockCache::new(),
            compressed: CompressedBlockCache::new(),
        }
    }
}

impl BlockFetcher for ConcreteFetcher {
    fn get_block(
        &mut self,
        base_words: u32,
        block_x: u32,
        block_y: u32,
        block_index: u32,
        format: TexFormatE,
        sdram: &[u16],
    ) -> [TexelUq18; 16] {
        // Try decoded cache first.
        if let Some(block) = self.cache.lookup(base_words, block_x, block_y) {
            return block;
        }

        // L1 miss: fetch from L2 (hits L2 cache or falls through to SDRAM).
        let raw = self
            .compressed
            .fetch_compressed(base_words, block_index, format, sdram);
        let block = tex_decode::decode_block_raw(format, raw);
        self.cache.fill(base_words, block_x, block_y, block);
        block
    }

    fn invalidate(&mut self) {
        self.cache.invalidate();
        self.compressed.invalidate();
    }

    fn cache_stats(&self) -> &CacheStats {
        &self.cache.stats
    }

    fn l2_stats(&self) -> &L2CacheStats {
        &self.compressed.stats
    }

    fn cached_block_count(&self) -> usize {
        self.cache.valid_line_count()
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fetcher_hit_and_miss() {
        let mut sdram = vec![0u16; 1024];
        // Write a recognizable RGB565 white pixel at block 0.
        for i in 0..16 {
            sdram[i] = 0xFFFF;
        }

        let mut fetcher = ConcreteFetcher::new();

        // First fetch: miss.
        let block = fetcher.get_block(0, 0, 0, 0, TexFormatE::Rgb565, &sdram);
        assert_eq!(fetcher.cache_stats().misses, 1);
        assert_eq!(fetcher.cache_stats().hits, 0);
        // Verify white pixel (RGB565 0xFFFF → UQ1.8 all 0x100).
        assert_eq!(block[0].r.to_bits(), 0x100);

        // Second fetch: hit.
        let _block = fetcher.get_block(0, 0, 0, 0, TexFormatE::Rgb565, &sdram);
        assert_eq!(fetcher.cache_stats().hits, 1);
        assert_eq!(fetcher.cache_stats().misses, 1);
    }

    #[test]
    fn fetcher_invalidation() {
        let sdram = vec![0u16; 1024];
        let mut fetcher = ConcreteFetcher::new();

        fetcher.get_block(0, 0, 0, 0, TexFormatE::Rgb565, &sdram);
        assert_eq!(fetcher.cached_block_count(), 1);

        fetcher.invalidate();
        assert_eq!(fetcher.cached_block_count(), 0);
    }
}
