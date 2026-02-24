# UNIT-004: Triangle Setup

## Purpose

Prepares triangle for rasterization

## Parent Requirements

- REQ-002 (Rasterizer)

## Implements Requirements

- REQ-002.01 (Flat Shaded Triangle)
- REQ-002.02 (Gouraud Shaded Triangle)
- REQ-002.03 (Rasterization Algorithm)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)

### Internal Interfaces

- Receives triangle vertex data from UNIT-003 (Register File) via tri_valid and vertex buses
- Outputs edge function coefficients, bounding box, and vertex attributes to UNIT-005 (Edge Walker / rasterizer iteration stages)
- Receives fb_base_addr and zb_base_addr configuration from UNIT-003

**Note:** UNIT-004 does not directly issue SRAM memory requests.
Triangle setup computes edge coefficients and bounding boxes, then emits fragment data to UNIT-005 (Rasterizer) which in turn passes fragments to UNIT-006 (Pixel Pipeline).
All SRAM memory access for framebuffer and Z-buffer occurs within UNIT-006.

## Design Description

### Inputs

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | Unified 100 MHz system clock (`clk_core`) |
| `rst_n` | 1 | Active-low reset |
| `tri_valid` | 1 | Triangle ready to rasterize |
| `v0_x`, `v0_y` | 16 each | Vertex 0 position (12.4 fixed point) |
| `v0_z` | 16 | Vertex 0 depth |
| `v0_color0` | 24 | Vertex 0 primary RGB888 color (diffuse) |
| `v0_color1` | 24 | Vertex 0 secondary RGB888 color (specular/emissive) |
| `v1_x`, `v1_y` | 16 each | Vertex 1 position (12.4 fixed point) |
| `v1_z` | 16 | Vertex 1 depth |
| `v1_color0` | 24 | Vertex 1 primary RGB888 color (diffuse) |
| `v1_color1` | 24 | Vertex 1 secondary RGB888 color (specular/emissive) |
| `v2_x`, `v2_y` | 16 each | Vertex 2 position (12.4 fixed point) |
| `v2_z` | 16 | Vertex 2 depth |
| `v2_color0` | 24 | Vertex 2 primary RGB888 color (diffuse) |
| `v2_color1` | 24 | Vertex 2 secondary RGB888 color (specular/emissive) |
| `inv_area` | 16 | 1/area (0.16 fixed point) from CPU |
| `fb_base_addr` | 20 | Framebuffer base address [31:12] |
| `zb_base_addr` | 20 | Z-buffer base address [31:12] |
| `downstream_ready` | 1 | UNIT-005 ready to accept setup data |

### Outputs

| Signal | Width | Description |
|--------|-------|-------------|
| `tri_ready` | 1 | Ready to accept new triangle |
| `setup_valid` | 1 | One-cycle pulse: setup data is ready for UNIT-005 |
| `setup_edge0_A/B` | 2x11 signed | Edge 0 A/B coefficients (differences of 10-bit coords) |
| `setup_edge0_C` | 21 signed | Edge 0 C coefficient (product of 10-bit coords) |
| `setup_edge1_A/B` | 2x11 signed | Edge 1 A/B coefficients |
| `setup_edge1_C` | 21 signed | Edge 1 C coefficient |
| `setup_edge2_A/B` | 2x11 signed | Edge 2 A/B coefficients |
| `setup_edge2_C` | 21 signed | Edge 2 C coefficient |
| `setup_bbox_min_x` | 10 | Bounding box minimum X |
| `setup_bbox_max_x` | 10 | Bounding box maximum X |
| `setup_bbox_min_y` | 10 | Bounding box minimum Y |
| `setup_bbox_max_y` | 10 | Bounding box maximum Y |
| `setup_v0_z`, `setup_v1_z`, `setup_v2_z` | 3x16 | Vertex Z depths |
| `setup_v0_color0`, `setup_v1_color0`, `setup_v2_color0` | 3x24 | Vertex primary RGB888 colors (diffuse) |
| `setup_v0_color1`, `setup_v1_color1`, `setup_v2_color1` | 3x24 | Vertex secondary RGB888 colors (specular/emissive) |
| `setup_inv_area` | 16 | 1/area (0.16 fixed point) passed through |

### Internal State

**FSM States (4-bit, setup-relevant subset):**
- IDLE (0): Waiting for tri_valid, tri_ready asserted
- SETUP (1): Compute edge A/B coefficients and bounding box; compute edge0_C via shared multiplier pair (1 cycle)
- SETUP_2 (13): Compute edge1_C via shared multiplier pair (1 cycle)
- SETUP_3 (14): Compute edge2_C via shared multiplier pair (1 cycle)

The 6 edge C multiplications (2 per edge × 3 edges) are serialized through a shared pair of 11×11 multipliers over 3 cycles, using only 2 physical MULT18X18D blocks instead of 6.

**Note:** Legacy states ITER_START through ITER_NEXT (states 2-11 in previous versions) have been removed.
Pixel iteration, Z-buffer access, and framebuffer writes are now handled downstream by UNIT-005 (Edge Walker) and UNIT-006 (Pixel Pipeline).

**Vertex Registers:**
- x0..x2, y0..y2 [9:0]: Integer pixel coordinates (converted from 12.4 by dropping fractional bits)
- z0..z2 [15:0]: Depth values
- r0_0..r2_0, g0_0..g2_0, b0_0..b2_0 [7:0]: Per-vertex primary RGB components (color0, diffuse)
- r0_1..r2_1, g0_1..g2_1, b0_1..b2_1 [7:0]: Per-vertex secondary RGB components (color1, specular/emissive)

**Edge Function Coefficients:**
- edge0_A/B, edge1_A/B, edge2_A/B [10:0 signed]: Edge slopes (11-bit, differences of 10-bit coords)
- edge0_C, edge1_C, edge2_C [20:0 signed]: Edge constants (21-bit, products of 10-bit coords)

**Bounding Box:**
- bbox_min_x, bbox_max_x, bbox_min_y, bbox_max_y [9:0]: Screen-clamped bounding box

**Latched Pass-Through:**
- inv_area_reg [15:0]: Latched 1/area (passed through to UNIT-005)

### Algorithm / Behavior

**SETUP States (3 cycles at 100 MHz = 30 ns):**
Computes three edge function coefficient sets from the latched vertex positions:
- Edge 0 (v1→v2): A = y1-y2, B = x2-x1, C = x1*y2 - x2*y1
- Edge 1 (v2→v0): A = y2-y0, B = x0-x2, C = x2*y0 - x0*y2
- Edge 2 (v0→v1): A = y0-y1, B = x1-x0, C = x0*y1 - x1*y0

A and B coefficients (differences) are computed combinationally in SETUP.
C coefficients (products) are serialized one per cycle through a shared multiplier pair: edge0_C in SETUP, edge1_C in SETUP_2, edge2_C in SETUP_3.

Computes bounding box as min/max of vertex coordinates clamped to screen (640x480).

**Output Handshake (EMIT state):**
1. Assert `setup_valid` for one cycle with all edge coefficients, bounding box, vertex attributes, and inv_area on the output buses.
2. Wait for downstream ready (UNIT-005 backpressure).
3. Return to IDLE, reassert `tri_ready`.

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
- Verify setup_valid handshake: setup_valid asserts for one cycle and deasserts when downstream_ready is low
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-010 (Gouraud Triangle Golden Image Test)
- VER-011 (Depth-Tested Overlapping Triangles Golden Image Test)

## Design Notes

Migrated from speckit module specification.

**Reconciliation:** UNIT-004 previously described the entire rasterization pipeline including pixel iteration, Z-buffer access, and framebuffer writes.
These responsibilities have been split: UNIT-004 now performs only triangle setup (edge coefficients, bounding box), emitting results to UNIT-005 (Edge Walker) which iterates pixels and passes fragments to UNIT-006 (Pixel Pipeline) for Z-test, color write, and SRAM access.
The FSM was reduced from 12 states (4-bit) to 3 states (3-bit).
SRAM arbiter ports 1 and 2 are now driven by UNIT-006, not UNIT-004.
See DD-015 for rationale.

**Dual-texture + color combiner update:** Triangle setup now passes through two vertex colors (color0 and color1) per vertex instead of one.
UV passthrough is reduced from up to 4 sets to up to 2 sets (UV0, UV1 only; UV2_UV3 register removed).
The second vertex color (color1) supports the color combiner's VER_COLOR1 input for specular highlights, emissive terms, or blend factors.

**Unified clock update:** Triangle setup now runs at 100 MHz (`clk_core`), doubling computation throughput compared to the previous 50 MHz design.
The setup FSM (IDLE → SETUP → SETUP_2 → SETUP_3) completes edge coefficient computation in 3 cycles (30 ns at 100 MHz) using a shared pair of 11×11 multipliers.
Combined with the 3-cycle initial edge evaluation (ITER_START → INIT_E1 → INIT_E2), total triangle setup is 6 cycles (60 ns).
Since the SPI interface limits triangle throughput to one every ~72+ core cycles minimum (4-bit QSPI @ 25 MHz), the serialized setup has zero impact on sustained performance.
This serialization reduces setup multiplier usage from 12 to 2 MULT18X18D blocks, contributing to the overall reduction from 47 to 17 blocks.
