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
// TODO: Implement fill_texture() with full INT-011 block-tiling transform
//   for linear pixel data input.
//
// burst_read() / burst_write() methods are implemented below, providing
// sequential word-level access matching the SDRAM controller burst interface.
// INT-032 burst lengths per texture format are supported.
//
// References:
//   INT-011 (SDRAM Memory Layout)
//   INT-014 (Texture Memory Layout)
//   INT-032 (Texture Cache Architecture)

#include "sdram_model.h"

#include <cstring>
#include <cstdio>

SdramModel::SdramModel(uint32_t num_words)
    : mem_(new uint16_t[num_words])
    , num_words_(num_words)
{
    // Initialize to zero (simulates power-on state; real SDRAM is undefined).
    std::memset(mem_, 0, num_words * sizeof(uint16_t));
}

SdramModel::~SdramModel() {
    delete[] mem_;
}

uint16_t SdramModel::read_word(uint32_t word_addr) const {
    if (word_addr >= num_words_) {
        return 0;
    }
    return mem_[word_addr];
}

void SdramModel::write_word(uint32_t word_addr, uint16_t data) {
    if (word_addr >= num_words_) {
        return;
    }
    mem_[word_addr] = data;
}

void SdramModel::upload_raw(uint32_t base_word_addr, const uint8_t* data,
                            size_t size_bytes) {
    // Write raw bytes as 16-bit little-endian words.
    size_t num_words = size_bytes / 2;
    for (size_t i = 0; i < num_words; i++) {
        uint16_t word = static_cast<uint16_t>(data[i * 2])
                      | (static_cast<uint16_t>(data[i * 2 + 1]) << 8);
        write_word(base_word_addr + static_cast<uint32_t>(i), word);
    }
}

void SdramModel::burst_read(uint32_t start_word_addr, uint16_t* buffer,
                             uint32_t count) const {
    for (uint32_t i = 0; i < count; i++) {
        buffer[i] = read_word(start_word_addr + i);
    }
}

void SdramModel::burst_write(uint32_t start_word_addr, const uint16_t* buffer,
                              uint32_t count) {
    for (uint32_t i = 0; i < count; i++) {
        write_word(start_word_addr + i, buffer[i]);
    }
}

void SdramModel::fill_texture(uint32_t base_word_addr, TexFormat fmt,
                               const uint8_t* pixel_data, size_t data_size) {
    // TODO: Implement full INT-011 4x4 block-tiling address transform.
    //
    // For block-compressed formats (BC1, BC2, BC3, BC4), the input data
    // is already in block order (each block is a self-contained unit),
    // so linear upload is correct.
    //
    // For uncompressed formats (RGB565, RGBA8888, R8), the input data
    // is in linear row-major order and must be rearranged into 4x4
    // block-tiled order per INT-011:
    //
    //   block_x    = pixel_x >> 2
    //   block_y    = pixel_y >> 2
    //   local_x    = pixel_x & 3
    //   local_y    = pixel_y & 3
    //   block_idx  = (block_y << (WIDTH_LOG2 - 2)) | block_x
    //   word_addr  = base_word + block_idx * 16 + (local_y * 4 + local_x)
    //
    // For now, upload linearly (sufficient for pre-tiled asset data from
    // the asset build tool).

    (void)fmt;  // Format will be used for tiling transform.
    upload_raw(base_word_addr, pixel_data, data_size);
}
