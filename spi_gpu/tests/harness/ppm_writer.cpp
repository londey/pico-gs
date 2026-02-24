// PPM image writer implementation for the integration test harness.
//
// Writes binary P6 PPM files from RGB565 framebuffer data.
// This is a fully functional implementation (not a stub).
//
// PPM P6 format:
//   Line 1: "P6\n"
//   Line 2: "<width> <height>\n"
//   Line 3: "255\n"
//   Followed by: width * height * 3 bytes of binary RGB data
//
// References:
//   INT-011 (SDRAM Memory Layout) -- RGB565 framebuffer format:
//     [15:11] R (5 bits), [10:5] G (6 bits), [4:0] B (5 bits)

#include "ppm_writer.h"

#include <cstdio>

namespace ppm_writer {

void rgb565_to_rgb888(uint16_t rgb565, uint8_t& r, uint8_t& g, uint8_t& b) {
    // Extract 5/6/5 bit fields from the RGB565 pixel.
    uint8_t r5 = (rgb565 >> 11) & 0x1F;
    uint8_t g6 = (rgb565 >> 5)  & 0x3F;
    uint8_t b5 =  rgb565        & 0x1F;

    // Expand to 8-bit using MSB replication for full-range mapping.
    // This ensures 0x1F (max 5-bit) maps to 0xFF (max 8-bit) and
    // 0x00 maps to 0x00, with smooth linear interpolation between.
    //
    // R5 -> R8: (R5 << 3) | (R5 >> 2)
    //   Example: 0x1F (31) -> (31 << 3) | (31 >> 2) = 248 | 7 = 255
    //   Example: 0x10 (16) -> (16 << 3) | (16 >> 2) = 128 | 4 = 132
    //
    // G6 -> G8: (G6 << 2) | (G6 >> 4)
    //   Example: 0x3F (63) -> (63 << 2) | (63 >> 4) = 252 | 3 = 255
    //   Example: 0x20 (32) -> (32 << 2) | (32 >> 4) = 128 | 2 = 130
    //
    // B5 -> B8: same as R5.
    r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
    g = static_cast<uint8_t>((g6 << 2) | (g6 >> 4));
    b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
}

bool write_ppm(const char* filename, int width, int height,
               const uint16_t* framebuffer) {
    if (!filename || !framebuffer || width <= 0 || height <= 0) {
        return false;
    }

    FILE* fp = fopen(filename, "wb");
    if (!fp) {
        return false;
    }

    // Write PPM P6 header.
    fprintf(fp, "P6\n%d %d\n255\n", width, height);

    // Write pixel data, converting each RGB565 pixel to 3 bytes of RGB888.
    // Pixels are written in row-major order (top-left first), matching the
    // framebuffer layout.
    for (int i = 0; i < width * height; i++) {
        uint8_t r, g, b;
        rgb565_to_rgb888(framebuffer[i], r, g, b);

        uint8_t pixel[3] = { r, g, b };
        if (fwrite(pixel, 1, 3, fp) != 3) {
            fclose(fp);
            return false;
        }
    }

    fclose(fp);
    return true;
}

} // namespace ppm_writer
