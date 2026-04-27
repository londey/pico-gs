"""INDEXED8_2X2 texture compression helper.

Compresses an RGBA image into the on-chip INDEXED8_2X2 format used by
the texture pipeline (UNIT-011, INT-014):

* The image is split into 2x2 RGBA tiles (one per *index*).
* k-means clustering reduces the tiles to 256 representative codewords.
* Each codeword becomes a 16-byte palette entry (NW, NE, SW, SE in
  RGBA8888, little-endian within each channel quadruple).
* Each tile is replaced by the 8-bit cluster id; the resulting index
  grid is laid out in INT-014 4x4 block-tiled order, ready for upload
  via ``emit_indexed_texture_block``.

This is a transactional, software-side compressor; it has no
relationship to the hardware decode path beyond producing payloads in
the same memory format the hardware reads.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image
from scipy.cluster.vq import kmeans2

NUM_PALETTE_ENTRIES = 256
QUADRANTS_PER_ENTRY = 4
CHANNELS_PER_QUADRANT = 4  # RGBA8888
BYTES_PER_ENTRY = QUADRANTS_PER_ENTRY * CHANNELS_PER_QUADRANT  # 16
PALETTE_BLOB_BYTES = NUM_PALETTE_ENTRIES * BYTES_PER_ENTRY  # 4096


def compress_indexed8_2x2(
    png_path: str | Path,
    *,
    k: int = NUM_PALETTE_ENTRIES,
    seed: int = 0xC0FFEE,
    iters: int = 50,
) -> tuple[bytes, bytes, np.ndarray]:
    """Compress an RGBA image to an INDEXED8_2X2 payload.

    # Arguments

    * ``png_path`` -- path to an image PIL can open.  Sides must be even
      so the 2x2 tile split is exact, and divisible by 8 so the index
      grid lands on 4x4 block boundaries (INT-014 requirement).
    * ``k`` -- number of palette entries to cluster to.  Caps at 256
      because the index field is 8 bits.
    * ``seed`` -- RNG seed for ``scipy.cluster.vq.kmeans2``.
      Fixed by default so golden images are reproducible across hosts.
    * ``iters`` -- maximum k-means iterations.

    # Returns

    A 3-tuple ``(palette_blob, indices_block_tiled, reconstructed)``:

    * ``palette_blob`` -- 4096-byte palette payload, ``[NW, NE, SW, SE]``
      RGBA8888 per entry, ready for ``emit_palette_upload``.
    * ``indices_block_tiled`` -- ``(index_h * index_w)`` bytes laid out
      in INT-014 4x4 block-tiled order, ready for
      ``emit_indexed_texture_block``.
    * ``reconstructed`` -- ``(H, W, 4)`` ``uint8`` RGBA array showing the
      lossy round-trip; useful for diagnostics and golden review.
    """
    if k > NUM_PALETTE_ENTRIES:
        raise ValueError(f"k={k} exceeds the 8-bit index domain ({NUM_PALETTE_ENTRIES})")

    img = Image.open(png_path).convert("RGBA")
    rgba = np.asarray(img, dtype=np.uint8)
    height, width, _ = rgba.shape

    if height % 2 or width % 2:
        raise ValueError(f"image size ({width}x{height}) must be even on both axes")
    if (height // 2) % 4 or (width // 2) % 4:
        raise ValueError(
            f"index grid {(width // 2)}x{(height // 2)} must be a multiple of 4 "
            "on both axes (INT-014 4x4 block-tiling requirement)"
        )

    # (index_h, index_w, 4 quadrants, 4 channels) -> flat (N, 16) features.
    index_h = height // 2
    index_w = width // 2
    tiles = (
        rgba.reshape(index_h, 2, index_w, 2, 4)
        .transpose(0, 2, 1, 3, 4)
        .reshape(index_h * index_w, QUADRANTS_PER_ENTRY * CHANNELS_PER_QUADRANT)
        .astype(np.float32)
    )

    rng = np.random.default_rng(seed)
    centroids, labels = kmeans2(
        tiles, k=k, iter=iters, minit="++", seed=rng, missing="warn"
    )

    # ``kmeans2`` may emit fewer than ``k`` clusters when a partition
    # collapses; pad the centroid table so the palette is always full.
    if centroids.shape[0] < NUM_PALETTE_ENTRIES:
        pad = np.zeros(
            (NUM_PALETTE_ENTRIES - centroids.shape[0], centroids.shape[1]),
            dtype=centroids.dtype,
        )
        centroids = np.vstack([centroids, pad])

    palette_blob = (
        np.clip(np.round(centroids), 0, 255).astype(np.uint8).tobytes()
    )
    assert len(palette_blob) == PALETTE_BLOB_BYTES

    indices_2d = labels.reshape(index_h, index_w).astype(np.uint8)
    indices_block_tiled = _block_tile_indices(indices_2d)

    reconstructed = _reconstruct(indices_2d, centroids, height, width)
    return palette_blob, indices_block_tiled, reconstructed


def palette_blob_to_entries(blob: bytes) -> list[tuple]:
    """Decode a 4096-byte palette blob into the ``(NW, NE, SW, SE)`` tuple
    list consumed by ``common.emit_palette_upload``.

    Each tuple element is an RGBA8888 4-tuple ``(R, G, B, A)``.
    """
    if len(blob) != PALETTE_BLOB_BYTES:
        raise ValueError(
            f"expected {PALETTE_BLOB_BYTES}-byte palette, got {len(blob)}"
        )
    entries: list[tuple] = []
    for i in range(NUM_PALETTE_ENTRIES):
        base = i * BYTES_PER_ENTRY
        nw = tuple(blob[base + 0:base + 4])
        ne = tuple(blob[base + 4:base + 8])
        sw = tuple(blob[base + 8:base + 12])
        se = tuple(blob[base + 12:base + 16])
        entries.append((nw, ne, sw, se))
    return entries


def _block_tile_indices(indices_2d: np.ndarray) -> bytes:
    """Lay out a 2D index array in 4x4 block-tiled order (INT-014).

    Blocks are row-major across the index grid; within each block the
    16 bytes are row-major (``byte_in_block = local_y * 4 + local_x``).
    """
    height, width = indices_2d.shape
    assert height % 4 == 0 and width % 4 == 0
    blocks_per_row = width // 4
    block_rows = height // 4

    # Reshape into (block_y, local_y, block_x, local_x), permute to
    # group local_y/local_x together, then flatten.
    out = (
        indices_2d.reshape(block_rows, 4, blocks_per_row, 4)
        .transpose(0, 2, 1, 3)
        .reshape(-1)
    )
    return bytes(out)


def _reconstruct(
    indices_2d: np.ndarray,
    centroids: np.ndarray,
    height: int,
    width: int,
) -> np.ndarray:
    """Reconstruct the lossy RGBA image from the index grid and palette."""
    palette = np.clip(np.round(centroids), 0, 255).astype(np.uint8)
    # palette: (256, 16) -> (256, 2, 2, 4) in (NW, NE, SW, SE) order.
    palette_tiles = palette.reshape(NUM_PALETTE_ENTRIES, 2, 2, 4)
    tiles = palette_tiles[indices_2d]  # (index_h, index_w, 2, 2, 4)
    # Stitch the 2x2 tiles back into a contiguous image.
    return tiles.transpose(0, 2, 1, 3, 4).reshape(height, width, 4)
