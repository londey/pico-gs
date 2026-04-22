# Technical Report: Bilinear Filter DSP Analysis

Date: 2026-04-04

## Problem

The `texture_bilinear` module uses 20 MULT18X18D blocks when synthesized with Yosys for ECP5.
The ECP5-25K has only 28 MULT18 total.
REQ-011.02 allocates 0 DSP for bilinear filtering.

## Root Cause

The module is fully combinational with 20 independent 9x9 multiplies:
- 4 weight multiplies: `w00 = (256-fu)*(256-fv)`, etc.
- 16 channel blend multiplies: 4 channels (RGBA) x 4 taps: `texel[i] * weight[i]`

Yosys maps each 9x9 multiply to a full MULT18X18D.
MULT9X9D (dual 9x9 mode) is not supported by Yosys/nextpnr.

## Analysis: Texel Value Ranges

All texel channels are UQ1.8 where 0x100 = 1.0 and max value = 0x100 (256).
Bilinear weights are also UQ1.8, derived from sub-texel fractions.
All values are <= 1.0, so products fit in 17 bits (max 256 x 256 = 65536).

## Approach 1: Time-Multiplexed (4 MULT18, 3 cycles)

Use 4 DSPs shared across channels:
```
Cycle 1: 4 DSPs compute U-lerp for top row (RGBA in parallel)
Cycle 2: 4 DSPs compute U-lerp for bottom row
Cycle 3: 4 DSPs compute V-lerp final
```

Pros: Minimal DSP usage (4 per sampler, 8 for two).
Cons: 3-cycle latency per pixel.
Not single-cycle throughput unless pipelined with 3 sets of registers.

## Approach 2: Two-Step Lerp (12 MULT18, fully pipelined)

Replace weight-then-blend with a 2-step linear interpolation:
```
top[ch]    = t0[ch] + frac_u * (t1[ch] - t0[ch])   // 4 DSPs
bottom[ch] = t2[ch] + frac_u * (t3[ch] - t2[ch])   // 4 DSPs
out[ch]    = top[ch] + frac_v * (bottom[ch] - top[ch]) // 4 DSPs
```

12 multiplies (3 per channel x 4 channels).
All operands fit signed 9-bit (diffs in [-255, +255], fracs in [0, 255]).
Can be split into 2 pipeline stages (U-lerp + V-lerp) for 1 pixel/clock throughput.

Pros: Single-cycle throughput when pipelined.
Cons: 12 MULT18 per sampler.

## DSP Budget Impact

| Configuration | Rasterizer | Bilinear (per sampler) | Samplers | Color Combiner | Total | Fits? |
|---------------|-----------|----------------------|----------|---------------|-------|-------|
| Current (naive) | 8 | 20 | 1 | 4-6 | 32-34 | No |
| Two-step lerp, 2 samplers | 8 | 12 | 2 | 4-6 | 36-38 | No |
| Two-step lerp, 1 shared sampler | 8 | 12 | 1 | 4-6 | 24-26 | Tight |
| Time-multiplexed, 1 shared | 8 | 4 | 1 | 4-6 | 16-18 | Yes |
| LUT-only (shift-and-add) | 8 | 0 | 1 | 4-6 | 12-14 | Yes |

## Key Insight: 1 Pixel/Clock Bilinear Conflicts with ECP5-25K DSP Budget

Achieving 1 pixel/clock throughput with bilinear filtering requires 12 MULT18 per sampler
(two-step lerp, pipelined).
With 2 samplers this is 24 DSPs for bilinear alone, exceeding the 28-DSP device.
With 1 shared sampler it is 24-26 total, leaving almost no margin.

The fundamental tension: **single-cycle bilinear throughput + dual texture samplers + ECP5-25K = does not fit.**

## Options for Future Implementation

1. **Shared sampler, 12 DSP** — 1 pixel/clock possible but tight (24-26 of 28).
   Could free more DSP if color combiner moves to LUT shift-and-add.
2. **Shared sampler, 4 DSP time-multiplexed** — 3 cycles per texture sample, not single-cycle.
   Comfortable budget (16-18 of 28).
3. **Nearest-only** — 0 DSP for filtering. Current implementation.
4. **LUT shift-and-add** — 0 DSP, ~870 LUTs, but too slow for 100 MHz single-cycle.

## Weight Computation Note

If DSP-based bilinear is implemented, the 4 weight multiplies should use LUT shift-and-add
(following the `raster_shift_mul_32x11.sv` pattern) to prevent Yosys `mul2dsp` inference.
Weights are computed once per pixel and shared across all channels, so LUT cost is acceptable.

## References

- RTL: `rtl/components/texture/detail/bilinear-filter/src/texture_bilinear.sv`
- Twin: `twin/components/texture/detail/bilinear-filter/src/lib.rs`
- DSP precision report: `doc/reports/dsp_block_precision.md`
- Resource constraints: `doc/requirements/req_011.02_resource_constraints.md`
- ECP5 DSP guide: `.claude/skills/ecp5-sv-yosys-verilator/references/dsp_guide.md`
