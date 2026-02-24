// PPM image writer for the integration test harness.
//
// Converts an array of RGB565 pixels to 8-bit-per-channel RGB and writes
// a binary P6 PPM file suitable for golden image comparison.
//
// PPM (Portable Pixmap) format was chosen because:
//   - Simple binary format with no compression or library dependencies.
//   - Human-readable header (width, height, max color value).
//   - Widely supported by image viewers and diff tools.
//   - Lossless (no compression artifacts to complicate comparison).
//
// RGB565 to RGB888 conversion follows INT-011 framebuffer format:
//   R8 = (R5 << 3) | (R5 >> 2)   -- replicate top bits for full range
//   G8 = (G6 << 2) | (G6 >> 4)
//   B8 = (B5 << 3) | (B5 >> 2)

#ifndef PPM_WRITER_H
#define PPM_WRITER_H

#include <cstdint>

namespace ppm_writer {

/// Write a binary P6 PPM file from an array of RGB565 pixels.
///
/// @param filename     Output file path.
/// @param width        Image width in pixels.
/// @param height       Image height in pixels.
/// @param framebuffer  Array of width * height RGB565 pixels in row-major
///                     order (top-left pixel first).
/// @return true on success, false on file I/O error.
bool write_ppm(const char* filename, int width, int height,
               const uint16_t* framebuffer);

/// Convert a single RGB565 pixel to separate R, G, B 8-bit channels.
///
/// Uses MSB replication to expand 5/6-bit channels to full 8-bit range:
///   R5 -> R8: (R5 << 3) | (R5 >> 2)
///   G6 -> G8: (G6 << 2) | (G6 >> 4)
///   B5 -> B8: (B5 << 3) | (B5 >> 2)
///
/// @param rgb565  Input pixel in RGB565 format.
/// @param r       Output red channel (0-255).
/// @param g       Output green channel (0-255).
/// @param b       Output blue channel (0-255).
void rgb565_to_rgb888(uint16_t rgb565, uint8_t& r, uint8_t& g, uint8_t& b);

} // namespace ppm_writer

#endif // PPM_WRITER_H
