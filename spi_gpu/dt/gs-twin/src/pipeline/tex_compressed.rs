//! Compressed texture data cache — DT-only optimization layer.
//!
//! Caches raw (compressed or uncompressed) SDRAM block data before decoding,
//! avoiding redundant SDRAM reads when the same compressed block is accessed
//! by multiple bilinear taps or mip levels.
//!
//! # DT-only
//!
//! This layer has **no RTL analog** — the RTL reads compressed data directly
//! from SDRAM during each cache fill.
//! It exists purely to explore potential future RTL optimizations and to
//! reduce DT simulation overhead.

/// Provide raw compressed/uncompressed block data from SDRAM, with caching.
///
/// Implementations may cache the raw SDRAM words to avoid redundant reads,
/// or pass through directly to SDRAM with no caching.
pub trait CompressedBlockProvider {
    /// Fetch raw block data for a 4×4 texel block.
    ///
    /// Returns a slice of `block_size_words` u16 words containing the
    /// raw (possibly compressed) block data.
    ///
    /// # Arguments
    ///
    /// * `base_words` - Texture base address in u16 words.
    /// * `block_index` - Block index within the mip level (row-major).
    /// * `block_size_words` - Number of u16 words per block (format-dependent).
    /// * `sdram` - Flat SDRAM backing store.
    fn fetch_compressed(
        &mut self,
        base_words: u32,
        block_index: u32,
        block_size_words: u32,
        sdram: &[u16],
    ) -> &[u16];

    /// Invalidate all cached entries.
    fn invalidate(&mut self);
}

// ── Direct pass-through (no caching) ────────────────────────────────────────

/// Pass-through provider that reads directly from SDRAM with no caching.
///
/// This matches the RTL behavior where compressed data is fetched from
/// SDRAM on every cache miss with no intermediate compressed data cache.
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
        block_size_words: u32,
        sdram: &[u16],
    ) -> &[u16] {
        let offset = (base_words + block_index * block_size_words) as usize;
        let end = (offset + block_size_words as usize).min(sdram.len());
        self.buf.clear();
        if offset < sdram.len() {
            self.buf.extend_from_slice(&sdram[offset..end]);
        }
        // Pad with zeros if SDRAM is too small.
        while self.buf.len() < block_size_words as usize {
            self.buf.push(0);
        }
        &self.buf
    }

    fn invalidate(&mut self) {
        // No cached state to clear.
    }
}

// ── Cached compressed block provider ────────────────────────────────────────

/// Cache entry for compressed block data.
#[derive(Clone, Default)]
struct CompressedCacheLine {
    /// Tag: (base_words, block_index) uniquely identifies a block.
    base_words: u32,

    /// Block index within the mip level.
    block_index: u32,

    /// Valid bit.
    valid: bool,

    /// Raw SDRAM words for this block.
    data: Vec<u16>,
}

/// Number of cache entries in the direct-mapped compressed cache.
const COMPRESSED_CACHE_SETS: usize = 64;

/// Direct-mapped cache for raw compressed/uncompressed SDRAM block data.
///
/// DT-only optimization — avoids redundant SDRAM reads when the same
/// block is fetched multiple times (e.g., bilinear taps spanning a
/// block boundary).
///
/// Uses direct-mapped addressing with `block_index % SETS` as the set index.
pub struct CompressedBlockCache {
    /// Cache lines.
    lines: Vec<CompressedCacheLine>,

    /// Scratch buffer for returning slices.
    buf: Vec<u16>,

    /// Cumulative hit count.
    pub hits: u64,

    /// Cumulative miss count.
    pub misses: u64,
}

impl Default for CompressedBlockCache {
    fn default() -> Self {
        Self::new()
    }
}

impl CompressedBlockCache {
    /// Create a new empty compressed block cache.
    #[must_use]
    pub fn new() -> Self {
        Self {
            lines: vec![CompressedCacheLine::default(); COMPRESSED_CACHE_SETS],
            buf: Vec::with_capacity(32),
            hits: 0,
            misses: 0,
        }
    }

    /// Compute the set index for a given base address and block index.
    fn set_index(base_words: u32, block_index: u32) -> usize {
        // XOR-fold base and block_index for better distribution.
        ((base_words ^ block_index) as usize) % COMPRESSED_CACHE_SETS
    }
}

impl CompressedBlockProvider for CompressedBlockCache {
    fn fetch_compressed(
        &mut self,
        base_words: u32,
        block_index: u32,
        block_size_words: u32,
        sdram: &[u16],
    ) -> &[u16] {
        let set = Self::set_index(base_words, block_index);
        let line = &self.lines[set];

        if line.valid
            && line.base_words == base_words
            && line.block_index == block_index
            && line.data.len() == block_size_words as usize
        {
            self.hits += 1;
            return &self.lines[set].data;
        }

        // Miss: fetch from SDRAM and fill.
        self.misses += 1;
        let offset = (base_words + block_index * block_size_words) as usize;
        let end = (offset + block_size_words as usize).min(sdram.len());

        let line = &mut self.lines[set];
        line.data.clear();
        if offset < sdram.len() {
            line.data.extend_from_slice(&sdram[offset..end]);
        }
        while line.data.len() < block_size_words as usize {
            line.data.push(0);
        }
        line.base_words = base_words;
        line.block_index = block_index;
        line.valid = true;

        &self.lines[set].data
    }

    fn invalidate(&mut self) {
        for line in &mut self.lines {
            line.valid = false;
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direct_provider_returns_correct_data() {
        let sdram: Vec<u16> = (0..256).collect();
        let mut provider = DirectSdramProvider::new();

        // Fetch block at offset 0, 16 words.
        let data = provider.fetch_compressed(0, 0, 16, &sdram);
        assert_eq!(data.len(), 16);
        assert_eq!(data[0], 0);
        assert_eq!(data[15], 15);

        // Fetch block at offset 32.
        let data = provider.fetch_compressed(0, 2, 16, &sdram);
        assert_eq!(data[0], 32);
        assert_eq!(data[15], 47);
    }

    #[test]
    fn cached_provider_hit_and_miss() {
        let sdram: Vec<u16> = (0..256).collect();
        let mut cache = CompressedBlockCache::new();

        // First access: miss.
        let data = cache.fetch_compressed(0, 0, 16, &sdram);
        assert_eq!(data.len(), 16);
        assert_eq!(data[0], 0);
        assert_eq!(cache.misses, 1);
        assert_eq!(cache.hits, 0);

        // Second access: hit.
        let data = cache.fetch_compressed(0, 0, 16, &sdram);
        assert_eq!(data[0], 0);
        assert_eq!(cache.hits, 1);
        assert_eq!(cache.misses, 1);

        // Different block: miss.
        let data = cache.fetch_compressed(0, 1, 16, &sdram);
        assert_eq!(data[0], 16);
        assert_eq!(cache.misses, 2);
    }

    #[test]
    fn cached_provider_invalidation() {
        let sdram: Vec<u16> = (0..256).collect();
        let mut cache = CompressedBlockCache::new();

        cache.fetch_compressed(0, 0, 16, &sdram);
        assert_eq!(cache.misses, 1);

        cache.invalidate();

        // After invalidation, same block is a miss.
        cache.fetch_compressed(0, 0, 16, &sdram);
        assert_eq!(cache.misses, 2);
    }

    #[test]
    fn out_of_bounds_sdram_padded() {
        let sdram: Vec<u16> = vec![0xAAAA; 4];
        let mut provider = DirectSdramProvider::new();

        // Request 16 words but only 4 available at offset 0.
        let data = provider.fetch_compressed(0, 0, 16, &sdram);
        assert_eq!(data.len(), 16);
        assert_eq!(data[0], 0xAAAA);
        assert_eq!(data[3], 0xAAAA);
        assert_eq!(data[4], 0, "should be zero-padded");
    }
}
