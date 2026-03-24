# UNIT-011.04: Block Decompressor

## Purpose

Decodes a compressed or uncompressed 4×4 texel block from its raw SDRAM format into 16 UQ1.8 RGBA texels for storage in UNIT-011.03 (L1 Decompressed Cache), then promotes the UQ1.8 output to Q4.12 via `texel_promote.sv` before passing texels to the color combiner pipeline.
Supports eight texture formats: BC1 (0), BC2 (1), BC3 (2), BC4 (3), BC5 (4), RGB565 (5), RGBA8888 (6), R8 (7).

## Implements Requirements

- REQ-003.03 (Compressed Textures) — BC1 through BC5 block decompression
- REQ-003.06 (Texture Sampling) — decoder portion: expands all eight source formats to UQ1.8

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — `tex_format[3:0]` from TEXn_CFG bits [5:2]

### Internal Interfaces

- Receives raw compressed block data from UNIT-011.05 (L2 Compressed Cache) or directly from SDRAM burst via the fill FSM
- Outputs 16 UQ1.8 RGBA texels (16 × 36 bits = 576 bits) to UNIT-011.03 for L1 bank fill
- Outputs promoted Q4.12 RGBA texel (4 × 16 bits = 64 bits) to UNIT-011.02 (Bilinear/Trilinear Filter output path) after promotion by `texel_promote.sv`

## Design Description

### Format-Select Mux

A 4-bit `tex_format` field from TEXn_CFG selects the active decoder.
All eight decoders operate in parallel on the compressed block data; the format-select mux routes the correct decoder's output to the L1 fill path and the promotion stage:

| tex_format | Decoder module | Format |
|------------|----------------|--------|
| 4'h0 | `texture_bc1.sv` | BC1 (RGB + 1-bit alpha punch-through) |
| 4'h1 | `texture_bc2.sv` | BC2 (RGB + 4-bit explicit alpha) |
| 4'h2 | `texture_bc3.sv` | BC3 (RGB + 8-bit interpolated alpha) |
| 4'h3 | `texture_bc4.sv` | BC4 (single-channel, replicated to RGB) |
| 4'h4 | `texture_bc5.sv` | BC5 (two-channel RG, B=0) |
| 4'h5 | `texture_rgb565.sv` | RGB565 uncompressed |
| 4'h6 | `texture_rgba8888.sv` | RGBA8888 uncompressed |
| 4'h7 | `texture_r8.sv` | R8 single-channel |
| 4'h8–4'hF | — | Reserved |

Codes 8–15 are reserved (see DD-041 for the 4-bit format field rationale).

### Channel Expansion Formulas (Source → UQ1.8)

All source-format channel values are expanded to 9-bit UQ1.8 using correction terms that map the maximum UNORM value to exactly 0x100 (1.0).
The naive `{1'b0, unorm8}` mapping is not used because it maps 255 to 0xFF (≈0.996), failing to represent 1.0 exactly.
See DD-038 for rationale.

The gs-texture twin crate (`components/texture/twin/`) is authoritative for these formulas; RTL must be bit-identical:

- **8-bit → UQ1.8**: `ch8_to_uq18(x) = {1'b0, x[7:0]} + {8'b0, x[7]}` — maps 0→0x000, 255→0x100
- **5-bit → UQ1.8**: `ch5_to_uq18(x) = {1'b0, x[4:0], x[4:2]} + {8'b0, x[4]}` — maps 0→0x000, 31→0x100
- **6-bit → UQ1.8**: `ch6_to_uq18(x) = {1'b0, x[5:0], x[5:4]} + {8'b0, x[5]}` — maps 0→0x000, 63→0x100
- **4-bit → UQ1.8** (BC2 alpha): `ch4_to_uq18(x) = {1'b0, x[3:0], x[3:0]} + {8'b0, x[3]}` — maps 0→0x000, 15→0x100

### BC Palette Interpolation (Shift+Add Reciprocal Multiply)

All BC palette interpolation divisions are implemented using shift+add reciprocal-multiply rather than Verilog `/` operators.
This ensures deterministic LUT usage with no synthesizer-generated integer dividers (DD-039, 0 DSP slices).

Formulas (see DD-039):
- Division by 2: `x_div2 = (x + 1) >> 1`
- Division by 3: `x_div3 = (x + 1) * 683 >> 11` (multiply by 0x2AB, shift 11; exact for sums ≤ 769)
- Division by 5: `x_div5 = (x + 2) * 3277 >> 14` (BC3 6-entry alpha; exact for sums ≤ 1277)
- Division by 7: `x_div7 = (x + 3) * 2341 >> 14` (BC3 8-entry alpha; exact for sums ≤ 1788)

### Decoder Descriptions

**BC1 Decoder (FORMAT=0) — `texture_bc1.sv`:**
- Fetch 8 bytes: two RGB565 endpoint colors + 32-bit 2-bit-per-texel index word
- Expand endpoints to 8-bit per channel using `ch5_to_uq18` (R, B) and `ch6_to_uq18` (G)
- Generate 4-color palette at UQ1.8 precision using shift+add reciprocal-multiply: C0, C1, `lerp(C0,C1,1/3)`, `lerp(C0,C1,2/3)`; or C0, C1, `lerp(C0,C1,1/2)`, transparent (when C0 ≤ C1)
- A: 1-bit punch-through: `0 → 9'h000` (transparent), `1 → 9'h100` (opaque)
- Assign palette entry to each of the 16 texels via 2-bit indices

**BC2 Decoder (FORMAT=1) — `texture_bc2.sv`:**
- 16-byte block: first 8 bytes encode 4-bit explicit alpha (2 alpha nibbles per byte, 16 texels); last 8 bytes encode RGB as BC1 (no punch-through)
- A: each 4-bit alpha expanded via `ch4_to_uq18`
- RGB: decoded per BC1 color block algorithm

**BC3 Decoder (FORMAT=2) — `texture_bc3.sv`:**
- 16-byte block: first 8 bytes encode 8-bit interpolated alpha (2 endpoint bytes + 48-bit 3-bit-per-texel indices); last 8 bytes encode RGB as BC1 (no punch-through)
- A: 6-entry or 8-entry BC3 alpha palette, expanded via `ch8_to_uq18`; interpolation uses shift+add (DD-039)
- RGB: decoded per BC1 color block algorithm

**BC4 Decoder (FORMAT=3) — `texture_bc4.sv`:**
- 8-byte block: single channel decoded via BC3 alpha interpolation algorithm, expanded via `ch8_to_uq18`
- Replicated to R=G=B (grayscale); A=`9'h100` (opaque)

**BC5 Decoder (FORMAT=4) — `texture_bc5.sv`:**
- 16-byte block: two independent BC3-style 8-byte single-channel alpha blocks
- First 8-byte block decodes the red channel using BC3 alpha interpolation (shift+add, DD-039)
- Second 8-byte block decodes the green channel using the same algorithm
- Output: R = decoded red, G = decoded green, B=`9'h000`, A=`9'h100` (opaque)
- Typically used for compressed two-channel normal maps (XY normals; Z is reconstructed downstream)

**RGB565 Decoder (FORMAT=5) — `texture_rgb565.sv`:**
- Fetch 32 bytes (16 × 16-bit pixels); expand each channel: R via `ch5_to_uq18`, G via `ch6_to_uq18`, B via `ch5_to_uq18`, A=`9'h100` (opaque)

**RGBA8888 Decoder (FORMAT=6) — `texture_rgba8888.sv`:**
- Fetch 64 bytes (16 × 32-bit pixels); each channel expanded via `ch8_to_uq18`

**R8 Decoder (FORMAT=7) — `texture_r8.sv`:**
- Fetch 16 bytes (16 × 8-bit values); expand via `ch8_to_uq18`; replicate R to G and B; A=`9'h100` (opaque)

### Texel Promotion: UQ1.8 → Q4.12

After the selected decoder produces UQ1.8 RGBA texels, `texel_promote.sv` promotes them to Q4.12 for the pixel pipeline.

The promotion formula (combinational, applied per channel):
```
Q4.12 = {3'b000, uq18[8:0], 3'b000}   // left-shift by 4, zero-pad (15-bit result)
```

This maps UQ1.8 value `0x100` (= 1.0) to Q4.12 value `0x1000` (= 1.0).
UQ1.8 LSB resolution 2⁻⁸ maps to Q4.12 resolution 2⁻¹², so 4 fractional bits of precision are added below the UQ1.8 LSB (all zero — no precision is lost or gained; the representation widens but the value is preserved exactly).
All four channels (R, G, B, A) use the same formula.

The UNIT-011 output contract is Q4.12 RGBA texel data.
`TEX_COLOR0` and `TEX_COLOR1` passed to UNIT-006 are always Q4.12.

## Implementation

- `components/texture/rtl/texture_bc1.sv`: BC1 decoder
- `components/texture/rtl/texture_bc2.sv`: BC2 decoder
- `components/texture/rtl/texture_bc3.sv`: BC3 decoder
- `components/texture/rtl/texture_bc4.sv`: BC4 single-channel decoder
- `components/texture/rtl/texture_bc5.sv`: BC5 two-channel decoder
- `components/texture/rtl/texture_rgb565.sv`: RGB565 uncompressed decoder
- `components/texture/rtl/texture_rgba8888.sv`: RGBA8888 uncompressed decoder
- `components/texture/rtl/texture_r8.sv`: R8 single-channel decoder
- `components/texture/rtl/texel_promote.sv`: UQ1.8 → Q4.12 texel promotion (combinational)
- `shared/fp_types_pkg.sv`: Q4.12 type definitions and promotion functions

The authoritative algorithmic design is the gs-texture twin crate (`components/texture/twin/`).
The RTL must produce bit-identical UQ1.8 and Q4.12 outputs to the twin for every supported format.

## Verification

- VER-005 (Texture Decoder Unit Testbench) — verifies all eight decoders produce correct UQ1.8 output for known input blocks

## Design Notes

**Estimated FPGA Resources:**
- BC1 decoder: ~180–250 LUTs, 0 DSPs (shift+add replaces division, DD-039)
- BC2/BC3 decoders: ~250–350 LUTs each, 0 DSPs
- BC4 decoder: ~120–180 LUTs, 0 DSPs
- BC5 decoder: ~200–300 LUTs, 0 DSPs (two independent BC3-style alpha paths)
- RGB565 decoder: ~30 LUTs, 0 DSPs
- RGBA8888 decoder: ~50 LUTs, 0 DSPs
- R8 decoder: ~20 LUTs, 0 DSPs
- Texel promotion (`texel_promote.sv`): ~50–100 LUTs (combinational wiring)

All decoders use 0 DSP slices; palette interpolation is purely combinational shift+add logic.
See REQ-011.02 for the GPU-wide resource budget.

**Decoders operate combinationally:** All eight decoders receive the raw block data and produce all 16 UQ1.8 texels within a single clock cycle (purely combinational logic for the decode step).
The format-select mux at the output is the only registered element.

**BC5 normal map usage:** BC5 outputs B=0, meaning Z-component reconstruction must be performed downstream (outside UNIT-011) by the shader or color combiner stage.
