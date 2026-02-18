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
| `setup_v0_color`, `setup_v1_color`, `setup_v2_color` | 3x24 | Vertex RGB888 colors |
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
- r0..r2, g0..g2, b0..b2 [7:0]: Per-vertex RGB components

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

## Design Notes

Migrated from speckit module specification.

**v10.0 reconciliation:** UNIT-004 previously described the entire rasterization pipeline including pixel iteration, Z-buffer access, and framebuffer writes.
These responsibilities have been split: UNIT-004 now performs only triangle setup (edge coefficients, bounding box), emitting results to UNIT-005 (Edge Walker) which iterates pixels and passes fragments to UNIT-006 (Pixel Pipeline) for Z-test, color write, and SRAM access.
The FSM was reduced from 12 states (4-bit) to 3 states (3-bit).
SRAM arbiter ports 1 and 2 are now driven by UNIT-006, not UNIT-004.
See DD-015 for rationale.

**v2.0 unified clock update:** Triangle setup now runs at 100 MHz (`clk_core`), doubling computation throughput compared to the previous 50 MHz design.
The setup FSM (IDLE → SETUP → SETUP_2 → SETUP_3) completes edge coefficient computation in 3 cycles (30 ns at 100 MHz) using a shared pair of 11×11 multipliers.
Combined with the 3-cycle initial edge evaluation (ITER_START → INIT_E1 → INIT_E2), total triangle setup is 6 cycles (60 ns).
Since the SPI interface limits triangle throughput to one every ~72+ core cycles minimum (4-bit QSPI @ 25 MHz), the serialized setup has zero impact on sustained performance.
This serialization reduces setup multiplier usage from 12 to 2 MULT18X18D blocks, contributing to the overall reduction from 47 to 17 blocks.
