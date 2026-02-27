// PNG image writer implementation for the integration test harness.
//
// Writes PNG files from RGB565 framebuffer data using stb_image_write.
//
// References:
//   INT-011 (SDRAM Memory Layout) -- RGB565 framebuffer format:
//     [15:11] R (5 bits), [10:5] G (6 bits), [4:0] B (5 bits)

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "png_writer.hpp"

#include "stb_image_write.h"

#include <algorithm>
#include <vector>

namespace png_writer {

Rgb888 rgb565_to_rgb888(uint16_t rgb565) {
    // Extract 5/6/5 bit fields from the RGB565 pixel.
    uint8_t r5 = (rgb565 >> 11) & 0x1F;
    uint8_t g6 = (rgb565 >> 5) & 0x3F;
    uint8_t b5 = rgb565 & 0x1F;

    // Expand to 8-bit using MSB replication for full-range mapping.
    // This ensures 0x1F (max 5-bit) maps to 0xFF (max 8-bit) and
    // 0x00 maps to 0x00, with smooth linear interpolation between.
    return Rgb888{
        .r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2)),
        .g = static_cast<uint8_t>((g6 << 2) | (g6 >> 4)),
        .b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2)),
    };
}

void write_png(const char* filename, int width, int height, std::span<const uint16_t> framebuffer) {
    if (!filename || width <= 0 || height <= 0) {
        throw std::runtime_error("write_png: invalid parameters");
    }

    // Convert RGB565 framebuffer to RGB888 buffer for stb_image_write.
    std::vector<uint8_t> rgb(framebuffer.size() * 3);

    // Transform each RGB565 pixel into three consecutive RGB888 bytes.
    std::ranges::for_each(framebuffer, [&rgb, i = std::size_t{0}](uint16_t pixel) mutable {
        auto [r, g, b] = rgb565_to_rgb888(pixel);
        rgb[i * 3] = r;
        rgb[i * 3 + 1] = g;
        rgb[i * 3 + 2] = b;
        ++i;
    });

    // Write PNG.  Stride = width * 3 bytes per row.
    int result = stbi_write_png(filename, width, height, 3, rgb.data(), width * 3);

    if (result == 0) {
        throw std::runtime_error("write_png: failed to write PNG file");
    }
}

} // namespace png_writer
