# UNIT-010: Color Combiner

**Status: WIP — combiner equation pipeline timing and register decoding are under design.**

## Purpose

Two-stage pipelined programmable color combiner that produces a final fragment color from multiple input sources.
Separated from UNIT-006 (Pixel Pipeline) to allow independent design iteration on the combining formula.

The color combiner sits between the texture sampling stage (UNIT-006) and the fragment output stage (alpha blending + framebuffer write).
It is connected to both via FIFOs of fragment data, allowing each stage to stall independently.

## Implements Requirements

- REQ-003.02 (Multi-Texture Rendering — dual-texture color combining; sub-requirement under area 3: Texture Samplers)
- REQ-004.01 (Color Combiner — programmable combiner equation; sub-requirement under area 4: Fragment Processor/Color Combiner)
- REQ-004.02 (Extended Precision Fragment Processing — Q4.12 fixed-point arithmetic; sub-requirement under area 4: Fragment Processor/Color Combiner)

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
  - CC_MODE [63:0]: two-cycle combiner equation selectors (cycle 0 in [31:0], cycle 1 in [63:32])
  - CONST_COLOR [63:0]: CONST0 in [31:0], CONST1/fog color in [63:32] (RGBA8888 UNORM8, promoted to Q4.12 internally)
- Outputs combined fragment to downstream fragment output unit via output FIFO:
  - Combined RGBA color (Q4.12)
  - Fragment position (x, y) passthrough
  - Fragment Z passthrough

## Design Description

### Input Sources

The combiner has access to these color inputs (all in Q4.12):

| Source | CC Enum | Origin | Description |
|--------|---------|--------|-------------|
| COMBINED | CC_COMBINED | Cycle 0 output | Previous combiner stage output (feeds cycle 1) |
| TEX_COLOR0 | CC_TEX0 | UNIT-006 sampler 0 | Sampled and filtered texture 0 color |
| TEX_COLOR1 | CC_TEX1 | UNIT-006 sampler 1 | Sampled and filtered texture 1 color |
| SHADE0 | CC_SHADE0 | UNIT-005 rasterizer | Primary vertex color (typically diffuse) |
| SHADE1 | CC_SHADE1 | UNIT-005 rasterizer | Secondary vertex color (typically specular) |
| CONST0 | CC_CONST0 | UNIT-003 CONST_COLOR[31:0] | Per-draw-call constant color 0 |
| CONST1 | CC_CONST1 | UNIT-003 CONST_COLOR[63:32] | Per-draw-call constant color 1 / fog color |
| ONE | CC_ONE | Constant | Q4.12 value for 1.0 |
| ZERO | CC_ZERO | Constant | Q4.12 value for 0.0 |

The RGB C slot additionally accepts alpha-to-RGB broadcast sources (TEX0.A, TEX1.A, SHADE0.A, CONST0.A, COMBINED.A, SHADE1.A) per INT-010 cc_rgb_c_source_e.

### Outputs

| Signal | Width | Description |
|--------|-------|-------------|
| `combined_color` | 4×16 | Combined RGBA in Q4.12 |
| `frag_x` | 16 | Fragment X position (passthrough) |
| `frag_y` | 16 | Fragment Y position (passthrough) |
| `frag_z` | 16 | Fragment Z depth (passthrough) |
| `frag_valid` | 1 | Output fragment valid |

### Internal State

- Cycle 0 pipeline registers (Q4.12 RGBA)
- Cycle 1 pipeline registers (Q4.12 RGBA)
- COMBINED register (cycle 0 result, fed to cycle 1 as COMBINED source)
- Input FIFO read pointer
- Output FIFO write pointer

### Algorithm / Behavior

The combiner evaluates `(A - B) * C + D` independently for RGB and Alpha, twice in sequence.

**Cycle 0:**
- Select A, B, D from CC_SOURCE (9 sources, 4-bit selector)
- Select C from CC_RGB_C_SOURCE (15 sources for RGB C; same CC_SOURCE for Alpha C)
- Compute `result0 = (A - B) * C + D` in Q4.12
- Saturate: clamp result0 to Q4.12 UNORM [0.0, 1.0] range
- Store as COMBINED for cycle 1

**Cycle 1:**
- Select A, B, C, D using CC_MODE[63:32] fields; COMBINED = cycle 0 output
- Compute `result1 = (A - B) * C + D` in Q4.12
- Saturate result1

**Q4.12 Arithmetic:**
- MULTIPLY: `(a * b) >> 12` using 16×16 DSP multiplier (product[27:12])
- ADD: signed addition, saturate at ±Q4.12 max
- SUBTRACT: signed subtraction, result may be negative (this is intentional for the `A-B` term)
- All operations per-component (R, G, B, A independently)

**CONST color promotion:**
- CONST0 and CONST1 arrive as RGBA8888 UNORM8 from UNIT-003
- Promote to Q4.12 at combiner input: `{3'b0, unorm8, unorm8[7:4]}` (MSB replication, range [0, 1.0])

### Data Flow (Conceptual)

```
UNIT-006 (Pixel Pipeline)          UNIT-010 (Color Combiner)         Fragment Output
┌─────────────────────┐           ┌──────────────────────┐          ┌─────────────────┐
│ Depth range clip     │           │                      │          │                 │
│ Early Z-test         │  FIFO    │  Input muxing        │  FIFO   │ Alpha blend     │
│ Texture sample (×2)  │ ──────►  │  Cycle 0: (A-B)*C+D  │ ──────► │ FB read/write   │
│ Format promotion     │           │  Cycle 1: (A-B)*C+D  │          │ Z-buffer write  │
│ Stipple test         │           │  Output saturation   │          │ Dither          │
└─────────────────────┘           └──────────────────────┘          └─────────────────┘
                                          ▲
                                          │ CC_MODE, CONST_COLOR
                                   UNIT-003 (Register File)
```

## Implementation

- `spi_gpu/src/render/color_combiner.sv`: Two-stage programmable color combiner (TBD)

## Verification

Formal testbench: **VER-004** (`color_combiner_tb` — Verilator unit testbench; covers REQ-004.01 color combiner equation).
Note: VER-004 implementation is deferred until UNIT-010 WIP status is resolved and combiner pipeline timing is finalized.

- Verify cycle 0 modulate: `TEX0 * SHADE0` produces expected Q4.12 output
- Verify cycle 0 decal: `TEX0` passes through unchanged (C=ONE, B=D=ZERO)
- Verify two-stage specular: cycle 0 = `TEX0 * SHADE0`, cycle 1 = `COMBINED + SHADE1`
- Verify two-stage lightmap: cycle 0 = `TEX0 * TEX1`
- Verify fog: cycle 1 blends COMBINED toward CONST1 using SHADE0.A as fog factor
- Verify CONST0 and CONST1 inputs are correctly promoted from RGBA8888 to Q4.12
- Verify COMBINED source in cycle 1 equals cycle 0 output
- Verify RGB C alpha-broadcast sources: TEX0.A broadcast to R=G=B
- Verify saturation at Q4.12 max and clamping at 0.0
- Verify pipeline throughput: one fragment per clock cycle (no stalls in steady state)
- Verify FIFO backpressure: combiner stalls correctly when output FIFO is full
- VER-004 (Color Combiner Unit Testbench)
- VER-004 (Color Combiner Unit Testbench)

## Design Notes

This unit is extracted from the former Stage 4 of UNIT-006 (Pixel Pipeline).
The separation allows the combiner equation design to evolve independently from texture sampling and framebuffer output logic.

The architecture is directly inspired by the N64 RDP's two-cycle combiner, adapted to use Q4.12 (16-bit signed) arithmetic instead of the N64's 9-bit fixed-point.

**Resource estimate (preliminary):**
- 4–6 DSP slices (16×16 multipliers for per-channel multiply in each of 2 cycles)
- ~800–1200 LUTs (input muxes, subtraction, addition, saturation)
- 0 EBR (combinational/registered logic only)

**Open questions:**
- Exact pipeline register staging to meet 100 MHz timing closure
- Whether RGB and Alpha C selectors share decode logic or are fully independent
