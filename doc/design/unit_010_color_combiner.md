# UNIT-010: Color Combiner

## Purpose

Single-instance time-multiplexed programmable color combiner that evaluates up to three passes (CC0, CC1, CC2/blend) per fragment, producing the final output color including alpha blending and fog within a 4-cycle/fragment throughput target.
Separated from UNIT-006 (Pixel Pipeline) to allow independent design iteration on the combining formula.

The color combiner sits between the texture sampling stage (UNIT-006) and the framebuffer write stage.
It is connected to both via FIFOs of fragment data, allowing each stage to stall independently.
Pass 2 (CC2) reads the destination pixel from the color tile buffer (a 4×4 register file of 16×16-bit entries populated by burst reads from SDRAM), enabling alpha blending without per-pixel framebuffer reads.

## Implements Requirements

- REQ-003.02 (Multi-Texture Rendering — dual-texture color combining; sub-requirement under area 3: Texture Samplers)
- REQ-004.01 (Color Combiner — programmable combiner equation; sub-requirement under area 4: Fragment Processor/Color Combiner)
- REQ-004.02 (Extended Precision Fragment Processing — Q4.12 fixed-point arithmetic; sub-requirement under area 4: Fragment Processor/Color Combiner)
- REQ-005.03 (Alpha Blending — implemented as CC pass 2 with DST_COLOR from the color tile buffer)
- REQ-004 (Fragment Processor / Color Combiner)
- REQ-011.02 (Resource Constraints)

## Interfaces

### Provides

None (internal pipeline stage).

### Consumes

- INT-010 (GPU Register Map — CC_MODE at 0x18, CONST_COLOR at 0x19)

### Internal Interfaces

- Receives fragment data from UNIT-006 (Pixel Pipeline) via input FIFO:
  - TEX_COLOR0: sampled texture 0 color (Q4.12 RGBA)
  - TEX_COLOR1: sampled texture 1 color (Q4.12 RGBA, white if TEX1 disabled)
  - SHADE0: interpolated vertex color 0 / diffuse (Q4.12 RGBA)
  - SHADE1: interpolated vertex color 1 / specular (Q4.12 RGBA)
  - Fragment position (x, y): passed through for downstream framebuffer addressing
  - Fragment Z: passed through for downstream Z-buffer write
- Receives configuration from UNIT-003 (Register File):
  - CC_MODE [95:0]: three-pass combiner equation selectors (pass 0 in [31:0], pass 1 in [63:32], pass 2 in [95:64])
  - CONST_COLOR [63:0]: CONST0 in [31:0], CONST1/fog color in [63:32] (RGBA8888 UNORM8, promoted to Q4.12 internally)
  - RENDER_MODE.ALPHA_BLEND [9:7]: selects which CC pass-2 equation template is applied
- Receives DST_COLOR from color tile buffer (UNIT-006): promoted destination pixel (RGB565 → Q4.12) for the fragment's tile position
- Outputs combined fragment to framebuffer write stage via output FIFO:
  - Combined RGBA color (Q4.12)
  - Fragment position (x, y) passthrough
  - Fragment Z passthrough

## Design Description

### Input Sources

The combiner has access to these color inputs (all in Q4.12):

| Source | CC Enum | Origin | Description |
| ------ | ------- | ------ | ----------- |
| COMBINED | CC_COMBINED | Previous pass output | Previous combiner pass output (pass 0 feeds pass 1; pass 1 feeds pass 2) |
| TEX_COLOR0 | CC_TEX0 | UNIT-011 sampler 0 | Sampled and filtered texture 0 color (Q4.12 RGBA from UNIT-011) |
| TEX_COLOR1 | CC_TEX1 | UNIT-011 sampler 1 | Sampled and filtered texture 1 color (Q4.12 RGBA from UNIT-011) |
| SHADE0 | CC_SHADE0 | UNIT-005 rasterizer | Primary vertex color (typically diffuse) |
| SHADE1 | CC_SHADE1 | UNIT-005 rasterizer | Secondary vertex color (typically specular) |
| CONST0 | CC_CONST0 | UNIT-003 CONST_COLOR[31:0] | Per-draw-call constant color 0 |
| CONST1 | CC_CONST1 | UNIT-003 CONST_COLOR[63:32] | Per-draw-call constant color 1 / fog color |
| DST_COLOR | CC_DST_COLOR | Color tile buffer | Promoted destination pixel from framebuffer (RGB565 → Q4.12); available in all passes |
| ONE | CC_ONE | Constant | Q4.12 value for 1.0 |
| ZERO | CC_ZERO | Constant | Q4.12 value for 0.0 |

The RGB C slot additionally accepts alpha-to-RGB broadcast sources (TEX0.A, TEX1.A, SHADE0.A, CONST0.A, COMBINED.A, SHADE1.A) per INT-010 cc_rgb_c_source_e.

### Outputs

| Signal | Width | Description |
| ------ | ----- | ----------- |
| `combined_color` | 4×16 | Combined RGBA in Q4.12 |
| `frag_x` | 16 | Fragment X position (passthrough) |
| `frag_y` | 16 | Fragment Y position (passthrough) |
| `frag_z` | 16 | Fragment Z depth (passthrough) |
| `frag_valid` | 1 | Output fragment valid |

### Internal State

- Pass 0 pipeline registers (Q4.12 RGBA)
- Pass 1 pipeline registers (Q4.12 RGBA)
- Pass 2 pipeline registers (Q4.12 RGBA)
- COMBINED register (updated after each pass; pass 0 output feeds pass 1; pass 1 output feeds pass 2)
- Pass counter (2-bit, cycles through 0→1→2→0 at fragment rate)
- Input FIFO read pointer
- Output FIFO write pointer

### Algorithm / Behavior

The combiner evaluates `(A - B) * C + D` independently for RGB and Alpha, for each of three passes in sequence per fragment.
A single physical `(A-B)*C+D` datapath is time-multiplexed across all three passes within the 4-cycle/fragment budget.

**Pass 0 (CC0):**

- Select A, B, D from CC_SOURCE (10 sources including DST_COLOR, 4-bit selector)
- Select C from CC_RGB_C_SOURCE (15 sources for RGB C; same CC_SOURCE for Alpha C)
- Compute `result0 = (A - B) * C + D` in Q4.12
- Saturate: clamp result0 to Q4.12 UNORM [0.0, 1.0] range
- Store as COMBINED for pass 1

**Pass 1 (CC1):**

- Select A, B, C, D using CC_MODE[63:32] fields; COMBINED = pass 0 output
- Compute `result1 = (A - B) * C + D` in Q4.12
- Saturate result1
- Store as COMBINED for pass 2

**Pass 2 (CC2 / Blend):**

- Input selectors use CC_MODE[95:64]; COMBINED = pass 1 output
- DST_COLOR source is available: the promoted destination pixel read from the color tile buffer for this fragment's tile position (RGB565 → Q4.12 promotion per FR-134-5)
- The RENDER_MODE.ALPHA_BLEND field selects a predefined pass-2 equation template:
  - **DISABLED (000):** A=COMBINED, B=ZERO, C=ONE, D=ZERO (pass-through; no blend)
  - **ADD (001):** `result = saturate(COMBINED + DST_COLOR)`
  - **SUBTRACT (010):** `result = saturate(COMBINED - DST_COLOR)`
  - **BLEND (011):** `result = COMBINED * COMBINED.A + DST_COLOR * (ONE - COMBINED.A)` (Porter-Duff source-over)
- Pass-2 equation templates may be overridden by explicit CC_MODE[95:64] selectors for custom blend or fog configurations
- Saturate result2 to UNORM [0.0, 1.0]
- Pass-2 output is the final combined color forwarded to dither and framebuffer write

**Q4.12 Arithmetic:**

- MULTIPLY: `(a * b) >> 12` using 16×16 DSP multiplier (product[27:12])
- ADD: signed addition, saturate at ±Q4.12 max
- SUBTRACT: signed subtraction, result may be negative (this is intentional for the `A-B` term)
- All operations per-component (R, G, B, A independently)
- ONE (1.0 in Q4.12 = 0x1000) and ZERO (0.0 in Q4.12 = 0x0000) are arithmetic constants defined in `rtl/pkg/fp_types_pkg.sv`; color_combiner.sv imports this package rather than duplicating the literal values.

**CONST color promotion:**

- CONST0 and CONST1 arrive as RGBA8888 UNORM8 from UNIT-003
- Promote to Q4.12 at combiner input: `{3'b0, unorm8, unorm8[7:4]}` (MSB replication, range [0, 1.0])

**DST_COLOR promotion:**

- DST_COLOR arrives as RGB565 from the color tile buffer
- Promote each channel to Q4.12 using MSB replication (same rule as FR-134-2):
  R5 → Q4.12: `{3'b0, R5, R5[4:1], 3'b0}`; G6 → Q4.12: `{3'b0, G6, G6[5:2], 2'b0}`; B5 → same as R5
- Alpha channel of DST_COLOR is set to ONE (RGB565 has no alpha storage)

### Data Flow (Conceptual)

```text
UNIT-006 (Pixel Pipeline)          UNIT-010 (Color Combiner)         Framebuffer Write
┌─────────────────────┐           ┌──────────────────────┐          ┌─────────────────┐
│ Depth range clip     │           │                      │          │                 │
│ Early Z-test         │  FIFO    │  Input muxing        │  FIFO   │ Dither          │
│ Texture sample (×2)  │ ──────►  │  Pass 0: (A-B)*C+D   │ ──────► │ RGB565 pack     │
│ Format promotion     │           │  Pass 1: (A-B)*C+D   │          │ FB burst write  │
│ Stipple test         │           │  Pass 2: (A-B)*C+D   │          │ Z-buffer write  │
└─────────────────────┘           │  (blend via DST_COLOR)│          └─────────────────┘
                                  └──────────────────────┘
                                          ▲           ▲
                                          │           │ DST_COLOR (RGB565→Q4.12)
                                          │    ┌──────────────────┐
                                  CC_MODE,│    │ Color Tile Buffer │
                                  CONST_  │    │ (4×4, 16×16-bit) │
                                  COLOR   │    │ burst fill/flush  │
                              UNIT-003    │    └──────────────────┘
                          (Register File) │           │
                                          │     SDRAM (burst R/W)
```

## Implementation

- `rtl/components/color-combiner/src/color_combiner.sv`: Single-instance time-multiplexed programmable color combiner with 3-pass control (CC0, CC1, CC2/blend); 2 pipeline stages per pass (mux+subtract, then multiply+add+saturate) within the 4-cycle/fragment budget.

## Verification

Formal testbench: **VER-004** (`color_combiner_tb` — Verilator unit testbench; covers REQ-004.01 color combiner equation).

- Verify pass 0 modulate: `TEX0 * SHADE0` produces expected Q4.12 output
- Verify pass 0 decal: `TEX0` passes through unchanged (C=ONE, B=D=ZERO)
- Verify two-pass specular: pass 0 = `TEX0 * SHADE0`, pass 1 = `COMBINED + SHADE1`
- Verify two-pass lightmap: pass 0 = `TEX0 * TEX1`
- Verify fog: pass 1 blends COMBINED toward CONST1 using SHADE0.A as fog factor
- Verify pass 2 ADD blend: `saturate(COMBINED + DST_COLOR)` matches reference
- Verify pass 2 SUBTRACT blend: `saturate(COMBINED - DST_COLOR)` matches reference
- Verify pass 2 BLEND: Porter-Duff source-over using COMBINED.A as alpha factor matches reference
- Verify DST_COLOR promotion from RGB565 to Q4.12 (MSB replication)
- Verify CONST0 and CONST1 inputs are correctly promoted from RGBA8888 to Q4.12
- Verify COMBINED source in pass 1 equals pass 0 output; COMBINED in pass 2 equals pass 1 output
- Verify RGB C alpha-broadcast sources: TEX0.A broadcast to R=G=B
- Verify saturation at Q4.12 max and clamping at 0.0
- Verify pipeline throughput: one fragment per 4 clock cycles (no stalls in steady state)
- Verify FIFO backpressure: combiner stalls correctly when output FIFO is full
- VER-004 (Color Combiner Unit Testbench)
- VER-013 (Color-Combined Output Golden Image Test)
- VER-024 (Alpha Blend Modes Golden Image Test — exercises pass 2 blend modes)

## Design Notes

This unit is extracted from the former Stage 4 of UNIT-006 (Pixel Pipeline).
The separation allows the combiner equation design to evolve independently from texture sampling and framebuffer output logic.

The architecture is directly inspired by the N64 RDP's two-cycle combiner, extended with a third blend pass and adapted to use Q4.12 (16-bit signed) arithmetic instead of the N64's 9-bit fixed-point.
By expressing alpha blending as CC pass 2, the dedicated alpha blend unit is eliminated; all color combination — including blending with the framebuffer destination — uses a single time-multiplexed `(A-B)*C+D` datapath.
The color tile buffer (4×4 register file, managed by UNIT-006) provides DST_COLOR to pass 2 via burst reads, replacing per-pixel SDRAM reads.

**Resource estimate:**

- 3–4 DSP slices (single shared 16×16 multiplier datapath, time-multiplexed across 3 passes)
- ~300 LUTs (input muxes, pass counter, subtraction, addition, saturation)
- 0 EBR (combinational/registered logic only; tile buffer registers are in UNIT-006)

**Pipeline staging for 100 MHz timing closure:**

The single shared datapath is split into two pipeline stages per pass (6 stages across 3 passes, issued at 1 pass/cycle):

- Stage A: source mux + A-B subtraction (registered output)
- Stage B: multiply by C, add D, saturate (registered output, result forwarded as COMBINED for the next pass)

This staging limits the critical path to a single 16×16 multiply plus adder per stage, meeting 100 MHz closure on ECP5-25K.
Three-pass execution consumes 3 cycles of the 4-cycle/fragment budget; the fourth cycle is available for tile buffer stall insertion when a tile boundary is crossed and a burst fill is in progress.
Each of the 4 RGBA channel paths is independent (no cross-channel dependency in `(A-B)*C+D`), so channel paths can be placed in parallel DSP columns.

**RGB and Alpha C decode:** RGB and Alpha use independent C selector decode logic because the RGB C slot accepts 15 sources (including alpha-broadcast sources such as TEX0.A) while the Alpha C slot uses the same 10-source CC_SOURCE enum (including DST_COLOR).
The decode is split: a 4-bit `rgb_c_source` field selects from the 15 RGB C sources; a 4-bit `cc_source` field selects from the 10 shared sources for A, B, D, and Alpha C.
The additional broadcast sources (TEX0.A, TEX1.A, SHADE0.A, CONST0.A, COMBINED.A, SHADE1.A) are implemented as simple wires replicating the Alpha channel of the corresponding source to all three RGB channels before the RGB C mux.
