# UNIT-004: Triangle Setup

## Purpose

Prepares triangle for rasterization

## Implements Requirements

- REQ-003 (Flat Shaded Triangle)
- REQ-004 (Gouraud Shaded Triangle)
- REQ-023 (Rasterization Algorithm)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)

### Internal Interfaces

- Receives triangle vertex data from UNIT-003 (Register File) via tri_valid and vertex buses
- Outputs edge function coefficients, bounding box, and vertex attributes to UNIT-005 (Edge Walker / rasterizer iteration stages)
- Receives fb_base_addr and zb_base_addr configuration from UNIT-003
- Issues framebuffer and Z-buffer memory requests to UNIT-007 (SRAM Arbiter) ports 1 and 2

## Design Description

### Inputs

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | System clock |
| `rst_n` | 1 | Active-low reset |
| `tri_valid` | 1 | Triangle ready to rasterize |
| `v0_x`, `v0_y` | 16 each | Vertex 0 position (12.4 fixed point) |
| `v0_z` | 16 | Vertex 0 depth |
| `v0_color` | 24 | Vertex 0 RGB888 color |
| `v1_x`, `v1_y` | 16 each | Vertex 1 position (12.4 fixed point) |
| `v1_z` | 16 | Vertex 1 depth |
| `v1_color` | 24 | Vertex 1 RGB888 color |
| `v2_x`, `v2_y` | 16 each | Vertex 2 position (12.4 fixed point) |
| `v2_z` | 16 | Vertex 2 depth |
| `v2_color` | 24 | Vertex 2 RGB888 color |
| `inv_area` | 16 | 1/area (0.16 fixed point) from CPU |
| `fb_base_addr` | 20 | Framebuffer base address [31:12] |
| `zb_base_addr` | 20 | Z-buffer base address [31:12] |
| `fb_ack`, `fb_ready` | 1 each | SRAM arbiter handshake for framebuffer port |
| `fb_rdata` | 32 | Framebuffer read data (unused) |
| `zb_ack`, `zb_ready` | 1 each | SRAM arbiter handshake for Z-buffer port |
| `zb_rdata` | 32 | Z-buffer read data |

### Outputs

| Signal | Width | Description |
|--------|-------|-------------|
| `tri_ready` | 1 | Ready to accept new triangle |
| `fb_req` | 1 | Framebuffer SRAM request |
| `fb_we` | 1 | Framebuffer write enable (always 1) |
| `fb_addr` | 24 | Framebuffer SRAM address |
| `fb_wdata` | 32 | Framebuffer write data (RGB565 in lower 16 bits) |
| `zb_req` | 1 | Z-buffer SRAM request |
| `zb_we` | 1 | Z-buffer write enable (0=read, 1=write) |
| `zb_addr` | 24 | Z-buffer SRAM address |
| `zb_wdata` | 32 | Z-buffer write data (16-bit depth in lower half) |

### Internal State

**FSM States (4-bit):**
- IDLE (0): Waiting for tri_valid, tri_ready asserted
- SETUP (1): Compute edge function coefficients and bounding box
- ITER_START (2): Initialize scanline position and compute triangle area
- EDGE_TEST (3): Evaluate edge functions at current pixel
- BARY_CALC (4): Check inside/outside and compute barycentric weights
- INTERPOLATE (5): Interpolate Z and color using barycentric coordinates
- ZBUF_READ (6): Issue Z-buffer read request
- ZBUF_WAIT (7): Wait for Z-buffer read acknowledgement
- ZBUF_TEST (8): Compare interpolated Z with stored Z
- WRITE_PIXEL (9): Issue framebuffer and Z-buffer writes
- WRITE_WAIT (10): Wait for write acknowledgements
- ITER_NEXT (11): Advance to next pixel in bounding box

**Vertex Registers:**
- x0..x2, y0..y2 [9:0]: Integer pixel coordinates (converted from 12.4 by dropping fractional bits)
- z0..z2 [15:0]: Depth values
- r0..r2, g0..g2, b0..b2 [7:0]: Per-vertex RGB components

**Edge Function Coefficients:**
- edge0_A/B/C, edge1_A/B/C, edge2_A/B/C [20:0 signed]: E(x,y) = A*x + B*y + C

**Bounding Box:**
- bbox_min_x, bbox_max_x, bbox_min_y, bbox_max_y [9:0]: Screen-clamped bounding box

**Iteration State:**
- curr_x, curr_y [9:0]: Current pixel position
- e0, e1, e2 [31:0 signed]: Edge function values at current pixel
- w0, w1, w2 [31:0]: Barycentric weights (e * inv_area)
- interp_z [15:0], interp_r/g/b [7:0]: Interpolated fragment values
- zbuf_value [15:0]: Z-buffer value read from SRAM
- inv_area_reg [15:0]: Latched 1/area
- tri_area_x2 [31:0 signed]: 2x triangle area

### Algorithm / Behavior

**SETUP State (1 cycle):**
Computes three edge function coefficient sets from the latched vertex positions:
- Edge 0 (v1->v2): A = y1-y2, B = x2-x1, C = x1*y2 - x2*y1
- Edge 1 (v2->v0): A = y2-y0, B = x0-x2, C = x2*y0 - x0*y2
- Edge 2 (v0->v1): A = y0-y1, B = x1-x0, C = x0*y1 - x1*y0

Computes bounding box as min/max of vertex coordinates clamped to screen (640x480).

**ITER_START State (1 cycle):**
Sets curr_x/curr_y to bbox top-left. Computes tri_area_x2 by evaluating edge0 at v0.

**Rasterization Loop (EDGE_TEST -> BARY_CALC -> INTERPOLATE -> ZBUF_READ -> ZBUF_WAIT -> ZBUF_TEST -> WRITE_PIXEL -> WRITE_WAIT -> ITER_NEXT):**
1. Evaluate all three edge functions at (curr_x, curr_y)
2. If all e0, e1, e2 >= 0: pixel is inside triangle; compute barycentric weights w = e[15:0] * inv_area_reg
3. Interpolate Z and RGB using weighted sum, shift right 16, and saturate
4. Read Z-buffer at (zb_base + curr_y*640 + curr_x)
5. If interp_z < zbuf_value: write RGB565 pixel to framebuffer and new Z to Z-buffer
6. Advance to next pixel; scan left-to-right, top-to-bottom within bounding box
7. Return to IDLE when bounding box exhausted

## Implementation

- `spi_gpu/src/render/rasterizer.sv`: Main implementation (SETUP and ITER_START states implement triangle setup; remaining states implement edge walking and pixel output)

## Verification

- Verify edge function computation: known triangle vertices produce correct A/B/C coefficients
- Verify bounding box clamping: vertices outside 640x480 produce clamped bounds
- Verify inside/outside test: sample points inside and outside a known triangle
- Verify barycentric interpolation: known weights produce correct interpolated colors
- Verify Z-buffer test: closer fragment passes, farther fragment is discarded
- Verify pixel output: RGB888 to RGB565 conversion is correct (R[7:3], G[7:2], B[7:3])
- Verify degenerate triangles: zero-area triangle produces no pixel writes
- Verify SRAM handshake: fb_req/zb_req deassert correctly after ack

## Design Notes

Migrated from speckit module specification.
