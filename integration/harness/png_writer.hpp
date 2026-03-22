// PNG image writer for the integration test harness.
//
// Converts an array of RGB565 pixels to 8-bit-per-channel RGB and writes
// a PNG file suitable for golden image comparison.
//
// PNG was chosen because:
//   - Lossless compression (no artifacts to complicate comparison).
//   - Much smaller than uncompressed formats (~25 KB vs ~920 KB for 640x480).
//   - Universally supported by image viewers and diff tools.
//
// Uses stb_image_write.h (public domain) for PNG encoding.
//
// RGB565 to RGB888 conversion follows INT-011 framebuffer format:
//   R8 = (R5 << 3) | (R5 >> 2)   -- replicate top bits for full range
//   G8 = (G6 << 2) | (G6 >> 4)
//   B8 = (B5 << 3) | (B5 >> 2)

#pragma once

#include <cstdint>
#include <span>
#include <stdexcept>

namespace png_writer {

/// 8-bit RGB color channels unpacked from a single RGB565 pixel.
struct Rgb888 {
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

/// Write a PNG file from an array of RGB565 pixels.
///
/// @param filename     Output file path.
/// @param width        Image width in pixels.
/// @param height       Image height in pixels.
/// @param framebuffer  Span of width * height RGB565 pixels in row-major
///                     order (top-left pixel first).
/// @throws std::runtime_error on failure.
void write_png(const char* filename, int width, int height, std::span<const uint16_t> framebuffer);

/// Convert a single RGB565 pixel to separate R, G, B 8-bit channels.
///
/// Uses MSB replication to expand 5/6-bit channels to full 8-bit range:
///   R5 -> R8: (R5 << 3) | (R5 >> 2)
///   G6 -> G8: (G6 << 2) | (G6 >> 4)
///   B5 -> B8: (B5 << 3) | (B5 >> 2)
///
/// @param rgb565  Input pixel in RGB565 format.
/// @return Rgb888 struct with r, g, b channels (0-255 each).
Rgb888 rgb565_to_rgb888(uint16_t rgb565);

} // namespace png_writer
