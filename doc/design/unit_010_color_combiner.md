# UNIT-010: Color Combiner

**Status: WIP — combiner equation and register interface are under design.**

## Purpose

Pipelined programmable color combiner that produces a final fragment color from multiple input sources.
Separated from UNIT-006 (Pixel Pipeline) to allow independent design iteration on the combining formula.

The color combiner sits between the texture sampling stage (UNIT-006) and the fragment output stage (alpha blending + framebuffer write).
It is connected to both via FIFOs of fragment data, allowing each stage to stall independently.

## Implements Requirements

- REQ-003.02 (Multi-Texture Rendering — dual-texture color combining; sub-requirement under area 3: Texture Samplers)
- REQ-004.01 (Color Combiner — programmable combiner equation; sub-requirement under area 4: Fragment Processor/Color Combiner)
- REQ-004.02 (Extended Precision Fragment Processing — 10.8 fixed-point arithmetic; sub-requirement under area 4: Fragment Processor/Color Combiner)

## Interfaces

### Provides

None (internal pipeline stage).

### Consumes

- INT-010 (GPU Register Map — color combiner registers 0x18–0x1F, layout TBD)

### Internal Interfaces

- Receives fragment data from UNIT-006 (Pixel Pipeline) via input FIFO:
  - TEX_COLOR0: sampled texture 0 color (10.8 fixed-point RGBA)
  - TEX_COLOR1: sampled texture 1 color (10.8 fixed-point RGBA, white if TEX1 disabled)
  - VER_COLOR0: interpolated vertex color 0 / diffuse (10.8 fixed-point RGBA)
  - VER_COLOR1: interpolated vertex color 1 / specular (10.8 fixed-point RGBA)
  - Z value: interpolated depth (for Z_COLOR derivation)
  - Fragment position (x, y): passed through for downstream framebuffer addressing
  - Fragment Z: passed through for downstream Z-buffer write
- Receives configuration from UNIT-003 (Register File):
  - Combiner mode / equation selectors (register layout TBD)
  - MAT_COLOR0: material color 0 (RGBA8888, promoted to 10.8 internally)
  - MAT_COLOR1: material color 1 (RGBA8888, promoted to 10.8 internally)
  - FOG_COLOR or similar (TBD)
- Outputs combined fragment to downstream fragment output unit via output FIFO:
  - Combined RGBA color (10.8 fixed-point, to be demoted to 8-bit or RGB565 downstream)
  - Fragment position (x, y) passthrough
  - Fragment Z passthrough

## Design Description

### Input Sources

The combiner has access to these color inputs (all in 10.8 fixed-point):

| Source | Origin | Description |
|--------|--------|-------------|
| TEX_COLOR0 | UNIT-006 texture sampler 0 | Sampled and filtered texture 0 color |
| TEX_COLOR1 | UNIT-006 texture sampler 1 | Sampled and filtered texture 1 color |
| VER_COLOR0 | UNIT-005 rasterizer interpolation | Primary vertex color (typically diffuse lighting) |
| VER_COLOR1 | UNIT-005 rasterizer interpolation | Secondary vertex color (typically specular) |
| MAT_COLOR0 | UNIT-003 register 0x19 (TBD) | Material-wide constant color 0 |
| MAT_COLOR1 | UNIT-003 register 0x1A (TBD) | Material-wide constant color 1 |
| Z_COLOR | Derived from interpolated Z[15:8] | Depth-based factor for fog or other effects |

### Outputs

| Signal | Width | Description |
|--------|-------|-------------|
| `combined_color` | 4×18 | Combined RGBA in 10.8 fixed-point |
| `frag_x` | 16 | Fragment X position (passthrough) |
| `frag_y` | 16 | Fragment Y position (passthrough) |
| `frag_z` | 25 | Fragment Z depth (passthrough) |
| `frag_valid` | 1 | Output fragment valid |

### Internal State

- Pipeline registers for multi-cycle combiner evaluation
- Input FIFO read pointer
- Output FIFO write pointer

### Algorithm / Behavior

**TBD — the exact combiner equation and pipeline stages are under design.**

Known design constraints:
- All arithmetic in 10.8 fixed-point (18-bit values, REQ-004.02)
- RGB and Alpha channels may use independent equations (separate input selectors)
- Must support common effects:
  - Modulate: `TEX0 * VER_COLOR0` (diffuse textured)
  - Decal: `TEX0` (texture only)
  - Add specular: `TEX0 * VER_COLOR0 + VER_COLOR1`
  - Dual-texture modulate: `TEX0 * TEX1`
  - Fog: blend between scene color and fog color based on Z_COLOR
  - Material color: flat material color without texture
- The combiner will be pipelined to maintain throughput
- DSP slices (18×18 multipliers) used for multiply operations

### Data Flow (Conceptual)

```
UNIT-006 (Pixel Pipeline)          UNIT-010 (Color Combiner)         Fragment Output (TBD)
┌─────────────────────┐           ┌──────────────────────┐          ┌─────────────────┐
│ Depth range clip    │           │                      │          │                 │
│ Early Z-test        │  FIFO    │  Input muxing        │  FIFO   │ Alpha blend     │
│ Texture sample (×2) │ ──────►  │  Combiner equation   │ ──────► │ FB read/write   │
│ Format promotion    │           │  (pipelined)         │          │ Z-buffer write  │
│ Z_COLOR derivation  │           │  Output saturation   │          │ Dither          │
└─────────────────────┘           └──────────────────────┘          └─────────────────┘
                                         ▲
                                         │ Configuration
                                  UNIT-003 (Register File)
                                  combiner mode, MAT_COLOR0/1
```

## Implementation

- `spi_gpu/src/render/color_combiner.sv`: Programmable color combiner (TBD)

## Verification

- Verify modulate mode: `TEX0 * VER_COLOR0` produces expected output
- Verify decal mode: `TEX0` passes through unchanged
- Verify dual-texture: `TEX0 * TEX1` produces expected output
- Verify fog: blend between scene color and fog color based on Z_COLOR
- Verify add-specular: `TEX0 * VER_COLOR0 + VER_COLOR1` with saturation
- Verify MAT_COLOR0/1 inputs are correctly promoted from RGBA8888 to 10.8
- Verify saturation at 10-bit max (1023) and clamping at 0
- Verify pipeline throughput: one fragment per clock cycle (no stalls in steady state)
- Verify FIFO backpressure: combiner stalls correctly when output FIFO is full

## Design Notes

This unit is extracted from the former Stage 4 of UNIT-006 (Pixel Pipeline).
The separation allows the combiner equation design to evolve independently from texture sampling and framebuffer output logic.

The N64 RDP uses a similar `(A - B) * C + D` combiner with selectable inputs.
The GeForce2 MX uses register combiners with a comparable programmable stage.
The exact equation format for this GPU is still being determined.

**Resource estimate (preliminary):**
- 4–6 DSP slices (18×18 multipliers for per-channel multiply)
- ~800–1200 LUTs (input muxes, subtraction, addition, saturation)
- 0 EBR (combinational/registered logic only)

**Open questions:**
- Single `(A-B)*C+D` equation or chained stages?
- Should Z_COLOR go through a color LUT (EBR-based) for non-linear fog curves?
- Exact register encoding for input selectors
- Whether RGB and Alpha use the same or independent equation selectors
