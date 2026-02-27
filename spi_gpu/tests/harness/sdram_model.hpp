// Behavioral SDRAM model header for the integration test harness.
//
// This model simulates the W9825G6KH-6 SDRAM (32 MB, 16-bit data bus)
// as a simple flat array of 16-bit words, with helper methods for the
// 4x4 block-tiled address layout defined in INT-011.
//
// The model is a *behavioral* stub: it provides correct read/write
// semantics without modeling SDRAM timing (ACTIVATE, CAS latency, etc.).
// Cycle-accurate timing will be added when the full Verilator harness
// connects to the SDRAM controller ports.
//
// References:
//   INT-011 (SDRAM Memory Layout) -- 4x4 block-tiled address layout,
//       memory map, surface base addresses.
//   INT-014 (Texture Memory Layout) -- Texture format block sizes and
//       block-tiled organization.
//   INT-032 (Texture Cache Architecture) -- Cache miss burst lengths
//       per texture format:
//
//       | Format   | burst_len (16-bit words) | Bytes |
//       |----------|--------------------------|-------|
//       | BC1      | 4                        | 8     |
//       | BC2      | 8                        | 16    |
//       | BC3      | 8                        | 16    |
//       | BC4      | 4                        | 8     |
//       | RGB565   | 16                       | 32    |
//       | RGBA8888 | 32                       | 64    |
//       | R8       | 8                        | 16    |
//
//       The behavioral model must serve data at these burst lengths when
//       the Verilated memory arbiter issues burst read requests during
//       texture cache miss fills.

#pragma once

#include <cstdint>
#include <cstddef>

/// Texture format codes matching INT-014 TEXn_CFG.FORMAT field encoding.
enum class TexFormat : uint8_t {
    BC1      = 0,   ///< 4 bpp, 8 bytes per 4x4 block
    BC2      = 1,   ///< 8 bpp, 16 bytes per 4x4 block
    BC3      = 2,   ///< 8 bpp, 16 bytes per 4x4 block
    BC4      = 3,   ///< 4 bpp, 8 bytes per 4x4 block (single channel)
    RGB565   = 4,   ///< 16 bpp, 32 bytes per 4x4 block
    RGBA8888 = 5,   ///< 32 bpp, 64 bytes per 4x4 block
    R8       = 6,   ///< 8 bpp, 16 bytes per 4x4 block (single channel)
};

/// INT-032 burst lengths per format (in 16-bit words).
/// These are the number of sequential 16-bit words the texture cache
/// reads from SDRAM on a cache miss fill.
static constexpr uint8_t BURST_LEN_BC1      = 4;
static constexpr uint8_t BURST_LEN_BC2      = 8;
static constexpr uint8_t BURST_LEN_BC3      = 8;
static constexpr uint8_t BURST_LEN_BC4      = 4;
static constexpr uint8_t BURST_LEN_RGB565   = 16;
static constexpr uint8_t BURST_LEN_RGBA8888 = 32;
static constexpr uint8_t BURST_LEN_R8       = 8;

/// Return the INT-032 burst length for a given texture format.
inline uint8_t burst_len_for_format(TexFormat fmt) {
    switch (fmt) {
        case TexFormat::BC1:      return BURST_LEN_BC1;
        case TexFormat::BC2:      return BURST_LEN_BC2;
        case TexFormat::BC3:      return BURST_LEN_BC3;
        case TexFormat::BC4:      return BURST_LEN_BC4;
        case TexFormat::RGB565:   return BURST_LEN_RGB565;
        case TexFormat::RGBA8888: return BURST_LEN_RGBA8888;
        case TexFormat::R8:       return BURST_LEN_R8;
        default:                  return 0;
    }
}

/// Return the bytes per 4x4 block for a given texture format (INT-014).
inline uint8_t bytes_per_block(TexFormat fmt) {
    switch (fmt) {
        case TexFormat::BC1:      return 8;
        case TexFormat::BC2:      return 16;
        case TexFormat::BC3:      return 16;
        case TexFormat::BC4:      return 8;
        case TexFormat::RGB565:   return 32;
        case TexFormat::RGBA8888: return 64;
        case TexFormat::R8:       return 16;
        default:                  return 0;
    }
}

/// Behavioral SDRAM model.
///
/// Provides a flat array of 16-bit words with methods for word-level
/// read/write access and texture upload with INT-011 block-tiled layout.
class SdramModel {
public:
    /// Construct a model with the given number of 16-bit words.
    /// The standard SDRAM is 16M words (32 MB).
    explicit SdramModel(uint32_t num_words);

    /// Destructor.
    ~SdramModel();

    // Non-copyable.
    SdramModel(const SdramModel&) = delete;
    SdramModel& operator=(const SdramModel&) = delete;

    /// Read a 16-bit word at the given word address.
    /// Returns 0 for out-of-range addresses.
    uint16_t read_word(uint32_t word_addr) const;

    /// Write a 16-bit word at the given word address.
    /// Silently ignores out-of-range addresses.
    void write_word(uint32_t word_addr, uint16_t data);

    /// Upload raw texture block data into SDRAM.
    ///
    /// The data is written starting at base_word_addr (in 16-bit word
    /// units). The caller provides pre-tiled texture data (i.e., data
    /// already laid out in INT-011 4x4 block-tiled order, as produced
    /// by the asset build tool).
    ///
    /// @param base_word_addr  Starting word address in SDRAM.
    /// @param data            Pointer to raw texture bytes.
    /// @param size_bytes      Size of data in bytes.
    void upload_raw(uint32_t base_word_addr, const uint8_t* data,
                    size_t size_bytes);

    /// Fill a texture region with pixel data, converting from linear
    /// row-major pixel order to INT-011 4x4 block-tiled layout.
    ///
    /// This is the high-level texture upload function that performs the
    /// block-tiling address transformation.
    ///
    /// For block-compressed formats (BC1, BC2, BC3, BC4), input data is
    /// already in block order and is uploaded linearly via upload_raw().
    ///
    /// For uncompressed formats (RGB565, RGBA8888, R8), input data is in
    /// linear row-major pixel order and is rearranged into 4x4 block-tiled
    /// layout per INT-011.
    ///
    /// @param base_word_addr  SDRAM word address for the texture base.
    /// @param fmt             Texture format (determines bytes per pixel/block).
    /// @param pixel_data      Linear row-major pixel data.
    /// @param data_size       Size of pixel_data in bytes.
    /// @param width_log2      Log2 of texture width in pixels (e.g. 4 for 16px).
    void fill_texture(uint32_t base_word_addr, TexFormat fmt,
                      const uint8_t* pixel_data, size_t data_size,
                      uint32_t width_log2);

    /// Burst read a sequence of consecutive 16-bit words from the model.
    ///
    /// Reads `count` sequential 16-bit words starting at `start_word_addr`
    /// into the caller-supplied buffer. This models the SDRAM controller's
    /// sequential burst read as described in INT-032, where the texture
    /// cache issues burst reads of varying length per texture format.
    ///
    /// Out-of-range addresses read as 0. The buffer must be at least
    /// `count` elements large.
    ///
    /// @param start_word_addr  Starting 16-bit word address in SDRAM.
    /// @param buffer           Output buffer for read data.
    /// @param count            Number of 16-bit words to read.
    void burst_read(uint32_t start_word_addr, uint16_t* buffer,
                    uint32_t count) const;

    /// Burst write a sequence of consecutive 16-bit words into the model.
    ///
    /// Writes `count` sequential 16-bit words starting at `start_word_addr`
    /// from the caller-supplied buffer. This models the SDRAM controller's
    /// sequential burst write, used by the framebuffer write-back path.
    ///
    /// Out-of-range addresses are silently ignored. The buffer must be at
    /// least `count` elements large.
    ///
    /// @param start_word_addr  Starting 16-bit word address in SDRAM.
    /// @param buffer           Input buffer of data to write.
    /// @param count            Number of 16-bit words to write.
    void burst_write(uint32_t start_word_addr, const uint16_t* buffer,
                     uint32_t count);

    /// Return the total number of 16-bit words in the model.
    uint32_t size() const { return num_words_; }

private:
    uint16_t* mem_;
    uint32_t  num_words_;
};
