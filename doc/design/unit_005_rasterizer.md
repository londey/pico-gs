# UNIT-005: Rasterizer

## Purpose

Edge-walking rasterization engine

## Implements Requirements

- REQ-003 (Flat Shaded Triangle)
- REQ-004 (Gouraud Shaded Triangle)
- REQ-005 (Depth Tested Triangle)
- REQ-006 (Textured Triangle)
- REQ-023 (Rasterization Algorithm)
- REQ-134 (Extended Precision Fragment Processing) — RGBA8 interpolation output promotion to 10.8

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)

### Internal Interfaces

- Receives triangle vertex data from UNIT-003 (Register File) via tri_valid/tri_ready handshake
- Writes framebuffer pixels to SRAM via UNIT-007 (SRAM Arbiter) port 1
- Reads/writes Z-buffer via UNIT-007 (SRAM Arbiter) port 2
- Receives framebuffer and Z-buffer base addresses from UNIT-003 configuration registers

## Design Description

### Inputs

- Triangle vertex data from UNIT-004 (Triangle Setup):
  - 3× vertex position (X, Y, Z)
  - 3× vertex color (RGBA8 — ABGR8888 from COLOR register)
  - 3× UV coordinates per enabled texture unit (up to 4 sets)
- Register state (TRI_MODE, FB_DRAW, FB_ZBUFFER)

### Outputs

- Fragment data to UNIT-006 (Pixel Pipeline):
  - Fragment position (x, y) in screen coordinates
  - Interpolated Z depth (16-bit)
  - Interpolated vertex color in 10.8 fixed-point (4× 18-bit channels: R, G, B, A)
  - Interpolated UV coordinates per enabled texture unit (up to 4 sets)

**Note**: The rasterizer does **not** write directly to the framebuffer. All fragment output goes through the pixel pipeline (UNIT-006) for texture blending, dithering, and framebuffer conversion.

### Internal State

- Edge-walking state machine registers
- Barycentric coordinate accumulators (8.8 fixed-point per channel)
- Current scanline and span tracking

### Algorithm / Behavior

1. **Edge Setup**: Compute edge slopes and initial values from triangle vertices
2. **Edge Walking**: Walk left and right edges scanline by scanline
3. **Span Interpolation**: For each pixel in the span:
   a. Interpolate RGBA8 vertex colors using barycentric coordinates with 8.8 fixed-point accumulators
   b. Promote interpolated values to 10.8 format: 8-bit integer values placed in [17:8], fractional bits from interpolation preserved in [7:0]
   c. Interpolate Z depth and UV coordinates
   d. Output fragment to pixel pipeline (UNIT-006)

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Main implementation

## Verification

- Verify edge function computation for known triangles (clockwise/counter-clockwise winding)
- Test bounding box clamping at screen edges (0, 639, 479)
- Verify barycentric interpolation produces correct colors at vertices and midpoints
- Test Z-buffer read-compare-write sequence with near/far values
- Verify RGB888-to-RGB565 conversion in framebuffer writes
- Test degenerate triangles (zero area, single-pixel, off-screen)
- Verify SRAM arbiter handshake (req/ack/ready protocol)

## Design Notes

Migrated from speckit module specification.
