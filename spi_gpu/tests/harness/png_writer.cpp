// PNG image writer implementation for the integration test harness.
//
// Writes PNG files from RGB565 framebuffer data using stb_image_write.
//
// References:
//   INT-011 (SDRAM Memory Layout) -- RGB565 framebuffer format:
//     [15:11] R (5 bits), [10:5] G (6 bits), [4:0] B (5 bits)

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include "png_writer.h"

#include <cstdlib>

namespace png_writer {

void rgb565_to_rgb888(uint16_t rgb565, uint8_t& r, uint8_t& g, uint8_t& b) {
    // Extract 5/6/5 bit fields from the RGB565 pixel.
    uint8_t r5 = (rgb565 >> 11) & 0x1F;
    uint8_t g6 = (rgb565 >> 5)  & 0x3F;
    uint8_t b5 =  rgb565        & 0x1F;

    // Expand to 8-bit using MSB replication for full-range mapping.
    // This ensures 0x1F (max 5-bit) maps to 0xFF (max 8-bit) and
    // 0x00 maps to 0x00, with smooth linear interpolation between.
    r = static_cast<uint8_t>((r5 << 3) | (r5 >> 2));
    g = static_cast<uint8_t>((g6 << 2) | (g6 >> 4));
    b = static_cast<uint8_t>((b5 << 3) | (b5 >> 2));
}

bool write_png(const char* filename, int width, int height,
               const uint16_t* framebuffer) {
    if (!filename || !framebuffer || width <= 0 || height <= 0) {
        return false;
    }

    // Convert RGB565 framebuffer to RGB888 buffer for stb_image_write.
    int pixel_count = width * height;
    uint8_t* rgb = static_cast<uint8_t*>(malloc(pixel_count * 3));
    if (!rgb) {
        return false;
    }

    for (int i = 0; i < pixel_count; i++) {
        rgb565_to_rgb888(framebuffer[i], rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]);
    }

    // Write PNG.  Stride = width * 3 bytes per row.
    int result = stbi_write_png(filename, width, height, 3, rgb, width * 3);

    free(rgb);
    return result != 0;
}

} // namespace png_writer
