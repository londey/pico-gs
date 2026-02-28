// Behavioral SDRAM model implementation (stub).
//
// This is a minimal implementation that provides correct word-level
// read/write semantics. The timing-accurate SDRAM command protocol
// (ACTIVATE, READ with CAS latency, burst sequences, etc.) is not
// yet modeled -- this stub treats SDRAM as a simple flat memory array.
//
// TODO: Implement cycle-accurate SDRAM timing model:
//   - ACTIVATE latency (tRCD = 2 cycles at 100 MHz)
//   - CAS latency (CL=3)
//   - Sequential burst reads/writes with proper pipelining
//   - PRECHARGE timing (tRP = 2 cycles)
//   - Auto-refresh scheduling (8192 refreshes per 64 ms)
//   - Bank state tracking (4 banks)
//
// fill_texture() implements the full INT-011 4x4 block-tiling transform
// for linear pixel data input (RGB565, RGBA8888, R8 uncompressed formats).
// Block-compressed formats (BC1-BC4) are uploaded linearly via upload_raw().
//
// burst_read() / burst_write() methods are implemented below, providing
// sequential word-level access matching the SDRAM controller burst interface.
// INT-032 burst lengths per texture format are supported.
//
// References:
//   INT-011 (SDRAM Memory Layout)
//   INT-014 (Texture Memory Layout)
//   INT-032 (Texture Cache Architecture)

#include "sdram_model.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>

SdramModel::SdramModel(uint32_t num_words) : mem_(num_words, 0) {}

uint16_t SdramModel::read_word(uint32_t word_addr) const {
    if (word_addr >= mem_.size()) {
        return 0;
    }
    return mem_[word_addr];
}

void SdramModel::write_word(uint32_t word_addr, uint16_t data) {
    if (word_addr >= mem_.size()) {
        return;
    }
    mem_[word_addr] = data;
}

void SdramModel::upload_raw(uint32_t base_word_addr, std::span<const uint8_t> data) {
    // Write raw bytes as 16-bit little-endian words.
    size_t num_words = data.size() / 2;
    for (size_t i = 0; i < num_words; i++) {
        uint16_t word =
            static_cast<uint16_t>(data[i * 2]) | (static_cast<uint16_t>(data[i * 2 + 1]) << 8);
        write_word(base_word_addr + static_cast<uint32_t>(i), word);
    }
}

void SdramModel::burst_read(uint32_t start_word_addr, std::span<uint16_t> buffer) const {
    for (uint32_t i = 0; i < buffer.size(); i++) {
        buffer[i] = read_word(start_word_addr + i);
    }
}

void SdramModel::burst_write(uint32_t start_word_addr, std::span<const uint16_t> buffer) {
    for (uint32_t i = 0; i < buffer.size(); i++) {
        write_word(start_word_addr + i, buffer[i]);
    }
}

std::vector<uint16_t>
SdramModel::read_framebuffer(uint32_t base_word, int width_log2, int height) const {
    int width = 1 << width_log2;

    std::vector<uint16_t> fb(static_cast<size_t>(width) * height);

    // Flat linear readback matching the rasterizer's WRITE_PIXEL address formula.
    //
    // The rasterizer (UNIT-005) currently computes framebuffer byte addresses as:
    //   fb_addr = fb_base + y * 1280 + x * 2
    // where the byte stride 1280 = (y << 10) + (y << 8) corresponds to a
    // 640-pixel row pitch (each pixel is 16-bit RGB565 = 2 bytes).
    //
    // The SDRAM controller (via connect_sdram) maps byte addresses into the
    // SdramModel's word-address space such that word_addr equals the byte
    // address for even addresses.  Therefore:
    //   word_addr = base_word + y * 1280 + x * 2
    //
    // The width_log2 parameter determines how many columns are read per row
    // (the image width), which may be narrower than the 640-pixel stride.
    static constexpr uint32_t BYTE_STRIDE = 1280; // 640 pixels * 2 bytes
    for (int py = 0; py < height; ++py) {
        for (int px = 0; px < width; ++px) {
            uint32_t word_addr =
                base_word +
                static_cast<uint32_t>(py) * BYTE_STRIDE +
                static_cast<uint32_t>(px) * 2;

            fb[py * width + px] = read_word(word_addr);
        }
    }

    return fb;
}

void SdramModel::fill_texture(
    uint32_t base_word_addr, TexFormat fmt, std::span<const uint8_t> pixel_data, uint32_t width_log2
) {
    // Block-compressed formats (BC1, BC2, BC3, BC4): input data is already
    // in block order (each block is a self-contained unit), so linear
    // upload is correct.
    if (fmt == TexFormat::BC1 || fmt == TexFormat::BC2 || fmt == TexFormat::BC3 ||
        fmt == TexFormat::BC4) {
        upload_raw(base_word_addr, pixel_data);
        return;
    }

    // Uncompressed formats (RGB565, RGBA8888, R8): input data is in linear
    // row-major pixel order and must be rearranged into 4x4 block-tiled
    // layout per INT-011.
    //
    // INT-011 block-tiled address calculation:
    //   block_x   = pixel_x >> 2
    //   block_y   = pixel_y >> 2
    //   local_x   = pixel_x & 3
    //   local_y   = pixel_y & 3
    //   block_idx = (block_y << (WIDTH_LOG2 - 2)) | block_x
    //   word_addr = base_word + block_idx * 16 + (local_y * 4 + local_x)

    uint32_t width = 1u << width_log2;

    if (fmt == TexFormat::RGB565) {
        // RGB565: 2 bytes per pixel, one 16-bit SDRAM word per pixel.
        uint32_t height = static_cast<uint32_t>(pixel_data.size() / 2) / width;
        // Raw loop retained: reinterpret_cast span access with block-tiled
        // address arithmetic does not map cleanly to a standard algorithm.
        const auto* src = reinterpret_cast<const uint16_t*>(pixel_data.data());

        for (uint32_t y = 0; y < height; y++) {
            for (uint32_t x = 0; x < width; x++) {
                uint32_t block_x = x >> 2;
                uint32_t block_y = y >> 2;
                uint32_t local_x = x & 3;
                uint32_t local_y = y & 3;
                uint32_t block_idx = (block_y << (width_log2 - 2)) | block_x;
                uint32_t word_addr = base_word_addr + block_idx * 16 + (local_y * 4 + local_x);

                // Source pixel in linear row-major order (little-endian u16).
                uint16_t pixel = src[y * width + x];
                write_word(word_addr, pixel);
            }
        }
    } else if (fmt == TexFormat::RGBA8888) {
        // RGBA8888: 4 bytes per pixel, two 16-bit SDRAM words per pixel.
        // Per INT-014: each texel is a little-endian u32 stored as two
        // consecutive 16-bit words.  The 4x4 block contains 16 texels
        // = 32 words.  Each texel at position (local_x, local_y) within
        // the block occupies two consecutive word addresses:
        //   low_word_addr  = base + block_idx * 32 + (local_y * 4 + local_x) * 2
        //   high_word_addr = low_word_addr + 1
        uint32_t height = static_cast<uint32_t>(pixel_data.size() / 4) / width;
        // Raw loop retained: block-tiled scatter with dual-word writes per
        // texel does not map to a standard algorithm.
        const auto* src = reinterpret_cast<const uint32_t*>(pixel_data.data());

        for (uint32_t y = 0; y < height; y++) {
            for (uint32_t x = 0; x < width; x++) {
                uint32_t block_x = x >> 2;
                uint32_t block_y = y >> 2;
                uint32_t local_x = x & 3;
                uint32_t local_y = y & 3;
                uint32_t block_idx = (block_y << (width_log2 - 2)) | block_x;
                // 32 words per block for RGBA8888 (16 texels x 2 words each).
                uint32_t word_addr = base_word_addr + block_idx * 32 + (local_y * 4 + local_x) * 2;

                // Source pixel in linear row-major order (little-endian u32).
                uint32_t pixel = src[y * width + x];
                uint16_t low_word = static_cast<uint16_t>(pixel & 0xFFFF);
                uint16_t high_word = static_cast<uint16_t>(pixel >> 16);
                write_word(word_addr, low_word);
                write_word(word_addr + 1, high_word);
            }
        }
    } else if (fmt == TexFormat::R8) {
        // R8: 1 byte per pixel.  Each 4x4 block is 16 bytes = 8 SDRAM
        // words.  Two pixels share one 16-bit word (little-endian: even
        // pixel in low byte, odd pixel in high byte).
        //
        // Within a block, pixels are stored row-major.  Two adjacent
        // pixels in the x-direction share a word:
        //   word_offset = (local_y * 4 + local_x) / 2
        //   byte_lane   = (local_y * 4 + local_x) % 2
        //
        // Raw loop retained: read-modify-write with block-tiled scatter
        // and per-byte lane selection does not map to a standard algorithm.
        uint32_t height = static_cast<uint32_t>(pixel_data.size()) / width;

        for (uint32_t y = 0; y < height; y++) {
            for (uint32_t x = 0; x < width; x++) {
                uint32_t block_x = x >> 2;
                uint32_t block_y = y >> 2;
                uint32_t local_x = x & 3;
                uint32_t local_y = y & 3;
                uint32_t block_idx = (block_y << (width_log2 - 2)) | block_x;
                uint32_t texel_idx = local_y * 4 + local_x;
                // 8 words per block for R8 (16 bytes / 2 bytes per word).
                uint32_t word_addr = base_word_addr + block_idx * 8 + texel_idx / 2;

                uint8_t pixel = pixel_data[y * width + x];

                // Read-modify-write to place the byte in the correct lane.
                uint16_t existing = read_word(word_addr);
                if ((texel_idx & 1) == 0) {
                    // Even texel index: low byte
                    existing = (existing & 0xFF00) | pixel;
                } else {
                    // Odd texel index: high byte
                    existing = (existing & 0x00FF) | (static_cast<uint16_t>(pixel) << 8);
                }
                write_word(word_addr, existing);
            }
        }
    } else {
        // Unknown format -- should not be reachable since the switch in
        // burst_len_for_format/bytes_per_block covers all enum values.
        fprintf(
            stderr,
            "WARNING: fill_texture: unknown format %u, "
            "falling back to linear upload.\n",
            static_cast<unsigned>(fmt)
        );
        upload_raw(base_word_addr, pixel_data);
    }
}
