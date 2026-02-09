# UNIT-006: Pixel Pipeline

## Purpose

Texture sampling, blending, z-test, framebuffer write

## Implements Requirements

- REQ-003 (Flat Shaded Triangle)
- REQ-004 (Gouraud Shaded Triangle)
- REQ-005 (Depth Tested Triangle)
- REQ-006 (Textured Triangle)
- REQ-008 (Multi-Texture Rendering)
- REQ-009 (Texture Blend Modes)
- REQ-010 (Compressed Textures)
- REQ-011 (Swizzle Patterns)
- REQ-012 (UV Wrapping Modes)
- REQ-013 (Alpha Blending)
- REQ-014 (Enhanced Z-Buffer)
- REQ-016 (Triangle-Based Clearing)
- REQ-024 (Texture Sampling)
- REQ-027 (Z-Buffer Operations)
- REQ-028 (Alpha Blending)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)
- INT-014 (Texture Memory Layout)

### Internal Interfaces

TBD

## Design Description

### Inputs

- Fragment position (x, y) from rasterizer (UNIT-005)
- Interpolated UV coordinates (per texture unit)
- Interpolated vertex color (for Gouraud shading)
- Interpolated Z depth value
- Register state (TEXn_FMT, TEXn_BASE, TEXn_BLEND, TEXn_WRAP, TRI_MODE, etc.)

### Outputs

- Pixel color (RGB565) to framebuffer
- Z value to Z-buffer (if Z_WRITE enabled)

### Internal State

- Texture decode pipeline registers
- BC1 block cache (optional optimization)

### Algorithm / Behavior

The pixel pipeline processes rasterized fragments through the following stages:

1. **Texture Sampling (per enabled texture unit):**
   - Apply UV wrapping mode (REQ-012, TEXn_WRAP)
   - Calculate texture address using block-organized layout (INT-014)
   - Decode texture format based on TEXn_FMT.FORMAT:
     - FORMAT=00 (RGBA4444): Read 16-bit pixel, expand to RGBA8 (FR-024-1)
     - FORMAT=01 (BC1): Read 8-byte block, decompress, extract pixel (FR-024-2)
   - Apply swizzle pattern (REQ-011, TEXn_FMT.SWIZZLE)

2. **Multi-Texture Blending:**
   - Sample up to 4 texture units (TEX0-TEX3)
   - Blend sequentially using TEXn_BLEND modes (REQ-009)
   - TEX0_BLEND is ignored (first texture is passthrough)

3. **Shading:**
   - Multiply by interpolated vertex color if GOURAUD enabled (REQ-004)

4. **Z-Buffer Test:**
   - Compare fragment Z with Z-buffer value (REQ-027)
   - Z_COMPARE function from FB_ZBUFFER register
   - Early discard if test fails

5. **Alpha Blending:**
   - Blend with framebuffer using ALPHA_BLEND mode (REQ-013, REQ-028)

6. **Framebuffer Write:**
   - Convert RGBA8 to RGB565 (REQ-025)
   - Write to framebuffer at FB_DRAW address
   - If Z_WRITE enabled, write Z value to Z-buffer

### Implementation Notes

**RGBA4444 Decoder (SystemVerilog):**
```systemverilog
// Extract 4-bit channels from 16-bit pixel
wire [3:0] r4 = pixel_data[15:12];
wire [3:0] g4 = pixel_data[11:8];
wire [3:0] b4 = pixel_data[7:4];
wire [3:0] a4 = pixel_data[3:0];

// Expand to 8-bit by replicating high nibble
wire [7:0] r8 = {r4, r4};
wire [7:0] g8 = {g4, g4};
wire [7:0] b8 = {b4, b4};
wire [7:0] a8 = {a4, a4};
```

**BC1 Decoder (High-Level Design):**
- Implement 4-stage pipeline:
  1. **Block fetch:** Read 8 bytes from SRAM (2 cycles on 16-bit bus = 4 reads)
  2. **Color palette generation:** RGB565 decode + interpolation
  3. **Index extraction:** 2-bit lookup from 32-bit index word
  4. **Color output:** Select palette entry, apply alpha
- RGB565 -> RGB888 conversion using shift and replicate
- Color interpolation using fixed-point dividers (divide-by-3 or divide-by-2)
- Alpha mode detection: compare color0 vs color1 as u16

**Estimated FPGA Resources:**
- RGBA4444 decoder: ~20 LUTs, 0 DSPs
- BC1 decoder: ~150-200 LUTs, 2-4 DSPs (for division), 64-byte BRAM (palette cache)

## Implementation

- `spi_gpu/src/render/pixel_pipeline.sv`: Main implementation
- `spi_gpu/src/render/texture_rgba4444.sv`: RGBA4444 decoder (new)
- `spi_gpu/src/render/texture_bc1.sv`: BC1 decoder (new)

## Verification

- Testbench for RGBA4444 decoder: verify all 16 nibble values expand correctly
- Testbench for BC1 decoder: verify 4-color and 1-bit alpha modes
- Integration test with rasterizer: render textured triangles and compare to reference

## Design Notes

Migrated from speckit module specification. Updated for RGBA4444/BC1 texture formats (v3.0).
