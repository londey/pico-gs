//! Block fetcher — orchestrates cache lookup, compressed fetch, and decode.
//!
//! The [`BlockFetcher`] trait provides the interface for obtaining decoded
//! 4×4 texel blocks.
//! [`ConcreteFetcher`] is the standard implementation that
//! owns a [`DecodedBlockProvider`] (decoded cache) and a
//! [`CompressedBlockProvider`] (compressed data cache), wiring them
//! together with the format decoders in `tex_decode`.
//!
//! # Data flow
//!
//! ```text
//! BlockFetcher::get_block()
//!   → DecodedBlockProvider::lookup() — hit? return
//!   → CompressedBlockProvider::fetch_compressed() — get raw SDRAM data
//!   → tex_decode::TexelDecoder::decode_block() — decompress to UQ1.8
//!   → DecodedBlockProvider::fill() — store in decoded cache
//!   → return decoded block
//! ```

use gpu_registers::components::tex_format_e::TexFormatE;

use super::tex_cache::{CacheStats, DecodedBlockProvider, TextureBlockCache};
use super::tex_compressed::{CompressedBlockCache, CompressedBlockProvider};
use super::tex_decode;
use super::texel::TexelUq18;

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

    /// Return decoded cache statistics.
    fn cache_stats(&self) -> &CacheStats;

    /// Return the number of valid decoded cache lines.
    fn cached_block_count(&self) -> usize;
}

// ── ConcreteFetcher ─────────────────────────────────────────────────────────

/// Standard block fetcher owning decoded and compressed caches.
///
/// Orchestrates the full fetch pipeline:
/// decoded cache lookup → compressed cache fetch → format decode → fill.
pub struct ConcreteFetcher {
    /// Decoded texel block cache (4-way set-associative, 64 sets).
    cache: TextureBlockCache,

    /// Compressed SDRAM data cache (DT-only optimization).
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

        // Miss: fetch compressed data, decode, fill.
        let bsw = tex_decode::block_size_words(format);
        let raw = self
            .compressed
            .fetch_compressed(base_words, block_index, bsw, sdram);
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
