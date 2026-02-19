# REQ-134: Extended Precision Fragment Processing

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the GPU pixel pipeline processes a fragment through blending, shading, or texture combination stages, the system SHALL represent all intermediate color values in 10.8 fixed-point format (10 integer bits, 8 fractional bits = 18 bits per channel) to minimize cumulative precision loss.

## Rationale

8-bit integer fragment processing causes visible banding artifacts in smooth gradients due to cumulative quantization errors across multiple blending stages. The 10.8 format provides 256x finer precision in the fractional range and 2 bits of integer overflow headroom for additive operations, while matching ECP5 DSP slice width (18x18 multipliers) for efficient implementation.

## Parent Requirements

- REQ-TBD-FRAGMENT-PROCESSOR (Fragment Processor/Color Combiner — top-level area 4 requirement, not yet created)

## Allocated To

- UNIT-005 (Rasterizer) — RGBA8 interpolation output promotion to 10.8
- UNIT-006 (Pixel Pipeline) — All blend operations in 10.8 format
- UNIT-022 (GPU Driver Layer)

## Interfaces

- INT-010 (GPU Register Map) — Vertex COLOR register input (ABGR8888 promoted to 10.8)
- INT-020 (GPU Driver API)

## Functional Requirements

### FR-134-1: 10.8 Fixed-Point Format

The GPU SHALL use 10.8 fixed-point format for all fragment color values:

- Total width: 18 bits per component (R, G, B, A)
- Integer range: [0, 1023] (10 bits) — 8 bits for [0,255] color range + 2 bits overflow headroom
- Fractional precision: 1/256 (8 bits)
- Representation: `value = integer_part + (fractional_part / 256)`

### FR-134-2: Texture Format Promotion

After texture cache read, pixel data SHALL be promoted from storage format to 10.8:

- **RGBA5652 (cache format):** R5→R10 (left shift 5, replicate MSBs), G6→G10 (left shift 4, replicate), B5→B10 (left shift 5, replicate), A2→A10 (expand 00→0, 01→341, 10→682, 11→1023)
- Fractional bits are zero after promotion

### FR-134-3: Vertex Color Promotion

The rasterizer SHALL output interpolated vertex colors in 10.8 format:

1. Interpolate per-vertex RGBA8 colors using barycentric coordinates with 8.8 fixed-point accumulators
2. Promote interpolated values to 10.8 by bit-width extension (8-bit values placed in integer part, fractional bits from interpolation preserved)

### FR-134-4: Color Combiner Precision

All color combiner operations SHALL be performed in 10.8 format.
When the color combiner receives inputs (VER_COLOR0, VER_COLOR1, TEX_COLOR0, TEX_COLOR1, MAT_COLOR0, MAT_COLOR1, Z_COLOR), the following arithmetic operations SHALL use 10.8 precision:

- **MULTIPLY:** `result = (a * b) >> 8` using 18x18 DSP multiplier
- **ADD:** `result = saturate(a + b)` with saturation at 10-bit integer max (1023)
- **SUBTRACT:** `result = saturate(a - b)` with saturation at 0
- **INVERSE_SUBTRACT:** `result = saturate(b - a)` with saturation at 0
- **LERP:** `result = (a * factor + b * (1023 - factor)) >> 8` for fog and blending effects
- All operations apply per-component (R, G, B, A independently)
- The color combiner replaces the previous sequential 4-texture blend pipeline with a programmable combining stage

### FR-134-5: Alpha Blending Precision

Alpha blending operations SHALL be performed in 10.8 format:

1. Promote destination pixel from RGB565 to 10.8 (same promotion as texture format)
2. Apply blend equation in 10.8 format:
   - **ADD:** `result = saturate(src + dst)`
   - **SUBTRACT:** `result = saturate(src - dst)`
   - **ALPHA_BLEND:** `result = (src * alpha + dst * (1023 - alpha)) >> 8` (Porter-Duff source-over)
3. Saturate results to [0, 1023] integer range

### FR-134-6: Framebuffer Conversion

After all blending, the pixel pipeline SHALL convert 10.8 format to RGB565:

1. Apply ordered dithering if enabled (REQ-132)
2. Extract upper bits: R[9:5]→R5, G[9:4]→G6, B[9:5]→B5
3. Pack into RGB565 format and write to framebuffer
4. Alpha channel is discarded (RGB565 has no alpha storage)

### FR-134-7: Always-On Mode

The 10.8 fixed-point format SHALL be always enabled. There is no configurable mode to revert to 8-bit integer processing. This simplifies hardware and ensures consistent visual quality.

## Verification Method

**Test:** Execute relevant test suite for fragment processing precision:

- [ ] Texture promotion from RGBA5652→10.8 produces correct values
- [ ] Vertex color promotion from RGBA8→10.8 preserves interpolation precision
- [ ] MULTIPLY blend of two RGBA8 values matches reference (error < 1 LSB at 8-bit)
- [ ] ADD blend saturates correctly at 10-bit integer max (1023)
- [ ] Alpha blend at alpha=128 produces correct 50% mix
- [ ] Color combiner chain (2 textures + vertex colors + material colors + alpha) maintains precision
- [ ] Final RGB565 output matches reference within dithering tolerance
- [ ] Framebuffer readback promotion (RGB565→10.8) produces correct values

## Notes

The 10.8 format matches ECP5 DSP slice capabilities (18x18 multipliers), enabling efficient hardware implementation.
Total DSP usage is approximately 8-12 slices, within the 16-slice budget.

The pixel pipeline runs at 100 MHz (`clk_core`), providing a peak throughput of 100 million fragment operations per second.
All SDRAM accesses for framebuffer readback (alpha blending) and texture cache fills occur in the same clock domain, with no CDC overhead.

Promotion from lower bit-depth formats uses MSB replication (e.g., R5→R10 = {R5, R5}) to ensure uniform distribution across the 10-bit range, avoiding bias from simple zero-padding.

See DD-011 in design_decisions.md for architectural rationale.
