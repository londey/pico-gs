"""Pure Python BC1-BC4 block compression encoder and decoder.

Deterministic, spec-compliant implementation for generating test textures.
Not quality-optimized — uses simple min/max endpoint selection.

Block formats match the RTL decoders in spi_gpu/src/render/texture_bc*.sv
and the SDRAM layout defined in INT-014 (Texture Memory Layout).

All blocks are 4x4 texels, stored as little-endian words in SDRAM.
Texel ordering within a block is row-major: index = y*4 + x.
"""

from __future__ import annotations

import struct
from typing import List, Tuple


# ---------------------------------------------------------------------------
# RGB565 helpers
# ---------------------------------------------------------------------------

def rgb888_to_rgb565(r: int, g: int, b: int) -> int:
    """Convert 8-bit RGB to packed RGB565."""
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def rgb565_to_rgb888(c: int) -> Tuple[int, int, int]:
    """Unpack RGB565 to 8-bit RGB (no expansion, raw 5/6/5 values)."""
    r5 = (c >> 11) & 0x1F
    g6 = (c >> 5) & 0x3F
    b5 = c & 0x1F
    return (r5, g6, b5)


def rgb565_components(c: int) -> Tuple[int, int, int]:
    """Extract R5, G6, B5 components from RGB565."""
    return ((c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F)


# ---------------------------------------------------------------------------
# BC1 color block interpolation (matches RTL exactly)
# ---------------------------------------------------------------------------

def bc1_palette(color0: int, color1: int, four_color: bool) -> List[int]:
    """Generate BC1 color palette as 4 RGB565 values.

    Interpolation matches texture_bc1.sv exactly:
      1/3: (2*C0 + C1 + 1) / 3  per channel
      2/3: (C0 + 2*C1 + 1) / 3  per channel
      1/2: (C0 + C1 + 1) / 2    per channel
    """
    c0_r, c0_g, c0_b = rgb565_components(color0)
    c1_r, c1_g, c1_b = rgb565_components(color1)

    pal = [color0, color1, 0, 0]

    if four_color:
        # Entry 2: lerp(C0, C1, 1/3)
        r2 = (2 * c0_r + c1_r + 1) // 3
        g2 = (2 * c0_g + c1_g + 1) // 3
        b2 = (2 * c0_b + c1_b + 1) // 3
        pal[2] = (r2 << 11) | (g2 << 5) | b2

        # Entry 3: lerp(C0, C1, 2/3)
        r3 = (c0_r + 2 * c1_r + 1) // 3
        g3 = (c0_g + 2 * c1_g + 1) // 3
        b3 = (c0_b + 2 * c1_b + 1) // 3
        pal[3] = (r3 << 11) | (g3 << 5) | b3
    else:
        # Entry 2: lerp(C0, C1, 1/2)
        r2 = (c0_r + c1_r + 1) >> 1
        g2 = (c0_g + c1_g + 1) >> 1
        b2 = (c0_b + c1_b + 1) >> 1
        pal[2] = (r2 << 11) | (g2 << 5) | b2

        # Entry 3: transparent black
        pal[3] = 0x0000

    return pal


def _color_distance_sq(c0: int, c1: int) -> int:
    """Squared distance between two RGB565 colors in component space."""
    r0, g0, b0 = rgb565_components(c0)
    r1, g1, b1 = rgb565_components(c1)
    return (r0 - r1) ** 2 + (g0 - g1) ** 2 + (b0 - b1) ** 2


def _find_best_index(color: int, palette: List[int], num_entries: int) -> int:
    """Find palette index with minimum squared distance to color."""
    best_idx = 0
    best_dist = _color_distance_sq(color, palette[0])
    for i in range(1, num_entries):
        d = _color_distance_sq(color, palette[i])
        if d < best_dist:
            best_dist = d
            best_idx = i
    return best_idx


# ---------------------------------------------------------------------------
# BC1 encoder / decoder
# ---------------------------------------------------------------------------

def bc1_compress_block(pixels_rgb565: List[int]) -> int:
    """Compress a 4x4 block of RGB565 texels to BC1 (64-bit).

    Args:
        pixels_rgb565: 16 RGB565 values in row-major order (y*4 + x).

    Returns:
        64-bit BC1 block: [15:0]=color0, [31:16]=color1, [63:32]=indices.
        Always uses 4-color opaque mode (color0 > color1).
    """
    assert len(pixels_rgb565) == 16

    # Find min/max endpoints in RGB565 space
    color0 = max(pixels_rgb565)
    color1 = min(pixels_rgb565)

    # Ensure 4-color opaque mode: color0 > color1
    if color0 == color1:
        # Solid block: all texels map to index 0
        return color0 | (color1 << 16)

    # Generate palette and find best index per texel
    palette = bc1_palette(color0, color1, four_color=True)
    indices = 0
    for i in range(16):
        idx = _find_best_index(pixels_rgb565[i], palette, 4)
        indices |= idx << (i * 2)

    return color0 | (color1 << 16) | (indices << 32)


def bc1_decode_texel(block: int, texel_idx: int) -> Tuple[int, int]:
    """Decode one texel from a BC1 block.

    Returns:
        (rgb565, alpha2): decoded color and 2-bit alpha.
    """
    color0 = block & 0xFFFF
    color1 = (block >> 16) & 0xFFFF
    indices = (block >> 32) & 0xFFFFFFFF

    idx = (indices >> (texel_idx * 2)) & 0x3
    four_color = color0 > color1
    palette = bc1_palette(color0, color1, four_color)

    if four_color:
        return (palette[idx], 0x3)  # all opaque
    else:
        if idx == 3:
            return (0x0000, 0x0)  # transparent black
        return (palette[idx], 0x3)  # opaque


# ---------------------------------------------------------------------------
# Alpha block encoder / decoder (shared by BC3 alpha and BC4 red)
# ---------------------------------------------------------------------------

def _alpha_palette(alpha0: int, alpha1: int) -> List[int]:
    """Generate 8-entry alpha palette matching BC3/BC4 RTL.

    Interpolation matches texture_bc3.sv / texture_bc4.sv exactly:
      if alpha0 > alpha1: 8-entry interpolated
        pal[i] = ((7-i)*a0 + i*a1 + 3) / 7   for i in 2..7
      else: 6-entry interpolated + 0 and 255
        pal[i] = ((5-i)*a0 + i*a1 + 2) / 5   for i in 2..5  (adjusted indices)
    """
    pal = [alpha0, alpha1, 0, 0, 0, 0, 0, 0]

    if alpha0 > alpha1:
        # 8-entry mode
        pal[2] = (6 * alpha0 + 1 * alpha1 + 3) // 7
        pal[3] = (5 * alpha0 + 2 * alpha1 + 3) // 7
        pal[4] = (4 * alpha0 + 3 * alpha1 + 3) // 7
        pal[5] = (3 * alpha0 + 4 * alpha1 + 3) // 7
        pal[6] = (2 * alpha0 + 5 * alpha1 + 3) // 7
        pal[7] = (1 * alpha0 + 6 * alpha1 + 3) // 7
    else:
        # 6-entry mode + 0 and 255
        pal[2] = (4 * alpha0 + 1 * alpha1 + 2) // 5
        pal[3] = (3 * alpha0 + 2 * alpha1 + 2) // 5
        pal[4] = (2 * alpha0 + 3 * alpha1 + 2) // 5
        pal[5] = (1 * alpha0 + 4 * alpha1 + 2) // 5
        pal[6] = 0
        pal[7] = 255

    return pal


def _find_best_alpha_index(value: int, palette: List[int],
                           num_entries: int) -> int:
    """Find palette index minimizing |value - palette[i]|."""
    best_idx = 0
    best_dist = abs(value - palette[0])
    for i in range(1, num_entries):
        d = abs(value - palette[i])
        if d < best_dist:
            best_dist = d
            best_idx = i
    return best_idx


def _compress_alpha_block(values: List[int]) -> int:
    """Compress 16 u8 values to a 64-bit alpha/red block.

    Layout: [7:0]=alpha0, [15:8]=alpha1, [63:16]=48-bit index table.
    Uses 8-entry interpolated mode (alpha0 > alpha1) when possible.

    Args:
        values: 16 u8 values in row-major order.

    Returns:
        64-bit alpha block.
    """
    assert len(values) == 16

    alpha0 = max(values)
    alpha1 = min(values)

    # Ensure 8-entry mode: alpha0 > alpha1
    if alpha0 == alpha1:
        # Solid block: all texels map to index 0
        return alpha0 | (alpha1 << 8)

    palette = _alpha_palette(alpha0, alpha1)
    num_entries = 8 if alpha0 > alpha1 else 8  # always 8 with our ordering

    indices = 0
    for i in range(16):
        idx = _find_best_alpha_index(values[i], palette, num_entries)
        indices |= idx << (i * 3)

    return alpha0 | (alpha1 << 8) | (indices << 16)


def _decode_alpha_texel(block: int, texel_idx: int) -> int:
    """Decode one u8 value from an alpha/red block."""
    alpha0 = block & 0xFF
    alpha1 = (block >> 8) & 0xFF

    bit_offset = 16 + texel_idx * 3
    idx = (block >> bit_offset) & 0x7

    palette = _alpha_palette(alpha0, alpha1)
    return palette[idx] & 0xFF


# ---------------------------------------------------------------------------
# BC2 encoder / decoder
# ---------------------------------------------------------------------------

def bc2_compress_block(pixels_rgb565: List[int],
                       alphas: List[int]) -> Tuple[int, int]:
    """Compress a 4x4 block to BC2 (128-bit = two 64-bit words).

    Args:
        pixels_rgb565: 16 RGB565 values in row-major order.
        alphas: 16 u8 alpha values in row-major order.

    Returns:
        (low64, high64): low = alpha data, high = BC1 color block.
        BC2 always uses 4-color opaque mode for the color block.
    """
    assert len(pixels_rgb565) == 16
    assert len(alphas) == 16

    # Alpha: 4 bits per texel, packed into 64-bit word.
    # Row y, col x: 4 bits at bit_offset = y*16 + x*4.
    alpha_data = 0
    for i in range(16):
        x = i & 3
        y = i >> 2
        a4 = (alphas[i] >> 4) & 0xF  # truncate u8 to 4-bit
        bit_offset = y * 16 + x * 4
        alpha_data |= a4 << bit_offset

    # Color block: BC1 in forced 4-color opaque mode
    color0 = max(pixels_rgb565)
    color1 = min(pixels_rgb565)

    if color0 == color1:
        color_block = color0 | (color1 << 16)
    else:
        palette = bc1_palette(color0, color1, four_color=True)
        indices = 0
        for i in range(16):
            idx = _find_best_index(pixels_rgb565[i], palette, 4)
            indices |= idx << (i * 2)
        color_block = color0 | (color1 << 16) | (indices << 32)

    return (alpha_data, color_block)


def bc2_decode_texel(low64: int, high64: int,
                     texel_idx: int) -> Tuple[int, int]:
    """Decode one texel from a BC2 block.

    Returns:
        (rgb565, alpha2): decoded color and 2-bit alpha.
    """
    # Alpha: extract 4-bit value, truncate to A2 = A4[3:2]
    x = texel_idx & 3
    y = texel_idx >> 2
    bit_offset = y * 16 + x * 4
    a4 = (low64 >> bit_offset) & 0xF
    alpha2 = (a4 >> 2) & 0x3

    # Color: forced 4-color opaque
    color0 = high64 & 0xFFFF
    color1 = (high64 >> 16) & 0xFFFF
    indices = (high64 >> 32) & 0xFFFFFFFF
    idx = (indices >> (texel_idx * 2)) & 0x3

    palette = bc1_palette(color0, color1, four_color=True)
    return (palette[idx], alpha2)


# ---------------------------------------------------------------------------
# BC3 encoder / decoder
# ---------------------------------------------------------------------------

def bc3_compress_block(pixels_rgb565: List[int],
                       alphas: List[int]) -> Tuple[int, int]:
    """Compress a 4x4 block to BC3 (128-bit = two 64-bit words).

    Args:
        pixels_rgb565: 16 RGB565 values in row-major order.
        alphas: 16 u8 alpha values in row-major order.

    Returns:
        (low64, high64): low = alpha block, high = BC1 color block.
        BC3 always uses 4-color opaque mode for the color block.
    """
    assert len(pixels_rgb565) == 16
    assert len(alphas) == 16

    # Alpha block (same format as BC4)
    alpha_block = _compress_alpha_block(alphas)

    # Color block: BC1 in forced 4-color opaque mode
    color0 = max(pixels_rgb565)
    color1 = min(pixels_rgb565)

    if color0 == color1:
        color_block = color0 | (color1 << 16)
    else:
        palette = bc1_palette(color0, color1, four_color=True)
        indices = 0
        for i in range(16):
            idx = _find_best_index(pixels_rgb565[i], palette, 4)
            indices |= idx << (i * 2)
        color_block = color0 | (color1 << 16) | (indices << 32)

    return (alpha_block, color_block)


def bc3_decode_texel(low64: int, high64: int,
                     texel_idx: int) -> Tuple[int, int]:
    """Decode one texel from a BC3 block.

    Returns:
        (rgb565, alpha2): decoded color and 2-bit alpha (A8[7:6]).
    """
    # Alpha block decode
    alpha8 = _decode_alpha_texel(low64, texel_idx)
    alpha2 = (alpha8 >> 6) & 0x3

    # Color: forced 4-color opaque
    color0 = high64 & 0xFFFF
    color1 = (high64 >> 16) & 0xFFFF
    indices = (high64 >> 32) & 0xFFFFFFFF
    idx = (indices >> (texel_idx * 2)) & 0x3

    palette = bc1_palette(color0, color1, four_color=True)
    return (palette[idx], alpha2)


# ---------------------------------------------------------------------------
# BC4 encoder / decoder
# ---------------------------------------------------------------------------

def bc4_compress_block(red_values: List[int]) -> int:
    """Compress a 4x4 block of u8 red values to BC4 (64-bit).

    Args:
        red_values: 16 u8 values in row-major order.

    Returns:
        64-bit BC4 block (same format as BC3 alpha block).
    """
    return _compress_alpha_block(red_values)


def bc4_decode_texel(block: int, texel_idx: int) -> Tuple[int, int]:
    """Decode one texel from a BC4 block.

    Returns:
        (rgb565, alpha2): R replicated to RGB, always opaque (A2=3).
        INT-032: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
    """
    red8 = _decode_alpha_texel(block, texel_idx)
    r5 = (red8 >> 3) & 0x1F
    g6 = (red8 >> 2) & 0x3F
    b5 = (red8 >> 3) & 0x1F
    rgb565 = (r5 << 11) | (g6 << 5) | b5
    return (rgb565, 0x3)


# ---------------------------------------------------------------------------
# Full-image compression
# ---------------------------------------------------------------------------

# Texture format constants (matching TexFormatE)
FMT_BC1 = 0
FMT_BC2 = 1
FMT_BC3 = 2
FMT_BC4 = 3

# Words per 4x4 block in SDRAM (u16 words)
WORDS_PER_BLOCK = {
    FMT_BC1: 4,   # 8 bytes
    FMT_BC2: 8,   # 16 bytes
    FMT_BC3: 8,   # 16 bytes
    FMT_BC4: 4,   # 8 bytes
}


def compress_image_bc1(pixels_rgb565: List[List[int]],
                       width: int, height: int) -> List[int]:
    """Compress an RGB565 image to BC1, returning SDRAM words.

    Args:
        pixels_rgb565: 2D array [y][x] of RGB565 values.
        width: image width (must be multiple of 4).
        height: image height (must be multiple of 4).

    Returns:
        List of u16 SDRAM words in block-sequential order.
    """
    assert width % 4 == 0 and height % 4 == 0
    words = []

    for by in range(height // 4):
        for bx in range(width // 4):
            block_pixels = []
            for ly in range(4):
                for lx in range(4):
                    block_pixels.append(pixels_rgb565[by * 4 + ly][bx * 4 + lx])
            block64 = bc1_compress_block(block_pixels)
            # 64-bit block → 4 u16 words (little-endian)
            words.append(block64 & 0xFFFF)
            words.append((block64 >> 16) & 0xFFFF)
            words.append((block64 >> 32) & 0xFFFF)
            words.append((block64 >> 48) & 0xFFFF)

    return words


def compress_image_bc2(pixels_rgb565: List[List[int]],
                       alphas: List[List[int]],
                       width: int, height: int) -> List[int]:
    """Compress an RGBA image to BC2, returning SDRAM words.

    Args:
        pixels_rgb565: 2D array [y][x] of RGB565 values.
        alphas: 2D array [y][x] of u8 alpha values.
        width: image width (must be multiple of 4).
        height: image height (must be multiple of 4).

    Returns:
        List of u16 SDRAM words in block-sequential order.
    """
    assert width % 4 == 0 and height % 4 == 0
    words = []

    for by in range(height // 4):
        for bx in range(width // 4):
            block_pixels = []
            block_alphas = []
            for ly in range(4):
                for lx in range(4):
                    block_pixels.append(pixels_rgb565[by * 4 + ly][bx * 4 + lx])
                    block_alphas.append(alphas[by * 4 + ly][bx * 4 + lx])
            low64, high64 = bc2_compress_block(block_pixels, block_alphas)
            # 128-bit block → 8 u16 words
            for shift in range(0, 64, 16):
                words.append((low64 >> shift) & 0xFFFF)
            for shift in range(0, 64, 16):
                words.append((high64 >> shift) & 0xFFFF)

    return words


def compress_image_bc3(pixels_rgb565: List[List[int]],
                       alphas: List[List[int]],
                       width: int, height: int) -> List[int]:
    """Compress an RGBA image to BC3, returning SDRAM words.

    Same args and return as compress_image_bc2.
    """
    assert width % 4 == 0 and height % 4 == 0
    words = []

    for by in range(height // 4):
        for bx in range(width // 4):
            block_pixels = []
            block_alphas = []
            for ly in range(4):
                for lx in range(4):
                    block_pixels.append(pixels_rgb565[by * 4 + ly][bx * 4 + lx])
                    block_alphas.append(alphas[by * 4 + ly][bx * 4 + lx])
            low64, high64 = bc3_compress_block(block_pixels, block_alphas)
            for shift in range(0, 64, 16):
                words.append((low64 >> shift) & 0xFFFF)
            for shift in range(0, 64, 16):
                words.append((high64 >> shift) & 0xFFFF)

    return words


def compress_image_bc4(red_values: List[List[int]],
                       width: int, height: int) -> List[int]:
    """Compress a single-channel image to BC4, returning SDRAM words.

    Args:
        red_values: 2D array [y][x] of u8 values.
        width: image width (must be multiple of 4).
        height: image height (must be multiple of 4).

    Returns:
        List of u16 SDRAM words in block-sequential order.
    """
    assert width % 4 == 0 and height % 4 == 0
    words = []

    for by in range(height // 4):
        for bx in range(width // 4):
            block_values = []
            for ly in range(4):
                for lx in range(4):
                    block_values.append(red_values[by * 4 + ly][bx * 4 + lx])
            block64 = bc4_compress_block(block_values)
            words.append(block64 & 0xFFFF)
            words.append((block64 >> 16) & 0xFFFF)
            words.append((block64 >> 32) & 0xFFFF)
            words.append((block64 >> 48) & 0xFFFF)

    return words


# ---------------------------------------------------------------------------
# Unit tests
# ---------------------------------------------------------------------------

def _test_bc1_solid_block():
    """BC1: solid color block encodes/decodes correctly."""
    color = rgb888_to_rgb565(128, 64, 32)
    pixels = [color] * 16
    block = bc1_compress_block(pixels)
    for i in range(16):
        decoded, alpha = bc1_decode_texel(block, i)
        assert decoded == color, f"BC1 solid: texel {i} decoded 0x{decoded:04X} != 0x{color:04X}"
        assert alpha == 3, f"BC1 solid: texel {i} alpha {alpha} != 3"


def _test_bc1_two_color_block():
    """BC1: two-color block roundtrips through encode/decode."""
    c0 = rgb888_to_rgb565(255, 0, 0)  # red
    c1 = rgb888_to_rgb565(0, 0, 255)  # blue
    pixels = [c0 if i < 8 else c1 for i in range(16)]
    block = bc1_compress_block(pixels)
    for i in range(16):
        decoded, alpha = bc1_decode_texel(block, i)
        expected = c0 if i < 8 else c1
        assert decoded == expected, (
            f"BC1 two-color: texel {i} decoded 0x{decoded:04X} != 0x{expected:04X}")


def _test_bc2_alpha():
    """BC2: explicit alpha encodes/decodes correctly."""
    color = rgb888_to_rgb565(255, 255, 255)
    pixels = [color] * 16
    # Alpha gradient: 0, 17, 34, ... (mapping to A4 values 0..15)
    alphas = [i * 17 for i in range(16)]
    low64, high64 = bc2_compress_block(pixels, alphas)
    for i in range(16):
        decoded_color, alpha2 = bc2_decode_texel(low64, high64, i)
        expected_a4 = (alphas[i] >> 4) & 0xF
        expected_a2 = (expected_a4 >> 2) & 0x3
        assert alpha2 == expected_a2, (
            f"BC2 alpha: texel {i} alpha2 {alpha2} != {expected_a2}")


def _test_bc3_alpha():
    """BC3: interpolated alpha encodes/decodes correctly."""
    color = rgb888_to_rgb565(255, 255, 255)
    pixels = [color] * 16
    # Two distinct alpha values to test interpolation
    alphas = [255] * 8 + [0] * 8
    low64, high64 = bc3_compress_block(pixels, alphas)
    # Endpoints should be max=255, min=0
    a0 = low64 & 0xFF
    a1 = (low64 >> 8) & 0xFF
    assert a0 == 255, f"BC3: alpha0 = {a0}, expected 255"
    assert a1 == 0, f"BC3: alpha1 = {a1}, expected 0"
    # Texels 0-7 should decode to alpha near 255 (index 0 → alpha0=255)
    for i in range(8):
        _, alpha2 = bc3_decode_texel(low64, high64, i)
        assert alpha2 == 3, f"BC3: texel {i} alpha2={alpha2}, expected 3"
    # Texels 8-15 should decode to alpha near 0 (index 1 → alpha1=0)
    for i in range(8, 16):
        _, alpha2 = bc3_decode_texel(low64, high64, i)
        assert alpha2 == 0, f"BC3: texel {i} alpha2={alpha2}, expected 0"


def _test_bc4_grayscale():
    """BC4: single channel encodes/decodes to grayscale RGB565."""
    # Solid max
    values = [255] * 16
    block = bc4_compress_block(values)
    for i in range(16):
        rgb565, alpha2 = bc4_decode_texel(block, i)
        assert alpha2 == 3, f"BC4: texel {i} alpha {alpha2} != 3"
        # R5=31, G6=63, B5=31 → 0xFFFF
        assert rgb565 == 0xFFFF, f"BC4: texel {i} rgb565=0x{rgb565:04X} != 0xFFFF"

    # Solid zero
    values = [0] * 16
    block = bc4_compress_block(values)
    for i in range(16):
        rgb565, alpha2 = bc4_decode_texel(block, i)
        assert rgb565 == 0x0000, f"BC4 zero: texel {i} rgb565=0x{rgb565:04X}"


def _test_bc1_max_contrast():
    """BC1: max contrast (black + white) block."""
    black = 0x0000
    white = 0xFFFF
    # Alternating pattern
    pixels = [white if i % 2 == 0 else black for i in range(16)]
    block = bc1_compress_block(pixels)
    for i in range(16):
        decoded, alpha = bc1_decode_texel(block, i)
        expected = white if i % 2 == 0 else black
        assert decoded == expected, (
            f"BC1 contrast: texel {i} decoded 0x{decoded:04X} != 0x{expected:04X}")


def run_tests():
    """Run all unit tests."""
    tests = [
        _test_bc1_solid_block,
        _test_bc1_two_color_block,
        _test_bc1_max_contrast,
        _test_bc2_alpha,
        _test_bc3_alpha,
        _test_bc4_grayscale,
    ]
    for test in tests:
        test()
        print(f"  PASS: {test.__name__}")
    print(f"All {len(tests)} tests passed.")


if __name__ == "__main__":
    run_tests()
