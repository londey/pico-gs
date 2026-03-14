"""Texture data .hex file generator.

Generates shared texture data files that test scripts can include via
the ## INCLUDE: directive.  Each output file contains MEM_ADDR + MEM_DATA
register write sequences to upload one compressed or uncompressed texture
to a well-known SDRAM address.

Uses the Nissan Skyline R32 pixel art texture atlas as a representative
real-world source, downsampled to GPU-appropriate sizes.  Also generates
small procedural textures for targeted format testing.
"""

from __future__ import annotations

import os
from typing import List, Tuple

from PIL import Image

from common import (
    ADDR_MEM_ADDR,
    ADDR_MEM_DATA,
    emit,
    emit_comment,
    emit_blank,
    write_hex_file,
)
from bc_compress import (
    rgb888_to_rgb565,
    compress_image_bc1,
    compress_image_bc2,
    compress_image_bc3,
    compress_image_bc4,
)


# ---------------------------------------------------------------------------
# Well-known texture base addresses
#
# BASE_ADDR register field = word_address / 256 (512-byte granularity).
# word_address = BASE_ADDR_512 * 256.
# ---------------------------------------------------------------------------

# Texture slot 0: byte 0x100000, word 0x80000, BASE_ADDR=0x0800
TEX_SLOT_0_WORD = 0x80000
TEX_SLOT_0_512 = 0x0800

# Texture slot 1: byte 0x120000, word 0x90000, BASE_ADDR=0x0900
TEX_SLOT_1_WORD = 0x90000
TEX_SLOT_1_512 = 0x0900

# Path to the representative source texture (relative to this script)
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SKYLINE_PNG = os.path.join(
    _SCRIPT_DIR,
    "nissan_skyline_r32_pixel_art", "textures", "Material.001_baseColor.png",
)


# ---------------------------------------------------------------------------
# PNG loading helpers
# ---------------------------------------------------------------------------

def load_png_rgba(path: str,
                  target_size: Tuple[int, int] | None = None,
                  ) -> Tuple[int, int,
                             List[List[int]], List[List[int]]]:
    """Load a PNG and return RGB565 + alpha arrays.

    Args:
        path: Path to PNG file.
        target_size: Optional (width, height) to resize to.  Uses
            box-filter (LANCZOS) downsampling.

    Returns:
        (width, height, pixels_rgb565[y][x], alphas[y][x])
    """
    img = Image.open(path).convert("RGBA")
    if target_size is not None:
        img = img.resize(target_size, Image.LANCZOS)
    w, h = img.size

    pixels: List[List[int]] = []
    alphas: List[List[int]] = []
    for y in range(h):
        row_px: List[int] = []
        row_a: List[int] = []
        for x in range(w):
            r, g, b, a = img.getpixel((x, y))
            row_px.append(rgb888_to_rgb565(r, g, b))
            row_a.append(a)
        pixels.append(row_px)
        alphas.append(row_a)

    return w, h, pixels, alphas


def load_png_rgba8888(path: str,
                      target_size: Tuple[int, int] | None = None,
                      ) -> Tuple[int, int, List[List[int]]]:
    """Load a PNG and return RGBA8888 array.

    Args:
        path: Path to PNG file.
        target_size: Optional (width, height) to resize to.

    Returns:
        (width, height, pixels_rgba8888[y][x]) where each value is a u32
        packed as [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A (little-endian).
    """
    img = Image.open(path).convert("RGBA")
    if target_size is not None:
        img = img.resize(target_size, Image.LANCZOS)
    w, h = img.size

    pixels: List[List[int]] = []
    for y in range(h):
        row: List[int] = []
        for x in range(w):
            r, g, b, a = img.getpixel((x, y))
            row.append(r | (g << 8) | (b << 16) | (a << 24))
        pixels.append(row)

    return w, h, pixels


def load_png_grayscale(path: str,
                       target_size: Tuple[int, int] | None = None,
                       ) -> Tuple[int, int, List[List[int]]]:
    """Load a PNG and return single-channel (luminance) array.

    Args:
        path: Path to PNG file.
        target_size: Optional (width, height) to resize to.

    Returns:
        (width, height, values[y][x]) where values are u8.
    """
    img = Image.open(path).convert("L")
    if target_size is not None:
        img = img.resize(target_size, Image.LANCZOS)
    w, h = img.size

    values: List[List[int]] = []
    for y in range(h):
        row: List[int] = []
        for x in range(w):
            row.append(img.getpixel((x, y)))
        values.append(row)

    return w, h, values


# ---------------------------------------------------------------------------
# Procedural test texture generators
# ---------------------------------------------------------------------------

def make_alpha_gradient_8x8() -> Tuple[List[List[int]], List[List[int]]]:
    """8x8 image with red color and varying alpha.

    Alpha varies from 0 (top-left) to 255 (bottom-right) in a diagonal
    gradient.  Good for testing BC2 explicit alpha and BC3 interpolated alpha.

    Returns (pixels_rgb565[y][x], alphas[y][x]).
    """
    pixels: List[List[int]] = []
    alphas: List[List[int]] = []
    for y in range(8):
        row: List[int] = []
        alpha_row: List[int] = []
        for x in range(8):
            # Red color, varying intensity slightly for BC color testing
            r = 200 + (x * 7)  # 200..249
            row.append(rgb888_to_rgb565(min(r, 255), 0, 0))
            # Diagonal alpha gradient
            t = (x + y) / 14.0  # 0..1
            alpha_row.append(int(255 * t))
        pixels.append(row)
        alphas.append(alpha_row)
    return pixels, alphas


# ---------------------------------------------------------------------------
# .hex file emission
# ---------------------------------------------------------------------------

def emit_texture_words(base_word: int, words: List[int],
                       label: str) -> List[str]:
    """Emit MEM_ADDR + MEM_DATA writes to upload texture data.

    Args:
        base_word: SDRAM word address for texture start.
        words: List of u16 words to write.
        label: Description for comment.

    Returns:
        List of hex file lines.
    """
    assert len(words) % 4 == 0, f"Word count {len(words)} not multiple of 4"

    lines: List[str] = []
    lines.append(emit_comment(f"Texture data: {label}"))
    lines.append(emit_comment(f"Base word address: 0x{base_word:05X} "
                               f"({len(words)} words, {len(words) * 2} bytes)"))
    lines.append(emit_blank())

    # Set MEM_ADDR to dword address
    dword_addr = base_word // 4
    lines.append(emit(ADDR_MEM_ADDR, dword_addr,
                       f"dword_addr=0x{dword_addr:05X}"))

    # Write 64-bit dwords (4 words each), auto-incrementing
    num_dwords = len(words) // 4
    for i in range(num_dwords):
        w0 = words[i * 4 + 0]
        w1 = words[i * 4 + 1]
        w2 = words[i * 4 + 2]
        w3 = words[i * 4 + 3]
        data = w0 | (w1 << 16) | (w2 << 32) | (w3 << 48)
        lines.append(emit(ADDR_MEM_DATA, data, f"dwords[{i}]"))

    return lines


# ---------------------------------------------------------------------------
# Texture generation functions
# ---------------------------------------------------------------------------

def generate_skyline_256x256_bc1(base_word: int) -> List[str]:
    """Skyline texture atlas at native 256x256, BC1 compressed."""
    _, _, pixels, _ = load_png_rgba(SKYLINE_PNG)
    words = compress_image_bc1(pixels, 256, 256)
    return emit_texture_words(base_word, words,
                               "skyline_256x256 BC1 (256x256, 4bpp)")


def generate_skyline_256x256_bc2(base_word: int) -> List[str]:
    """Skyline texture atlas at native 256x256, BC2 compressed."""
    _, _, pixels, alphas = load_png_rgba(SKYLINE_PNG)
    words = compress_image_bc2(pixels, alphas, 256, 256)
    return emit_texture_words(base_word, words,
                               "skyline_256x256 BC2 (256x256, 8bpp)")


def generate_skyline_256x256_bc3(base_word: int) -> List[str]:
    """Skyline texture atlas at native 256x256, BC3 compressed."""
    _, _, pixels, alphas = load_png_rgba(SKYLINE_PNG)
    words = compress_image_bc3(pixels, alphas, 256, 256)
    return emit_texture_words(base_word, words,
                               "skyline_256x256 BC3 (256x256, 8bpp)")


def generate_skyline_256x256_bc4(base_word: int) -> List[str]:
    """Skyline texture as native 256x256 grayscale, BC4 compressed."""
    _, _, values = load_png_grayscale(SKYLINE_PNG)
    words = compress_image_bc4(values, 256, 256)
    return emit_texture_words(base_word, words,
                               "skyline_256x256 BC4 (256x256, 4bpp)")


def tile_image_rgba8888(pixels: List[List[int]],
                       width: int, height: int) -> List[int]:
    """Tile an RGBA8888 image into 4x4 block order as u16 words.

    Each 4x4 block produces 32 u16 words (2 per texel, little-endian).
    Block iteration order: row-major blocks, row-major texels within each.

    Args:
        pixels: 2D array [y][x] of u32 RGBA8888 values.
        width: Image width (must be multiple of 4).
        height: Image height (must be multiple of 4).

    Returns:
        List of u16 SDRAM words in block-sequential order.
    """
    assert width % 4 == 0 and height % 4 == 0
    words: List[int] = []

    for by in range(height // 4):
        for bx in range(width // 4):
            for ly in range(4):
                for lx in range(4):
                    rgba = pixels[by * 4 + ly][bx * 4 + lx]
                    words.append(rgba & 0xFFFF)
                    words.append((rgba >> 16) & 0xFFFF)

    return words


def generate_skyline_256x256_rgba8888(base_word: int) -> List[str]:
    """Skyline texture atlas at native 256x256, RGBA8888 uncompressed."""
    _, _, pixels = load_png_rgba8888(SKYLINE_PNG)
    words = tile_image_rgba8888(pixels, 256, 256)
    return emit_texture_words(base_word, words,
                               "skyline_256x256 RGBA8888 (256x256, 32bpp)")


def generate_alpha_gradient_8x8_bc2(base_word: int) -> List[str]:
    """Procedural 8x8 alpha gradient, BC2 compressed.

    Supplements the Skyline texture (which is fully opaque) with explicit
    alpha variation for BC2/BC3 alpha testing.
    """
    pixels, alphas = make_alpha_gradient_8x8()
    words = compress_image_bc2(pixels, alphas, 8, 8)
    return emit_texture_words(base_word, words,
                               "alpha_gradient_8x8 BC2 (8x8, 8bpp)")


def generate_alpha_gradient_8x8_bc3(base_word: int) -> List[str]:
    """Procedural 8x8 alpha gradient, BC3 compressed."""
    pixels, alphas = make_alpha_gradient_8x8()
    words = compress_image_bc3(pixels, alphas, 8, 8)
    return emit_texture_words(base_word, words,
                               "alpha_gradient_8x8 BC3 (8x8, 8bpp)")


# ---------------------------------------------------------------------------
# File generation
# ---------------------------------------------------------------------------

TEXTURE_FILES = [
    ("skyline_256x256_bc1.hex", generate_skyline_256x256_bc1),
    ("skyline_256x256_bc2.hex", generate_skyline_256x256_bc2),
    ("skyline_256x256_bc3.hex", generate_skyline_256x256_bc3),
    ("skyline_256x256_bc4.hex", generate_skyline_256x256_bc4),
    ("skyline_256x256_rgba8888.hex", generate_skyline_256x256_rgba8888),
    ("alpha_gradient_8x8_bc2.hex", generate_alpha_gradient_8x8_bc2),
    ("alpha_gradient_8x8_bc3.hex", generate_alpha_gradient_8x8_bc3),
]


def generate_all_textures(output_dir: str) -> None:
    """Generate all shared texture .hex files.

    Args:
        output_dir: Directory for output files (e.g. spi_gpu/tests/scripts/textures/).
    """
    os.makedirs(output_dir, exist_ok=True)

    for filename, generator in TEXTURE_FILES:
        path = os.path.join(output_dir, filename)
        lines = generator(TEX_SLOT_0_WORD)
        write_hex_file(path, lines)
        print(f"  Generated {path}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Generate shared texture .hex files")
    parser.add_argument("--output-dir", default=None,
                        help="Output directory (default: ../textures/)")
    args = parser.parse_args()

    if args.output_dir is None:
        args.output_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "textures")

    generate_all_textures(args.output_dir)
    print(f"Done: {len(TEXTURE_FILES)} texture files generated.")
