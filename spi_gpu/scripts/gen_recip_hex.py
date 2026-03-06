#!/usr/bin/env python3
"""Generate .hex initialization files for DP16KD reciprocal BRAMs.

Produces two files:
  - recip_area_init.hex: 512 entries, 36 bits each (UQ1.17 seed + UQ0.17 delta),
    for the triangle-area reciprocal module (raster_recip_area.sv).
  - recip_q_init.hex: 1024 entries, 18 bits each (UQ1.17),
    for the per-pixel 1/Q reciprocal module (raster_recip_q.sv).

Both tables store reciprocal values: round(2^17 / (1 + i/N)) in UQ1.17 format,
representing 1/mantissa for mantissa in [1.0, 2.0).

Output format: one hex value per line, compatible with Verilog $readmemh.

Spec references: UNIT-005.01, UNIT-005.04, DD-035
"""

import os
import sys


def compute_recip_uq1_17(i: int, n: int) -> int:
    """Compute round(2^17 / (1 + i/n)) as an 18-bit UQ1.17 integer."""
    value = round((1 << 17) / (1.0 + i / n))
    # Clamp to 18-bit range [0, 0x3FFFF]
    return min(value, 0x3FFFF)


def generate_area_table(path: str) -> None:
    """Generate the 512-entry area reciprocal table (36 bits per entry).

    Each entry packs {delta[17:0], seed[17:0]} where:
      - seed = round(2^17 / (1 + i/512))       (UQ1.17, 18 bits)
      - delta = seed[i] - seed[i+1]            (UQ0.17, 18 bits, non-negative)

    The 36-bit entry layout: bits [35:18] = delta, bits [17:0] = seed.
    """
    # Compute 513 seed values (extra one needed for delta of last entry)
    seeds = [compute_recip_uq1_17(i, 512) for i in range(513)]

    with open(path, "w") as f:
        for i in range(512):
            seed = seeds[i]
            delta = seeds[i] - seeds[i + 1]
            assert delta >= 0, (
                f"Delta at index {i} is negative: {delta} "
                f"(seed[{i}]={seeds[i]}, seed[{i+1}]={seeds[i+1]})"
            )
            # Pack as 36-bit value: {delta[17:0], seed[17:0]}
            entry = (delta << 18) | seed
            # Format as 9-digit hex (36 bits = 9 hex digits)
            f.write(f"{entry:09X}\n")


def generate_q_table(path: str) -> None:
    """Generate the 1024-entry per-pixel 1/Q reciprocal table (18 bits per entry).

    Each entry is round(2^17 / (1 + i/1024)) in UQ1.17 format.
    Entry 1024 would be needed for interpolation of the last entry; we special-case
    entry index 1023's interpolation neighbor to equal entry 1023 itself (delta = 0
    at the boundary).
    """
    # Compute 1024 values
    values = [compute_recip_uq1_17(i, 1024) for i in range(1024)]

    with open(path, "w") as f:
        for i in range(1024):
            f.write(f"{values[i]:05X}\n")


def main() -> None:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    render_dir = os.path.join(script_dir, "..", "src", "render")

    area_path = os.path.join(render_dir, "recip_area_init.hex")
    q_path = os.path.join(render_dir, "recip_q_init.hex")

    generate_area_table(area_path)
    print(f"Generated {area_path}")

    generate_q_table(q_path)
    print(f"Generated {q_path}")

    # Verification summary
    seed_0 = compute_recip_uq1_17(0, 512)
    seed_511 = compute_recip_uq1_17(511, 512)
    q_0 = compute_recip_uq1_17(0, 1024)
    q_1023 = compute_recip_uq1_17(1023, 1024)

    print(f"\nVerification:")
    print(f"  Area table entry 0 seed:  0x{seed_0:05X} (expect 0x20000)")
    print(f"  Area table entry 511 seed: 0x{seed_511:05X} "
          f"(expect round(2^17 / (1 + 511/512)) = "
          f"{round((1 << 17) / (1 + 511/512))})")
    print(f"  Q table entry 0:    0x{q_0:05X} (expect 0x20000)")
    print(f"  Q table entry 1023: 0x{q_1023:05X} "
          f"(expect ~0x10000 = {round((1 << 17) / (1 + 1023/1024))})")


if __name__ == "__main__":
    main()
