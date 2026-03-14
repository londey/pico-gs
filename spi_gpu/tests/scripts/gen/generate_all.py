#!/usr/bin/env python3
"""Generate all VER-NNN test script .hex files.

Usage:
    python3 generate_all.py [--output-dir <dir>]

By default, hex files are written to the parent directory
(spi_gpu/tests/scripts/).
"""

from __future__ import annotations

import argparse
import os
import sys

# Add this directory to the Python path so generators can import common
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import write_hex_file
from textures import generate_all_textures

import ver_010
import ver_011
import ver_012
import ver_013
import ver_014
import ver_015
import ver_016
import ver_017
import ver_018
import ver_019
import ver_020


GENERATORS = [
    ("ver_010_gouraud.hex", ver_010),
    ("ver_011_depth_test.hex", ver_011),
    ("ver_012_textured.hex", ver_012),
    ("ver_013_color_combined.hex", ver_013),
    ("ver_014_textured_cube.hex", ver_014),
    ("ver_015_size_grid.hex", ver_015),
    ("ver_016_perspective_road.hex", ver_016),
    ("ver_017_bc1_texture.hex", ver_017),
    ("ver_018_bc2_texture.hex", ver_018),
    ("ver_019_bc3_texture.hex", ver_019),
    ("ver_020_bc4_texture.hex", ver_020),
]


def main():
    parser = argparse.ArgumentParser(description="Generate GPU test script .hex files")
    parser.add_argument("--output-dir", default=None,
                        help="Output directory (default: ../)")
    args = parser.parse_args()

    if args.output_dir is None:
        # Default: parent of gen/ directory (i.e., spi_gpu/tests/scripts/)
        args.output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

    os.makedirs(args.output_dir, exist_ok=True)

    # Generate shared texture data files first (test scripts may INCLUDE them)
    tex_dir = os.path.join(args.output_dir, "textures")
    print("Generating shared texture data files...")
    generate_all_textures(tex_dir)
    print()

    # Generate test scripts
    print("Generating test scripts...")
    for filename, module in GENERATORS:
        path = os.path.join(args.output_dir, filename)
        lines = module.generate()
        write_hex_file(path, lines)
        print(f"  Generated {path}")

    print(f"\nDone: {len(GENERATORS)} hex files written to {args.output_dir}")


if __name__ == "__main__":
    main()
