# INT-010: GPU Register Map

## Type

Internal

## Parties

- **Provider:** UNIT-003 (Register File)
- **Consumer:** UNIT-001 (SPI Slave Controller)
- **Consumer:** UNIT-004 (Triangle Setup)
- **Consumer:** UNIT-005 (Rasterizer)
- **Consumer:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-008 (Display Controller)
- **Consumer:** UNIT-022 (GPU Driver Layer)

## Referenced By

- REQ-001 (Basic Host Communication)
- REQ-002 (Framebuffer Management)
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
- REQ-015 (Memory Upload Interface)
- REQ-016 (Triangle-Based Clearing)
- REQ-110 (GPU Initialization)
- REQ-118 (Clear Framebuffer)
- REQ-132 (Ordered Dithering)
- REQ-133 (Color Grading LUT)
- REQ-134 (Extended Precision Fragment Processing)
- REQ-123 (Double-Buffered Rendering)
- REQ-105 (GPU Communication Protocol)
- REQ-131 (Texture Cache)
- REQ-052 (Reliability Requirements)
- REQ-050 (Performance Targets)
- REQ-051 (Resource Constraints)
- REQ-027 (Z-Buffer Operations)
- REQ-026 (Display Output Timing)
- REQ-024 (Texture Sampling)
- REQ-023 (Rasterization Algorithm)
- REQ-022 (Vertex Submission Protocol)
- REQ-029 (Memory Upload Interface)
- REQ-028 (Alpha Blending)

## Specification


**Version**: 8.0
**Date**: February 2026
**Status**: Enhanced Rendering Features + Register Consolidation (Pre-1.0)

---

## Overview

The GPU is controlled via a 7-bit address space providing 128 register locations. Each register is 64 bits wide, though many use fewer bits (unused bits are reserved and must be written as zero, read as zero).

**Transaction Format** (72 bits total):
```
[71]      R/W̄ (1 = read, 0 = write)
[70:64]   Register address (7 bits)
[63:0]    Register value (64 bits)
```

**Major Features** (v8.0):
- 4 independent texture units with separate UV coordinates
- **DOT3 bump mapping with interpolated light direction (v8.0)**
- **Dual vertex colors: diffuse (multiply) + specular (add) (v8.0)**
- **Trilinear texture filtering for smooth LOD transitions (v8.0)**
- RGBA4444 and BC1 block-compressed texture formats (see INT-014)
- Swizzle patterns for channel reordering
- **Unified RENDER_MODE register (TRI_MODE + ALPHA_BLEND + Z-modes + dithering) (v8.0)**
- **Scissor rectangle for pixel clipping (v8.0)**
- **Framebuffer write enable masks (Z-buffer, color buffer) (v8.0)**
- Memory upload interface
- Color grading LUT at scanout
- Integrated triangle kick mode control (v6.0)
- **Packed performance counters: 2×32-bit per register (v8.0)**
- Backface culling based on winding order (v6.0)
- **Optimized register packing: 53 → 46 active registers (v8.0)**

---

## Address Space Organization

```
0x00-0x0F: Vertex State (COLOR, UV0_UV1, UV2_UV3, LIGHT_DIR, VERTEX variants)
0x10-0x1F: Texture Configuration (4 units × 4 registers each, TIGHTLY PACKED)
0x20-0x2F: Reserved (freed from old texture registers)
0x30-0x3F: Rendering Configuration (RENDER_MODE consolidated)
0x40-0x4F: Framebuffer, Z-Buffer, Scissor, Color Grading
0x50-0x5F: Performance Counters (PACKED: 2×32-bit per register)
0x60-0x6F: Reserved (freed from old performance counters)
0x70-0x7F: Status & Control (MEM_ADDR, MEM_DATA, STATUS, ID)
```

**Key Optimizations** (v8.0):
- Register count reduced from 53 to 46 active registers (13% reduction)
- Texture units compressed from 5 to 4 registers each (eliminates TEXn_BLEND)
- Performance counters packed from 15 to 8 registers (2×32-bit pairs)
- 33+ registers freed for future features (0x20-0x2F, 0x58-0x6F)

---

## Register Summary

| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| **Vertex State** ||||
| 0x00 | COLOR | W | Diffuse[63:32] + Specular[31:0] vertex colors (v8.0: CHANGED) |
| 0x01 | UV0_UV1 | W | Texture units 0+1 coordinates (packed) |
| 0x02 | UV2_UV3 | W | Texture units 2+3 coordinates (packed) |
| 0x03 | LIGHT_DIR | W | Light direction XYZ for DOT3 (X8Y8Z8) (v8.0: NEW) |
| 0x04-0x05 | - | - | Reserved (future vertex attributes) |
| 0x06 | VERTEX_NOKICK | W | Vertex position + 1/W, no triangle draw |
| 0x07 | VERTEX_KICK_012 | W | Vertex position + 1/W, draw tri (v[0], v[1], v[2]) |
| 0x08 | VERTEX_KICK_021 | W | Vertex position + 1/W, draw tri (v[0], v[2], v[1]) |
| 0x09-0x0F | - | - | Reserved (future vertex attributes) |
| **Texture Unit 0** ||||
| 0x10 | TEX0_BASE | R/W | Texture 0 base address |
| 0x11 | TEX0_FMT | R/W | Format, dimensions, swizzle, **blend, filter** (v8.0: CHANGED) |
| 0x12 | TEX0_MIP_BIAS | R/W | Mipmap LOD bias (v8.0: MOVED from 0x13) |
| 0x13 | TEX0_WRAP | R/W | UV wrapping mode (v8.0: MOVED from 0x14) |
| **Texture Unit 1** ||||
| 0x14 | TEX1_BASE | R/W | Texture 1 base address (v8.0: MOVED from 0x18) |
| 0x15 | TEX1_FMT | R/W | Format, dimensions, swizzle, blend, filter (v8.0: MOVED+CHANGED) |
| 0x16 | TEX1_MIP_BIAS | R/W | Mipmap LOD bias (v8.0: MOVED from 0x1B) |
| 0x17 | TEX1_WRAP | R/W | UV wrapping mode (v8.0: MOVED from 0x1C) |
| **Texture Unit 2** ||||
| 0x18 | TEX2_BASE | R/W | Texture 2 base address (v8.0: MOVED from 0x20) |
| 0x19 | TEX2_FMT | R/W | Format, dimensions, swizzle, blend, filter (v8.0: MOVED+CHANGED) |
| 0x1A | TEX2_MIP_BIAS | R/W | Mipmap LOD bias (v8.0: MOVED from 0x23) |
| 0x1B | TEX2_WRAP | R/W | UV wrapping mode (v8.0: MOVED from 0x24) |
| **Texture Unit 3** ||||
| 0x1C | TEX3_BASE | R/W | Texture 3 base address (v8.0: MOVED from 0x28) |
| 0x1D | TEX3_FMT | R/W | Format, dimensions, swizzle, blend, filter (v8.0: MOVED+CHANGED) |
| 0x1E | TEX3_MIP_BIAS | R/W | Mipmap LOD bias (v8.0: MOVED from 0x2B) |
| 0x1F | TEX3_WRAP | R/W | UV wrapping mode (v8.0: MOVED from 0x2C) |
| 0x20-0x2F | - | - | Reserved (v8.0: FREED from texture registers) |
| **Rendering Config** ||||
| 0x30 | RENDER_MODE | R/W | **Unified rendering state** (v8.0: CHANGED, consolidates TRI_MODE+ALPHA_BLEND+Z-modes+dither) |
| 0x31-0x32 | - | - | Reserved (v8.0: FREED, was ALPHA_BLEND, DITHER_MODE) |
| 0x33-0x3F | - | - | Reserved (rendering config) |
| **Framebuffer** ||||
| 0x40 | FB_DRAW | R/W | Draw target framebuffer address |
| 0x41 | FB_DISPLAY | R/W | Display scanout framebuffer address |
| 0x42 | FB_ZBUFFER | R/W | Z-buffer address (v8.0: Z_COMPARE moved to RENDER_MODE) |
| 0x43 | FB_CONTROL | R/W | **Scissor rect + write enables** (v8.0: NEW) |
| 0x44 | COLOR_GRADE_CTRL | R/W | Color grading LUT control |
| 0x45 | COLOR_GRADE_LUT_ADDR | R/W | Color grading LUT address |
| 0x46 | COLOR_GRADE_LUT_DATA | W | Color grading LUT data |
| 0x47-0x4F | - | - | Reserved (framebuffer config) |
| **Performance Counters** ||||
| 0x50 | PERF_TEX0 | R | **TEX0 hits[31:0] + misses[63:32]** (v8.0: PACKED) |
| 0x51 | PERF_TEX1 | R | TEX1 hits + misses (v8.0: PACKED) |
| 0x52 | PERF_TEX2 | R | TEX2 hits + misses (v8.0: PACKED) |
| 0x53 | PERF_TEX3 | R | TEX3 hits + misses (v8.0: PACKED) |
| 0x54 | PERF_PIXELS | R | Pixels written[31:0] + fragments passed[63:32] (v8.0: PACKED) |
| 0x55 | PERF_FRAGMENTS | R | Fragments failed[31:0] + reserved[63:32] (v8.0: PACKED) |
| 0x56 | PERF_STALL_VS | R | Vertex stalls[31:0] + SRAM stalls[63:32] (v8.0: PACKED) |
| 0x57 | PERF_STALL_CT | R | Cache stalls[31:0] + triangles[63:32] (v8.0: PACKED) |
| 0x58-0x6F | - | - | Reserved (v8.0: FREED, 24 registers freed) |
| **Status & Control** ||||
| 0x70 | MEM_ADDR | R/W | Memory upload address pointer |
| 0x71 | MEM_DATA | R/W | Memory upload data (auto-increment) |
| 0x72-0x7D | - | - | Reserved |
| 0x7E | STATUS | R | GPU status and FIFO depth |
| 0x7F | ID | R | GPU identification |

---

## Vertex State Registers (0x00-0x0F)

### 0x00: COLOR (Diffuse + Specular)

Latches RGBA colors for the next vertex push. Now holds both diffuse and specular colors.

```
[63:56]   Diffuse Alpha (8 bits)
[55:48]   Diffuse Blue (8 bits)
[47:40]   Diffuse Green (8 bits)
[39:32]   Diffuse Red (8 bits)
[31:24]   Specular Alpha (8 bits)
[23:16]   Specular Blue (8 bits)
[15:8]    Specular Green (8 bits)
[7:0]     Specular Red (8 bits)
```

**Blending Pipeline**:
```
Step 1: Sample textures and blend sequentially (TEX0 → TEX1 → TEX2 → TEX3)
Step 2: Multiply by diffuse color: result = texture_result × diffuse_rgba
Step 3: Add specular color: result = result + specular_rgba (clamped to [0, 1])
Step 4: Apply alpha blend with framebuffer if ALPHA_BLEND != DISABLED
```

**Notes**:
- Diffuse multiplies with texture output (tints and modulates lighting)
- Specular adds after texture blending (creates highlights independent of textures)
- In flat shading mode (GOURAUD=0), only vertex 0's colors are used
- Values are 0-255, where 255 = full intensity
- Color is associated with the next VERTEX write

**Reset Value**: 0x00000000_00000000 (both transparent black)

---

### 0x01: UV0_UV1

Latches texture coordinates for texture units 0 and 1. Values are pre-divided by W for perspective correction. **Note**: 1/W (Q) is now stored in VERTEX registers (v6.0 change).

```
[63:48]   UV1_VQ = V1/W (1.15 signed fixed-point)
[47:32]   UV1_UQ = U1/W (1.15 signed fixed-point)
[31:16]   UV0_VQ = V0/W (1.15 signed fixed-point)
[15:0]    UV0_UQ = U0/W (1.15 signed fixed-point)
```

**Fixed-Point Format (1.15)**:
- Bit 15: Sign
- Bits 14:0: Fractional value
- Range: -1.0 to +0.99997
- Resolution: 1/32768 ≈ 0.00003

**Notes**:
- Host must compute U/W, V/W per vertex for each texture unit
- GPU reconstructs U = UQ/Q, V = VQ/Q per pixel using Q from VERTEX register
- If only UV0 is used (single texture), write UV1 fields as 0
- UV coordinates for disabled texture units are ignored

**Reset Value**: 0x0000000000000000

---

### 0x02: UV2_UV3

Latches texture coordinates for texture units 2 and 3. Values are pre-divided by W for perspective correction.

```
[63:48]   UV3_VQ = V3/W (1.15 signed fixed-point)
[47:32]   UV3_UQ = U3/W (1.15 signed fixed-point)
[31:16]   UV2_VQ = V2/W (1.15 signed fixed-point)
[15:0]    UV2_UQ = U2/W (1.15 signed fixed-point)
```

**Notes**:
- Same format as UV0_UV1
- Only required when using 3 or 4 texture units simultaneously
- If only UV2 is used, write UV3 fields as 0

**Reset Value**: 0x0000000000000000

---

### 0x03: LIGHT_DIR

Latches light direction vector for DOT3 bump mapping. Interpolated across the triangle (Gouraud-style).

```
[63:24]   Reserved (write as 0)
[23:16]   Z direction (signed 8-bit, -128 to +127)
[15:8]    Y direction (signed 8-bit, -128 to +127)
[7:0]     X direction (signed 8-bit, -128 to +127)
```

**Format**: Signed 8-bit fixed-point, range [-1.0, +0.992] (scale: 128 = 1.0)

**Usage with DOT3**:
```
Per-vertex (host):
  light_dir = normalize(light_position - vertex_position)
  X = clamp(light_dir.x × 128, -128, 127)
  Y = clamp(light_dir.y × 128, -128, 127)
  Z = clamp(light_dir.z × 128, -128, 127)
  gpu_write(REG_LIGHT_DIR, (Z << 16) | (Y << 8) | X)

Per-pixel (GPU):
  light_xyz = interpolate_linear(v0.light_dir, v1.light_dir, v2.light_dir, bary)
  normal_xyz = texture_sample(normal_map) × 2 - 1  // Map [0,1] to [-1,+1]
  dot3_result = clamp(dot(normal_xyz, light_xyz), 0, 1)
  // Use dot3_result in texture blending when BLEND=DOT3
```

**Notes**:
- Light direction interpolated linearly across triangle (like vertex colors)
- Interpolated vector may not be unit length, but acceptable for DOT3
- Requires texture unit configured with BLEND=DOT3 mode
- Normal map texture typically uses RGBA4444 or BC1 encoding

**Reset Value**: 0x0000000000000000 (zero vector)

---

### 0x04-0x05: Reserved

Reserved for future vertex attributes (normals, tangents, skinning weights, etc.).

**Reset Value**: N/A (reserved)

---

### 0x06: VERTEX

Latches vertex position and 1/W, then triggers vertex push based on **RENDER_MODE[TRI_KICK_MODE]** field.

```
[63:48]   Q = 1/W (1.15 signed fixed-point) — v6.0: moved from UV registers
[47:32]   Z depth (16 bits unsigned)
[31:16]   Y coordinate (12.4 signed fixed-point)
[15:0]    X coordinate (12.4 signed fixed-point)
```

**Fixed-Point Format (12.4)**:
- Bits 15:4: Signed integer (-2048 to +2047)
- Bits 3:0: Fractional (1/16 pixel)

**Fixed-Point Format Q (1.15)**:
- Bit 15: Sign
- Bits 14:0: Fractional value
- Same format as UQ/VQ in UV registers

**Z Format (16 bits)**:
- Unsigned, 0 = near plane, 0xFFFF = far plane
- Maps to normalized device coordinates after projection
- Higher values are further away

**Vertex Push Behavior**:
```
Write to VERTEX:
  vertex[vertex_count] = {current_COLOR, current_UV0-UV3, X, Y, Z}
  vertex_count++
  if vertex_count == 3:
    submit_triangle(vertex[0], vertex[1], vertex[2])
    vertex_count = 0
```

**Reset Value**: N/A (write-only trigger)

---

### 0x06: VERTEX_NOKICK

Latches vertex position and 1/W without triggering triangle rasterization. Used to accumulate vertices for strips, fans, or explicit triangle submission.

```
[63:48]   Q = 1/W (1.15 signed fixed-point)
[47:32]   Z depth (16 bits unsigned)
[31:16]   Y coordinate (12.4 signed fixed-point)
[15:0]    X coordinate (12.4 signed fixed-point)
```

**Behavior**:
```
Write to VERTEX_NOKICK:
  vertex_buffer[vertex_count] = {current_COLOR, current_UV0_UV1, current_UV2_UV3, X, Y, Z, Q}
  vertex_count = (vertex_count + 1) % 3  // Wrap at 3
  // No triangle submission
```

**Use Cases**:
- **Triangle Strips**: Write first 2 vertices with NOKICK, then alternate KICK modes
- **Triangle Fans**: Write center vertex with NOKICK, then kick subsequent triangles
- **Explicit Control**: Accumulate 3 vertices, then trigger draw with a KICK register

**Reset Value**: N/A (write-only trigger)

---

### 0x07: VERTEX_KICK_012

Latches vertex position and 1/W, then triggers triangle rasterization with vertex order (v[0], v[1], v[2]).

```
[63:48]   Q = 1/W (1.15 signed fixed-point)
[47:32]   Z depth (16 bits unsigned)
[31:16]   Y coordinate (12.4 signed fixed-point)
[15:0]    X coordinate (12.4 signed fixed-point)
```

**Behavior**:
```
Write to VERTEX_KICK_012:
  vertex_buffer[vertex_count] = {current_COLOR, current_UV0_UV1, current_UV2_UV3, X, Y, Z, Q}
  vertex_count = (vertex_count + 1) % 3
  submit_triangle(vertex_buffer[0], vertex_buffer[1], vertex_buffer[2])  // CW winding
```

**Winding Order**: Counter-clockwise (CCW) when vertices are in screen-space order (0, 1, 2).

**Use Cases**:
- Standard triangle rendering (same as deprecated VERTEX register)
- Triangle strips (odd triangles maintain winding)
- Triangle fans (all triangles with same winding)

**Reset Value**: N/A (write-only trigger)

---

### 0x08: VERTEX_KICK_021

Latches vertex position and 1/W, then triggers triangle rasterization with **reversed** vertex order (v[0], v[2], v[1]).

```
[63:48]   Q = 1/W (1.15 signed fixed-point)
[47:32]   Z depth (16 bits unsigned)
[31:16]   Y coordinate (12.4 signed fixed-point)
[15:0]    X coordinate (12.4 signed fixed-point)
```

**Behavior**:
```
Write to VERTEX_KICK_021:
  vertex_buffer[vertex_count] = {current_COLOR, current_UV0_UV1, current_UV2_UV3, X, Y, Z, Q}
  vertex_count = (vertex_count + 1) % 3
  submit_triangle(vertex_buffer[0], vertex_buffer[2], vertex_buffer[1])  // Reversed
```

**Winding Order**: Clockwise (CW) when using the same vertex order as KICK_012. This reverses the triangle facing.

**Use Cases**:
- **Triangle strips**: Alternate with KICK_012 to maintain consistent winding across strip
  - Triangle 0: NOKICK, NOKICK, KICK_012 (v0, v1, v2) → CCW
  - Triangle 1: KICK_021 (v2, v1, v3) → CCW (winding maintained!)
  - Triangle 2: KICK_012 (v2, v3, v4) → CCW
- **Backface culling control**: Explicitly reverse winding for special cases

**Strip Example**:
```c
// 5-vertex triangle strip
gpu_write(COLOR, color0); gpu_write(UV0_UV1, uv0); gpu_write(VERTEX_NOKICK, v0);  // v[0]
gpu_write(COLOR, color1); gpu_write(UV0_UV1, uv1); gpu_write(VERTEX_NOKICK, v1);  // v[1]
gpu_write(COLOR, color2); gpu_write(UV0_UV1, uv2); gpu_write(VERTEX_KICK_012, v2); // Draw tri(v0,v1,v2)
gpu_write(COLOR, color3); gpu_write(UV0_UV1, uv3); gpu_write(VERTEX_KICK_021, v3); // Draw tri(v2,v1,v3)
gpu_write(COLOR, color4); gpu_write(UV0_UV1, uv4); gpu_write(VERTEX_KICK_012, v4); // Draw tri(v2,v3,v4)
```

**Reset Value**: N/A (write-only trigger)

---

## Texture Configuration Registers (0x10-0x2F)

Each texture unit has 8 registers (0x10-0x17 for unit 0, 0x18-0x1F for unit 1, etc.). The register layout is identical for all 4 units.

### TEXn_BASE (0x10, 0x18, 0x20, 0x28)

Base address of texture in SRAM. Must be 4K aligned.

```
[63:32]   Reserved (write as 0)
[31:12]   Base address bits [31:12]
[11:0]    Ignored (assumed 0 for 4K alignment)
```

**Example**:
- Texture at SRAM address 0x340000
- Write value: 0x00000000_00340000
- Effective address: 0x340000

**Reset Value**: 0x0000000000000000

---

### TEXn_FMT (0x11, 0x15, 0x19, 0x1D) - Expanded

Texture format, dimensions, swizzle, **blend mode**, **filtering**, and mipmap levels.

```
[63:27]   Reserved (write as 0)
[26:24]   BLEND: Texture blend function (3 bits) - v8.0 NEW
          000 = MULTIPLY (component-wise: result = prev × current)
          001 = ADD (component-wise: result = prev + current, saturate)
          010 = SUBTRACT (component-wise: result = prev - current, saturate)
          011 = INVERSE_SUBTRACT (component-wise: result = current - prev, saturate)
          100 = DOT3 (dot product for bump mapping, see below)
          101-111 = Reserved
[23:20]   MIP_LEVELS: Number of mipmap levels (0-15)
          0000 = No mipmaps (disabled, single level only)
          0001 = Base level only (equivalent to 0, backward compatible)
          0010 = Base + 1 mip level (2 levels total)
          ...
          1011 = Base + 10 mip levels (11 levels total, max for 1024×1024)
          1100-1111 = Reserved
[19:16]   SWIZZLE: Channel reordering pattern (4 bits, see encoding below)
[15:12]   HEIGHT_LOG2: log₂(height), valid 3-10 (8 to 1024 pixels)
[11:8]    WIDTH_LOG2: log₂(width), valid 3-10 (8 to 1024 pixels)
[7:6]     FILTER: Filtering mode (2 bits) - v8.0 NEW
          00 = NEAREST (sharp, pixelated, no interpolation)
          01 = BILINEAR (smooth, 2×2 tap filter)
          10 = TRILINEAR (smooth + mipmap blend, requires MIP_LEVELS>1)
          11 = Reserved
[5:4]     Reserved (write as 0)
[3:2]     FORMAT: Texture format encoding
          00 = RGBA4444 (16 bits per pixel, see INT-014)
          01 = BC1 (block compressed, 64 bits per 4x4 block, see INT-014)
          10 = Reserved (future format)
          11 = Reserved (future format)
[1]       Reserved (write as 0)
[0]       ENABLE: 0=disabled, 1=enabled
```

**BLEND Mode Details** (v8.0 NEW):

- **MULTIPLY** (000): `result = prev × current` (default, modulates colors)
- **ADD** (001): `result = prev + current` (brightens, saturates at 1.0)
- **SUBTRACT** (010): `result = prev - current` (darkens, clamps at 0.0)
- **INVERSE_SUBTRACT** (011): `result = current - prev` (reversed subtract)
- **DOT3** (100): **Bump mapping mode**
  ```
  normal_xyz = current_texture.rgb × 2.0 - 1.0    // Map [0,1] to [-1,+1]
  light_xyz = interpolated LIGHT_DIR vector
  dot3 = clamp(dot(normal_xyz, light_xyz), 0, 1)
  result.rgb = prev.rgb × dot3                     // Modulate by lighting
  result.a = prev.a                                // Alpha unchanged
  ```
  **Note**: DOT3 expects normal map in texture RGB channels (typically tangent-space normals).

**FILTER Mode Details** (v8.0 NEW):

- **NEAREST** (00): Sample single texel, no interpolation. Sharp pixelated look, lowest cost.
- **BILINEAR** (01): 2×2 texel interpolation within a mip level. Smooth, moderate cost.
- **TRILINEAR** (10): Bilinear + blend between two mip levels. Smoothest, highest cost. Falls back to BILINEAR if MIP_LEVELS ≤ 1.

**Texture Blend Order**: Textures evaluated sequentially (0→1→2→3):
```
Step 1: Sample TEX0, filter → color = tex0_rgba
Step 2: Sample TEX1, filter, blend: color = blend(color, tex1_rgba, TEX1_FMT.BLEND)
Step 3: Sample TEX2, filter, blend: color = blend(color, tex2_rgba, TEX2_FMT.BLEND)
Step 4: Sample TEX3, filter, blend: color = blend(color, tex3_rgba, TEX3_FMT.BLEND)
Step 5: Multiply by diffuse color: color = color × COLOR.diffuse
Step 6: Add specular color: color = color + COLOR.specular
Step 7: Apply alpha blend with framebuffer if ALPHA_BLEND mode enabled
```

**Note**: TEX0_FMT.BLEND is ignored (no previous texture to blend with).

**Format Notes**:
- BC1 textures (FORMAT=01) require width and height to be multiples of 4
- Attempting to use non-multiple-of-4 dimensions with BC1 results in undefined behavior
- Swizzle patterns apply after texture decode (see INT-014)
- See INT-014 for detailed texture memory layout specifications

**Mipmap Notes**:
- MIP_LEVELS=0 or MIP_LEVELS=1: Single level only, no mipmap addressing
- MIP_LEVELS=N (N>1): Texture has N mipmap levels stored sequentially per INT-014
- Maximum mip levels = min(11, min(WIDTH_LOG2, HEIGHT_LOG2) + 1)
  - Example: 256×256 (log2=8) can have up to 9 levels (256→128→64→32→16→8→4→2→1)
- See INT-014 for mipmap chain memory layout

**Dimension Encoding**:

| Value | Dimension |
|-------|-----------|
| 3 | 8 |
| 4 | 16 |
| 5 | 32 |
| 6 | 64 |
| 7 | 128 |
| 8 | 256 |
| 9 | 512 |
| 10 | 1024 |

**Swizzle Pattern Encoding** (4 bits [19:16]):

| Code | Pattern | Description |
|------|---------|-------------|
| 0x0 | RGBA | Identity (default) |
| 0x1 | BGRA | Swap red/blue channels |
| 0x2 | ARGB | Alpha first |
| 0x3 | ABGR | Alpha first, blue/red swapped |
| 0x4 | GBRA | Green first |
| 0x5 | R000 | Red only, others zero |
| 0x6 | 000A | Alpha only, RGB zero |
| 0x7 | RRR1 | Red replicated to RGB, alpha=1 (grayscale) |
| 0x8 | GGG1 | Green replicated to RGB, alpha=1 |
| 0x9 | BBB1 | Blue replicated to RGB, alpha=1 |
| 0xA | AAA1 | Alpha replicated to RGB, alpha=1 |
| 0xB | 1110 | RGB=1 (white), alpha=0 |
| 0xC | 111A | RGB=1 (white), preserve alpha |
| 0xD-0xF | Reserved | Default to RGBA |

**Example**: 64x64 texture, RGBA4444, enabled, bilinear, multiply blend, no mipmaps
→ WIDTH_LOG2=6, HEIGHT_LOG2=6, FORMAT=00, FILTER=01, BLEND=000, MIP_LEVELS=1
→ write 0x00000000_00100661 | (0x0 << 24) | (0x1 << 6) = 0x00000000_001006A1

**Example**: 256x256 texture, BC1, enabled, trilinear, DOT3 blend, 9 mipmap levels
→ WIDTH_LOG2=8, HEIGHT_LOG2=8, FORMAT=01, FILTER=10, BLEND=100 (DOT3), MIP_LEVELS=9
→ write 0x00000000_00900883 | (0x4 << 24) | (0x2 << 6) = 0x00000000_049008C3

**Reset Value**: 0x0000000000000000 (disabled, RGBA4444, 8×8, multiply, nearest)

---

### TEXn_BLEND (REMOVED in v8.0)

**v7.0**: Previously at addresses 0x12, 0x1A, 0x22, 0x2A

**v8.0 CHANGE**: BLEND mode packed into TEXn_FMT[26:24]. This register no longer exists as a separate entity.

These addresses are now used for TEXn_MIP_BIAS (v8.0 reorganization).

---

### TEXn_MIP_BIAS (0x13, 0x1B, 0x23, 0x2B)

Mipmap LOD (Level of Detail) bias for artistic control.

```
[63:8]    Reserved (write as 0)
[7:0]     MIP_BIAS: Signed 8-bit fixed-point bias (-4.0 to +3.99)
          Format: 2's complement, 2 fractional bits
          Range: -128 to +127 → -4.00 to +3.96875
          Examples:
            0x00 = 0.0 (no bias)
            0x04 = 1.0 (sharper, select higher-res mip)
            0xFC = -1.0 (blurrier, select lower-res mip)
```

**LOD Calculation**:
```
raw_lod = log₂(max(|du/dx|, |dv/dx|, |du/dy|, |dv/dy|))
biased_lod = raw_lod + (MIP_BIAS / 4.0)
final_lod = clamp(biased_lod, 0, MIP_LEVELS - 1)
mip_level = round(final_lod)  // Nearest-mip mode
```

**Use Cases**:
- Positive bias: Sharper textures (reduce blurriness at distance)
- Negative bias: Softer textures (reduce aliasing, shimmer)
- Typical range: -0.5 to +0.5

**Reset Value**: 0x0000000000000000 (no bias)

**Version**: Added in v4.0 (Mipmap Support)

**Note**: Previously Reserved in v3.0 (TEXn_LUT_BASE in v2.0).

---

### TEXn_WRAP (0x14, 0x1C, 0x24, 0x2C)

UV coordinate wrapping mode.

```
[63:4]    Reserved (write as 0)
[3:2]     V_WRAP mode:
          00 = REPEAT (wrap around)
          01 = CLAMP_TO_EDGE (clamp to [0, height-1])
          10 = CLAMP_TO_ZERO (out of bounds = transparent)
          11 = MIRROR (reflect at boundaries)
[1:0]     U_WRAP mode: (same encoding as V_WRAP)
```

**Wrapping Behavior**:
- **REPEAT**: UV mod texture_size (U=1.5 becomes U=0.5)
- **CLAMP_TO_EDGE**: Clamp to [0, size-1], prevents edge artifacts
- **CLAMP_TO_ZERO**: Out of bounds samples return RGBA=(0,0,0,0)
- **MIRROR**: Reflect at boundaries (0→1→0→1...), reduces tiling

**Reset Value**: 0x0000000000000000 (repeat on both axes)

---

## Rendering Configuration Registers (0x30-0x3F)

### 0x30: RENDER_MODE (Unified Rendering State)

Consolidated rendering state register. Combines TRI_MODE, ALPHA_BLEND, Z-buffer modes, and dithering.

```
[63:16]   Reserved (write as 0)
[15:13]   Z_COMPARE: Depth test comparison function (3 bits) - v8.0: moved from FB_ZBUFFER
          000 = LESS (<)
          001 = LEQUAL (≤)
          010 = EQUAL (=)
          011 = GEQUAL (≥)
          100 = GREATER (>)
          101 = NOTEQUAL (≠)
          110 = ALWAYS (always pass, no Z-test)
          111 = NEVER (always fail)
[12:11]   DITHER_PATTERN: Ordered dither pattern (2 bits) - v8.0: moved from DITHER_MODE
          00 = Blue noise 16×16 (default)
          01-11 = Reserved
[10]      DITHER_EN: Dithering enable (1=enabled, 0=disabled) - v8.0: moved from DITHER_MODE
[9:7]     ALPHA_BLEND: Framebuffer alpha blending mode (3 bits) - v8.0: moved from ALPHA_BLEND register
          000 = DISABLED (overwrite destination)
          001 = ADD (result = src + dst, saturate)
          010 = SUBTRACT (result = src - dst, saturate)
          011 = ALPHA_BLEND (result = src × α + dst × (1-α))
          100-111 = Reserved
[6:5]     CULL_MODE: Backface culling mode (2 bits)
          00 = CULL_NONE (draw all triangles, default)
          01 = CULL_CW (cull clockwise-wound triangles)
          10 = CULL_CCW (cull counter-clockwise triangles)
          11 = Reserved (treat as CULL_NONE)
[4]       Reserved
[3]       Z_WRITE_EN: Write to Z-buffer on depth test pass
[2]       Z_TEST_EN: Enable depth testing
[1]       Reserved
[0]       GOURAUD: Enable Gouraud shading (vs flat shading)
```

**Update Frequency by Field** (v8.0 guidance):
- **Per-material**: GOURAUD, ALPHA_BLEND, CULL_MODE (changes when switching materials/objects)
- **Per-render-pass**: Z_TEST_EN, Z_WRITE_EN, Z_COMPARE (e.g., opaque pass vs transparent pass)
- **Per-scene/frame**: DITHER_EN, DITHER_PATTERN (rarely changes)

**Common Mode Combinations**:

| Use Case | GOURAUD | Z_TEST_EN | Z_WRITE_EN | Z_COMPARE | ALPHA_BLEND | CULL_MODE |
|----------|---------|-----------|------------|-----------|-------------|-----------|
| Opaque 3D object | 1 | 1 | 1 | LEQUAL | DISABLED | CULL_CW |
| Transparent object | 1 | 1 | 0 | LEQUAL | ALPHA_BLEND | CULL_NONE |
| Skybox | 1 | 0 | 0 | ALWAYS | DISABLED | CULL_NONE |
| Particle additive | 1 | 1 | 0 | LEQUAL | ADD | CULL_NONE |
| UI/HUD 2D | 0 | 0 | 0 | ALWAYS | ALPHA_BLEND | CULL_NONE |
| Z-prepass | 0 | 1 | 1 | LEQUAL | DISABLED | CULL_CW |

**Notes**:
- Z_COMPARE moved from FB_ZBUFFER[34:32] for better grouping with Z_TEST_EN/Z_WRITE_EN
- ALPHA_BLEND expanded from 2 bits to 3 bits for future blend modes (e.g., multiply, screen, etc.)
- Dithering typically enabled for all 3D rendering, disabled for UI
- Z_WRITE_EN should be 0 for transparent objects (still test depth, don't write it)
- CULL_MODE: Computed in Triangle Setup (UNIT-004) using signed area
  ```
  signed_area = (v1.x - v0.x) * (v2.y - v0.y) - (v2.x - v0.x) * (v1.y - v0.y)
  if signed_area > 0: triangle is CW
  if signed_area < 0: triangle is CCW
  if signed_area == 0: degenerate (always culled)
  ```

**Reset Value**: 0x0000000000000401 (GOURAUD=1, DITHER_EN=1, DITHER_PATTERN=0, Z_COMPARE=LEQUAL, all else 0)

---

### 0x31: ALPHA_BLEND (REMOVED in v8.0)

**v7.0**: Separate ALPHA_BLEND register at address 0x31

**v8.0 CHANGE**: Alpha blend mode packed into RENDER_MODE[9:7]. This register no longer exists.

See RENDER_MODE register (0x30) for current alpha blend mode control.

---

### 0x32: DITHER_MODE (REMOVED in v8.0)

**v7.0**: Separate DITHER_MODE register at address 0x32

**v8.0 CHANGE**: Dithering control packed into RENDER_MODE[12:10]. This register no longer exists.

See RENDER_MODE register (0x30) for current dithering control.

---

## Framebuffer & Z-Buffer Registers (0x40-0x4F)

### 0x40: FB_DRAW

Address where triangles are rendered. Must be 4K aligned.

```
[63:32]   Reserved (write as 0)
[31:12]   Base address bits [31:12]
[11:0]    Ignored (assumed 0)
```

**Notes**:
- Default after reset: 0x000000
- Changing FB_DRAW mid-frame allows render-to-texture

**Reset Value**: 0x0000000000000000

---

### 0x41: FB_DISPLAY

Address scanned out to display. Must be 4K aligned.

```
[63:32]   Reserved (write as 0)
[31:12]   Base address bits [31:12]
[11:0]    Ignored (assumed 0)
```

**Notes**:
- Change takes effect at next VSYNC (no tearing)
- Default after reset: 0x000000

**Reset Value**: 0x0000000000000000

---

### 0x42: FB_ZBUFFER (Simplified)

Z-buffer base address. Compare function moved to RENDER_MODE.

```
[63:32]   Reserved (write as 0)
[31:12]   Z-buffer base address bits [31:12] (4K aligned)
[11:0]    Ignored (assumed 0)
```

**Z-Buffer Memory Format**: 32-bit words with 16-bit depth:
```
[31:16] = unused (should be 0)
[15:0]  = depth value (0 = near, 0xFFFF = far)
```

**Notes**:
- Z_COMPARE function now in RENDER_MODE[15:13] (v8.0 change)
- Z_WRITE_EN and Z_TEST_EN now in RENDER_MODE[3:2] (v8.0 change)
- This register now only holds the buffer address
- Must be 4K aligned (same as framebuffer)

**Reset Value**: 0x0000000000000000 (address 0x000000)

---

### 0x43: FB_CONTROL (New in v8.0)

Framebuffer control: scissor rectangle and write enable masks.

```
[63:43]   Reserved (write as 0)
[42]      STENCIL_WRITE_EN: Enable stencil buffer writes (future use)
[41]      COLOR_WRITE_EN: Enable color buffer writes (0=Z-only pass)
[40]      Z_WRITE_EN_OVERRIDE: Override RENDER_MODE.Z_WRITE_EN (reserved)
[39:30]   SCISSOR_HEIGHT: Scissor rectangle height (10 bits, 1-1024)
[29:20]   SCISSOR_WIDTH: Scissor rectangle width (10 bits, 1-1024)
[19:10]   SCISSOR_Y: Scissor rectangle top-left Y (10 bits, 0-1023)
[9:0]     SCISSOR_X: Scissor rectangle top-left X (10 bits, 0-1023)
```

**Scissor Rectangle Behavior**:
- Pixels outside the scissor rect are discarded before Z-test and color writes
- Rectangle defined as: [SCISSOR_X, SCISSOR_X + SCISSOR_WIDTH) × [SCISSOR_Y, SCISSOR_Y + SCISSOR_HEIGHT)
- Default (disabled): SCISSOR_X=0, SCISSOR_Y=0, SCISSOR_WIDTH=1024, SCISSOR_HEIGHT=1024 (full screen)
- Typical use: UI rendering (set scissor per UI element to prevent overdraw)

**Write Enable Flags**:
- **COLOR_WRITE_EN** (bit 41): When 0, disables all color writes to framebuffer
  - Use for Z-only prepass (render depth but not color)
  - Z-test still occurs if RENDER_MODE.Z_TEST_EN=1

- **Z_WRITE_EN_OVERRIDE** (bit 40): **Future use, currently reserved**
  - Intended for per-pixel Z-write control
  - If implemented: 1 = use RENDER_MODE.Z_WRITE_EN, 0 = force Z-write off

- **STENCIL_WRITE_EN** (bit 42): Reserved for future stencil buffer support

**Common Use Cases**:

| Use Case | COLOR_WRITE_EN | Z_WRITE_EN_OVERRIDE | SCISSOR |
|----------|----------------|---------------------|---------|
| Normal rendering | 1 | 0 (use RENDER_MODE) | Full screen or UI bounds |
| Z-only prepass | 0 | 0 (use RENDER_MODE) | Full screen |
| UI element | 1 | 0 | UI element bounding box |
| HUD overlay | 1 | 0 | HUD region |

**Reset Value**: 0x00000000_3FF003FF (full screen scissor 1024×1024 at 0,0, all writes enabled)

---

### 0x44: COLOR_GRADE_CTRL

Color grading LUT control. See REQ-133.

```
[63:3]    Reserved (write as 0)
[2]       RESET_ADDR: Write 1 to reset LUT address pointer (self-clearing)
[1]       SWAP_BANKS: Write 1 to swap LUT banks at next vblank (self-clearing)
[0]       ENABLE: 1=color grading enabled, 0=disabled (default)
```

**Notes**:
- Color grading LUT is applied at display scanout between framebuffer read and DVI encoder
- SWAP_BANKS takes effect at the next vertical blanking interval (no tearing)
- Firmware writes go to the inactive bank; SWAP_BANKS activates the new data

**Reset Value**: 0x0000000000000000 (disabled)

**Version**: Added in v5.0

---

### 0x45: COLOR_GRADE_LUT_ADDR

Selects which LUT and entry to write via COLOR_GRADE_LUT_DATA.

```
[63:8]    Reserved (write as 0)
[7:6]     LUT_SELECT: LUT to address
          00 = Red LUT (32 entries, index 0-31)
          01 = Green LUT (64 entries, index 0-63)
          10 = Blue LUT (32 entries, index 0-31)
          11 = Reserved
[5:0]     ENTRY_INDEX: Entry within selected LUT
          For R/B LUTs: bits [4:0] used (0-31), bit [5] ignored
          For G LUT: bits [5:0] used (0-63)
```

**Reset Value**: 0x0000000000000000

**Version**: Added in v5.0

---

### 0x46: COLOR_GRADE_LUT_DATA

Write LUT entry data. Entry is written to the address selected by COLOR_GRADE_LUT_ADDR. Writes go to the inactive bank.

```
[63:24]   Reserved (write as 0)
[23:16]   R output (8 bits)
[15:8]    G output (8 bits)
[7:0]     B output (8 bits)
```

**Entry Format**: RGB888 (24 bits per entry). Each LUT entry specifies the RGB contribution of that input channel to the final output. Full 8-bit output precision matches the DVI TMDS RGB888 scanout format.

**Lookup Process** (per scanout pixel):
```
lut_r_out = red_lut[pixel_R5]     // RGB888
lut_g_out = green_lut[pixel_G6]   // RGB888
lut_b_out = blue_lut[pixel_B5]    // RGB888

final_R8 = saturate(lut_r_out.R + lut_g_out.R + lut_b_out.R, 255)
final_G8 = saturate(lut_r_out.G + lut_g_out.G + lut_b_out.G, 255)
final_B8 = saturate(lut_r_out.B + lut_g_out.B + lut_b_out.B, 255)
```

**Upload Protocol**:
1. Write COLOR_GRADE_CTRL[2] (RESET_ADDR) to reset pointer
2. For each LUT entry: write COLOR_GRADE_LUT_ADDR, then COLOR_GRADE_LUT_DATA
3. Write COLOR_GRADE_CTRL[1] (SWAP_BANKS) to activate at next vblank

**Reset Value**: 0x0000000000000000

**Version**: Added in v5.0

---

## Performance Counter Registers (0x50-0x5F)

**Version**: v6.0 (added), v8.0 (packed format)

Performance counters packed as **pairs of 32-bit unsigned saturating counters** per register. All are **clear-on-read** (reading returns value AND resets both counters to 0).

```
[63:32]   Counter B (32-bit unsigned, saturates at 0xFFFFFFFF)
[31:0]    Counter A (32-bit unsigned, saturates at 0xFFFFFFFF)
```

**Clear-on-Read Protocol** (v8.0 packed format):
```c
uint64_t value = gpu_read(REG_PERF_TEX0);
uint32_t hits = value & 0xFFFFFFFF;
uint32_t misses = (value >> 32) & 0xFFFFFFFF;
// Both counters now reset to 0, start counting again
```

**Saturation Behavior** (v8.0 change):
- Counters saturate at 0xFFFFFFFF (4,294,967,295) and stop incrementing
- Reading a saturated counter clears it back to 0
- 32-bit range sufficient for typical per-frame sampling (at 60 FPS, would take ~2.27 years of continuous max hits to saturate)

**Use Cases**:
- **Performance Profiling**: Sample counters every frame to measure triangle throughput, fill rate, cache efficiency
- **Bottleneck Detection**: Compare stall counters to identify pipeline bottlenecks
- **Cache Tuning**: Measure texture cache hit rates to validate cache architecture
- **Debugging**: Track pixels written, triangles submitted for correctness verification

---

### 0x50-0x53: PERF_TEXn (Packed Hit/Miss Counters)

Texture cache hit/miss counters for each of the 4 texture samplers, **packed 2×32-bit per register**.

**Register Layout**:

| Addr | Name | Counter A [31:0] | Counter B [63:32] |
|------|------|------------------|-------------------|
| 0x50 | PERF_TEX0 | TEX0 cache hits | TEX0 cache misses |
| 0x51 | PERF_TEX1 | TEX1 cache hits | TEX1 cache misses |
| 0x52 | PERF_TEX2 | TEX2 cache hits | TEX2 cache misses |
| 0x53 | PERF_TEX3 | TEX3 cache hits | TEX3 cache misses |

**Increment Conditions**:
- **Hits [31:0]**: Increments when pixel pipeline requests texel from sampler N and the 4×4 block is already cached
- **Misses [63:32]**: Increments when pixel pipeline requests texel and the block is NOT cached (triggers cache fill)

**Cache Hit Rate Calculation**:
```rust
let value = gpu_read(REG_PERF_TEX0);
let hits = (value & 0xFFFFFFFF) as u32;
let misses = (value >> 32) as u32;
let total = hits + misses;
let hit_rate = if total > 0 { (hits as f32 / total as f32) * 100.0 } else { 0.0 };
println!("Texture 0 cache hit rate: {:.1}%", hit_rate);
```

**Expected Performance** (per REQ-131):
- Typical scenes: >85% hit rate due to spatial locality
- Cache miss causes stall (tracked by PERF_STALL_CT register)

**Reset Value**: 0 (clears on read)

---

### 0x54: PERF_PIXELS (Packed Pixels/Fragments Passed)

Pixels written to framebuffer and fragments that passed Z-test, **packed 2×32-bit**.

```
[63:32]   Fragments passed Z-test (32-bit unsigned)
[31:0]    Pixels written to framebuffer (32-bit unsigned)
```

**Increment Conditions**:
- **Pixels written [31:0]**: Increments when pixel pipeline writes a pixel to the framebuffer at FB_DRAW address (after passing Z-test if enabled).
- **Fragments passed [63:32]**: Increments when fragment passes depth test (or Z-test is disabled). Equivalent to pixels written.

**Use Cases**:
- **Fill Rate Measurement**: `fill_rate = pixels_written / frame_time_seconds`
- **Overdraw Detection**: If pixels_written > screen_resolution, scene has overdraw
- **Culling Efficiency**: Compare to theoretical max (640×480 = 307,200 pixels)

**Reset Value**: 0 (clears on read)

---

### 0x55: PERF_FRAGMENTS (Packed Fragments Failed + Reserved)

Fragments that failed Z-test (early-Z rejection), **packed with reserved counter**.

```
[63:32]   Reserved (reads as 0)
[31:0]    Fragments failed Z-test (32-bit unsigned)
```

**Increment Condition**: Increments when fragment fails depth test and is discarded (Z_TEST=1 and depth comparison fails).

**Use Cases**:
- **Z-Cull Efficiency**: `cull_rate = FAILED / (PASSED + FAILED)`
- **Render Order Optimization**: Front-to-back rendering increases FAILED count (good for performance)

**Reset Value**: 0 (clears on read)

---

### 0x56: PERF_STALL_VS (Packed Vertex/SRAM Stalls)

Cycles stalled waiting for vertex data or SRAM arbiter, **packed 2×32-bit**.

```
[63:32]   SRAM stall cycles (32-bit unsigned)
[31:0]    Vertex stall cycles (32-bit unsigned)
```

**Increment Conditions**:
- **Vertex stalls [31:0]**: Increments once per clk_50 cycle when rasterizer (UNIT-005) is idle waiting for tri_valid signal from register file.
- **SRAM stalls [63:32]**: Increments once per clk_50 cycle when any rendering unit has a pending SRAM request not granted by arbiter (UNIT-007).

**Use Cases**:
- **Bottleneck Detection**: High vertex stalls indicate host not submitting triangles fast enough
- **Memory Bandwidth Analysis**: High SRAM stalls indicate memory contention
- **SPI Bandwidth**: Correlate vertex stalls with triangle submission rate

**Reset Value**: 0 (clears on read)

---

### 0x57: PERF_STALL_CT (Packed Cache Stalls/Triangles)

Cycles stalled waiting for cache fill and triangles submitted, **packed 2×32-bit**.

```
[63:32]   Triangles submitted (32-bit unsigned)
[31:0]    Cache stall cycles (32-bit unsigned)
```

**Increment Conditions**:
- **Cache stalls [31:0]**: Increments once per clk_50 cycle when pixel pipeline is stalled waiting for texture cache miss to complete (SRAM fetch + decompress + bank write).
- **Triangles [63:32]**: Increments once per tri_valid pulse from UNIT-003 when a triangle is submitted for rasterization (any VERTEX_KICK register write).

**Cache Fill Latency** (per INT-032):
- BC1 format: ~8 cycles
- RGBA4444 format: ~18 cycles

**Use Cases**:
- **Cache Miss Impact**: Correlate cache stalls with PERF_TEXn misses to understand miss penalty
- **Texture Format Selection**: Compare BC1 vs RGBA4444 stall cycles
- **Triangle Throughput**: `tri_rate = triangles / frame_time_seconds`
- **Mesh Complexity**: Track triangles per frame for different scenes

**Note**: Triangle count includes culled triangles (backface, degenerate).

**Reset Value**: 0 (clears on read)

---

### 0x58-0x6F: Reserved

Reserved for future performance counters. **v8.0: 24 registers freed** from old unpacked performance counter layout.

**Potential Future Counters**:
- PERF_VERTICES_SUBMITTED (vertex write count)
- PERF_TRIANGLES_CULLED (backface + degenerate count)
- PERF_CACHE_EVICTIONS (cache line replacements)
- PERF_DMA_TRANSFERS (SPI→SRAM bulk uploads)

---

## Status & Control Registers (0x70-0x7F)

### 0x70: MEM_ADDR

Memory address pointer for bulk data transfer.

```
[63:32]   Reserved (write as 0)
[31:0]    SRAM address pointer
```

**Usage**: Set this register before reading/writing MEM_DATA. The address is used for bulk uploads of textures, lookup tables, or other GPU memory.

**Reset Value**: 0x0000000000000000

---

### 0x71: MEM_DATA

Memory data register with auto-increment.

```
[63:32]   Reserved (write as 0)
[31:0]    32-bit data value
```

**Write Behavior**:
- Writes 32-bit value to SRAM at MEM_ADDR
- Auto-increments MEM_ADDR by 4
- Allows host to upload textures via SPI

**Read Behavior**:
- Reads 32-bit value from SRAM at MEM_ADDR
- Auto-increments MEM_ADDR by 4
- Allows host to verify memory contents

**Example**: Upload 1KB texture:
```c
gpu_write(REG_MEM_ADDR, 0x384000);
for (int i = 0; i < 256; i++) {
    gpu_write(REG_MEM_DATA, texture_data[i]);  // Auto-increments
}
```

**Reset Value**: N/A (depends on memory contents)

---

### 0x7E: STATUS

GPU status (read-only).

```
[63:16]   Reserved (reads as 0)
[15:10]   Reserved
[9]       VBLANK: Currently in vertical blanking period
[8]       BUSY: GPU is processing commands
[7:0]     FIFO_DEPTH: Number of commands in queue
```

**FIFO_DEPTH**:
- 0 = FIFO empty, safe to read other registers
- ≥(MAX-2) = Near full, CMD_FULL GPIO asserted

**Reset Value**: 0x0000000000000000

---

### 0x7F: ID

GPU identification (read-only).

```
[63:32]   Reserved (reads as 0)
[31:16]   VERSION: Major.Minor (8.8 unsigned)
[15:0]    DEVICE_ID: 0x6702 ("gp" + version 2)
```

**Example**: Version 2.0 → reads as 0x00000200_00006702

**Reset Value**: 0x0000020000006702 (version 2.0)

---

## Migration Guide (v1.0 → v2.0)

### Address Changes

**BREAKING CHANGES** - All software must be updated:

| v1.0 Address | v1.0 Name | v2.0 Address | v2.0 Name | Notes |
|--------------|-----------|--------------|-----------|-------|
| 0x01 | UV | 0x01 | UV0 | Renamed, same format |
| 0x02 | VERTEX | 0x05 | VERTEX | Moved to 0x05 |
| 0x04 | TRI_MODE | 0x30 | TRI_MODE | Moved, bit 1 repurposed |
| 0x05 | TEX_BASE | 0x10 | TEX0_BASE | Moved, now unit 0 |
| 0x06 | TEX_FMT | 0x11 | TEX0_FMT | Moved, format enhanced |
| 0x08 | FB_DRAW | 0x40 | FB_DRAW | Moved to 0x40 |
| 0x09 | FB_DISPLAY | 0x41 | FB_DISPLAY | Moved to 0x41 |
| 0x0A | CLEAR_COLOR | - | - | **REMOVED** |
| 0x0B | CLEAR | - | - | **REMOVED** |
| 0x0C | CLEAR_Z | - | - | **REMOVED** |
| 0x10 | STATUS | 0x7E | STATUS | Moved to 0x7E |
| 0x7F | ID | 0x7F | ID | Same address, reads 0x6702 |

### Removed Registers

**CLEAR_COLOR, CLEAR, CLEAR_Z** have been removed. Use triangle rendering for clearing:

**Clear Framebuffer** (replacement for CLEAR):
```c
gpu_write(REG_TRI_MODE, 0x00);  // Flat shading, no texture, no Z
gpu_write(REG_COLOR, clear_color);

// Draw two triangles covering full viewport (640×480)
gpu_write(REG_VERTEX, PACK_XYZ(0, 0, 0));
gpu_write(REG_VERTEX, PACK_XYZ(639, 0, 0));
gpu_write(REG_VERTEX, PACK_XYZ(639, 479, 0));

gpu_write(REG_VERTEX, PACK_XYZ(0, 0, 0));
gpu_write(REG_VERTEX, PACK_XYZ(639, 479, 0));
gpu_write(REG_VERTEX, PACK_XYZ(0, 479, 0));
```

**Clear Z-Buffer** (replacement for CLEAR_Z):
```c
// Configure Z-buffer with ALWAYS compare, Z-write enabled
gpu_write(REG_FB_ZBUFFER, (0x006 << 32) | 0x258000);  // ALWAYS, Z-buffer at 0x258000
gpu_write(REG_TRI_MODE, (1 << 3) | (1 << 2));  // Z_WRITE + Z_TEST

// Draw full-screen triangles with far plane depth
uint32_t far_z = 0x1FFFFFF;
gpu_write(REG_VERTEX, PACK_XYZ(0, 0, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(639, 0, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(639, 479, far_z));

gpu_write(REG_VERTEX, PACK_XYZ(0, 0, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(639, 479, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(0, 479, far_z));

// Restore LEQUAL compare
gpu_write(REG_FB_ZBUFFER, (0x001 << 32) | 0x258000);  // LEQUAL
```

### New Features in v2.0

**Multi-Texturing**: Up to 4 texture units (TEX0-TEX3)
- Each has: BASE, FMT, BLEND, WRAP registers
- Each vertex gets 4 UV coordinates (UV0-UV3)
- Textures blend sequentially (0→1→2→3)

**Texture Enhancements**:
- Swizzle patterns (16 predefined channel orderings)
- UV wrapping modes (REPEAT, CLAMP_TO_EDGE, CLAMP_TO_ZERO, MIRROR)
- Per-texture blend modes (MULTIPLY, ADD, SUBTRACT, INVERSE_SUBTRACT)

**Z-Buffer Improvements**:
- Configurable compare function (8 modes)
- Base address in same register as compare function

**Alpha Blending**:
- Dedicated ALPHA_BLEND register
- 4 modes: DISABLED, ADD, SUBTRACT, ALPHA_BLEND

**Memory Upload**:
- MEM_ADDR/MEM_DATA registers for bulk transfer
- Auto-increment for efficient uploads

---

## Migration Guide (v2.0 → v3.0)

### Format Changes (v3.0)

**BREAKING CHANGE:** RGBA8888 and 8-bit indexed compression formats removed.

**Texture Formats:**
- v2.0: RGBA8 (COMPRESSED=0), 8-bit indexed (COMPRESSED=1)
- v3.0: RGBA4444 (FORMAT=00), BC1 (FORMAT=01)

**Register Encoding Change:**
- TEXn_FMT bit [1] (COMPRESSED) replaced with bits [2:1] (FORMAT)
- TEXn_LUT_BASE registers (0x13, 0x1B, 0x23, 0x2B) removed (now Reserved)

**Migration:**
- RGBA8 → RGBA4444: Quantize 8-bit channels to 4 bits
- Indexed → BC1: Re-encode using BC1 compression
- All assets must be regenerated with updated asset_build_tool
- See INT-014 for new texture memory layout specifications

---

## Migration Guide (v7.0 → v8.0)

### Summary of Breaking Changes

**ALL v7.0 software must be updated** - no backward compatibility.

**Major Changes:**
1. COLOR register format changed (32-bit → 64-bit with diffuse + specular)
2. Texture registers moved and reorganized (TEX1-3 addresses changed, TEXn_BLEND removed)
3. TRI_MODE, ALPHA_BLEND, DITHER_MODE consolidated into RENDER_MODE
4. Performance counters packed (2×32-bit per register, addresses changed)
5. New features: LIGHT_DIR, DOT3, trilinear filtering, scissor rect, FB_CONTROL

### Register Address Changes

**Vertex State**:
- 0x00 COLOR: **FORMAT CHANGED** (now diffuse[63:32] + specular[31:0])
- 0x03 LIGHT_DIR: **NEW** (was reserved)

**Texture Units** (all addresses changed):

| Register | v7.0 Address | v8.0 Address | Notes |
|----------|--------------|--------------|-------|
| TEX0_BASE | 0x10 | 0x10 | Unchanged |
| TEX0_FMT | 0x11 | 0x11 | **Format changed** (added BLEND, FILTER) |
| TEX0_BLEND | 0x12 | **REMOVED** | Packed into TEX0_FMT[26:24] |
| TEX0_MIP_BIAS | 0x13 | **0x12** | Moved |
| TEX0_WRAP | 0x14 | **0x13** | Moved |
| TEX1_BASE | **0x18** | **0x14** | Moved |
| TEX1_FMT | **0x19** | **0x15** | Moved + format changed |
| TEX1_BLEND | **0x1A** | **REMOVED** | Packed into TEX1_FMT[26:24] |
| TEX1_MIP_BIAS | **0x1B** | **0x16** | Moved |
| TEX1_WRAP | **0x1C** | **0x17** | Moved |
| TEX2_BASE | **0x20** | **0x18** | Moved |
| TEX2_FMT | **0x21** | **0x19** | Moved + format changed |
| TEX2_BLEND | **0x22** | **REMOVED** | Packed into TEX2_FMT[26:24] |
| TEX2_MIP_BIAS | **0x23** | **0x1A** | Moved |
| TEX2_WRAP | **0x24** | **0x1B** | Moved |
| TEX3_BASE | **0x28** | **0x1C** | Moved |
| TEX3_FMT | **0x29** | **0x1D** | Moved + format changed |
| TEX3_BLEND | **0x2A** | **REMOVED** | Packed into TEX3_FMT[26:24] |
| TEX3_MIP_BIAS | **0x2B** | **0x1E** | Moved |
| TEX3_WRAP | **0x2C** | **0x1F** | Moved |

**Rendering Config**:
- 0x30 TRI_MODE: **REPLACED** by RENDER_MODE (unified register)
- 0x31 ALPHA_BLEND: **REMOVED** (packed into RENDER_MODE[9:7])
- 0x32 DITHER_MODE: **REMOVED** (packed into RENDER_MODE[12:10])

**Framebuffer**:
- 0x42 FB_ZBUFFER: **FORMAT CHANGED** (Z_COMPARE moved to RENDER_MODE[15:13])
- 0x43 FB_CONTROL: **NEW** (scissor rect + write enables)

**Performance Counters** (all addresses and formats changed):

| v7.0 | v8.0 | Notes |
|------|------|-------|
| 0x50 PERF_TEX0_HITS | **0x50 PERF_TEX0** | **Packed**: hits[31:0] + misses[63:32] |
| 0x51 PERF_TEX0_MISSES | ^^^ | ^^^ |
| 0x52 PERF_TEX1_HITS | **0x51 PERF_TEX1** | **Packed**: hits[31:0] + misses[63:32] |
| 0x53 PERF_TEX1_MISSES | ^^^ | ^^^ |
| 0x54 PERF_TEX2_HITS | **0x52 PERF_TEX2** | **Packed**: hits[31:0] + misses[63:32] |
| 0x55 PERF_TEX2_MISSES | ^^^ | ^^^ |
| 0x56 PERF_TEX3_HITS | **0x53 PERF_TEX3** | **Packed**: hits[31:0] + misses[63:32] |
| 0x57 PERF_TEX3_MISSES | ^^^ | ^^^ |
| 0x58 PERF_PIXELS_WRITTEN | **0x54 PERF_PIXELS** | **Packed**: pixels[31:0] + frag_passed[63:32] |
| 0x59 PERF_FRAGMENTS_PASSED | ^^^ | ^^^ |
| 0x5A PERF_FRAGMENTS_FAILED | **0x55 PERF_FRAGMENTS** | **Packed**: failed[31:0] + reserved[63:32] |
| 0x5B PERF_STALL_VERTEX | **0x56 PERF_STALL_VS** | **Packed**: vertex[31:0] + sram[63:32] |
| 0x5C PERF_STALL_SRAM | ^^^ | ^^^ |
| 0x5D PERF_STALL_CACHE | **0x57 PERF_STALL_CT** | **Packed**: cache[31:0] + triangles[63:32] |
| 0x5E PERF_TRIANGLES | ^^^ | ^^^ |

### Code Migration Examples

**COLOR Register** (v7.0 → v8.0):
```rust
// v7.0: Single 32-bit color
gpu_write(REG_COLOR, diffuse_color.to_u32());

// v8.0: Dual colors packed into 64-bit
let diffuse = RGBA8::new(255, 255, 255, 255);
let specular = RGBA8::new(64, 64, 64, 0);
gpu_write(REG_COLOR, pack_color(diffuse, specular));

fn pack_color(diffuse: RGBA8, specular: RGBA8) -> u64 {
    ((diffuse.to_u32() as u64) << 32) | (specular.to_u32() as u64)
}
```

**Texture Configuration** (v7.0 → v8.0):
```rust
// v7.0: Separate registers
gpu_write(REG_TEX1_BASE, 0x3C4000);           // At 0x18
gpu_write(REG_TEX1_FMT, fmt);                 // At 0x19
gpu_write(REG_TEX1_BLEND, 0x00);              // At 0x1A (MULTIPLY)
gpu_write(REG_TEX1_WRAP, 0x0);                // At 0x1C

// v8.0: Moved addresses, blend packed into FMT
gpu_write(REG_TEX1_BASE, 0x3C4000);           // NOW at 0x14
gpu_write(REG_TEX1_FMT, pack_tex_fmt(         // NOW at 0x15
    8, 8,                       // Width, height (log2)
    TexFormat::BC1,
    FilterMode::Trilinear,      // NEW: filtering control
    BlendMode::Multiply,        // NEW: packed blend mode
    Swizzle::RGBA,
    5,                          // Mipmap levels
    true,                       // Enable
));
gpu_write(REG_TEX1_WRAP, 0x0);                // NOW at 0x17

fn pack_tex_fmt(...) -> u64 {
    let mut fmt = 0u64;
    if enable { fmt |= 1; }
    fmt |= (format as u64) << 2;
    fmt |= (filter as u64) << 6;              // NEW field
    fmt |= (width_log2 as u64) << 8;
    fmt |= (height_log2 as u64) << 12;
    fmt |= (swizzle as u64) << 16;
    fmt |= (mip_levels as u64) << 20;
    fmt |= (blend as u64) << 24;              // NEW field
    fmt
}
```

**Rendering Mode** (v7.0 → v8.0):
```rust
// v7.0: Separate registers
gpu_write(REG_TRI_MODE, 0x0D);                // GOURAUD | Z_TEST | Z_WRITE | CULL_CW
gpu_write(REG_ALPHA_BLEND, 0x03);             // ALPHA_BLEND mode
gpu_write(REG_DITHER_MODE, 0x01);             // Dithering enabled
gpu_write(REG_FB_ZBUFFER, (0x001 << 32) | zbuf_addr); // Z_COMPARE=LEQUAL

// v8.0: Unified RENDER_MODE register
gpu_write(REG_RENDER_MODE, pack_render_mode(
    true,                       // GOURAUD
    true,                       // Z_TEST_EN
    true,                       // Z_WRITE_EN
    ZCompare::LessEqual,        // Z_COMPARE (moved from FB_ZBUFFER)
    CullMode::CullCW,
    AlphaBlend::AlphaBlend,     // Alpha blend mode (moved from ALPHA_BLEND)
    true,                       // DITHER_EN (moved from DITHER_MODE)
    DitherPattern::BlueNoise,   // DITHER_PATTERN
));
gpu_write(REG_FB_ZBUFFER, zbuf_addr);         // Now only holds address

fn pack_render_mode(...) -> u64 {
    let mut mode = 0u64;
    if gouraud { mode |= 1 << 0; }
    if z_test { mode |= 1 << 2; }
    if z_write { mode |= 1 << 3; }
    mode |= (cull_mode as u64) << 5;
    mode |= (alpha_blend as u64) << 7;
    if dither_en { mode |= 1 << 10; }
    mode |= (dither_pattern as u64) << 11;
    mode |= (z_compare as u64) << 13;
    mode
}
```

**Performance Counters** (v7.0 → v8.0):
```rust
// v7.0: Separate 64-bit registers
let hits = gpu_read(REG_PERF_TEX0_HITS);      // At 0x50
let misses = gpu_read(REG_PERF_TEX0_MISSES);  // At 0x51

// v8.0: Packed 2×32-bit counters
let value = gpu_read(REG_PERF_TEX0);          // NOW at 0x50
let hits = (value & 0xFFFFFFFF) as u32;       // Lower 32 bits
let misses = (value >> 32) as u32;            // Upper 32 bits
```

**New Features** (v8.0):

```rust
// LIGHT_DIR register for DOT3 bump mapping
let light_dir = normalize(light_pos - vertex.position);
gpu_write(REG_LIGHT_DIR, pack_light_dir(light_dir.x, light_dir.y, light_dir.z));

fn pack_light_dir(x: f32, y: f32, z: f32) -> u64 {
    let x8 = (x * 128.0).clamp(-128.0, 127.0) as i8 as u8;
    let y8 = (y * 128.0).clamp(-128.0, 127.0) as i8 as u8;
    let z8 = (z * 128.0).clamp(-128.0, 127.0) as i8 as u8;
    ((z8 as u64) << 16) | ((y8 as u64) << 8) | (x8 as u64)
}

// Scissor rectangle and write enables
gpu_write(REG_FB_CONTROL, pack_fb_control(
    100, 100,                   // Scissor X, Y
    200, 150,                   // Scissor width, height
    true,                       // Z-write enabled
    true,                       // Color write enabled
));

fn pack_fb_control(x: u16, y: u16, w: u16, h: u16, z_write: bool, color_write: bool) -> u64 {
    let mut ctrl = 0u64;
    ctrl |= (x as u64) & 0x3FF;
    ctrl |= ((y as u64) & 0x3FF) << 10;
    ctrl |= ((w as u64) & 0x3FF) << 20;
    ctrl |= ((h as u64) & 0x3FF) << 30;
    if z_write { ctrl |= 1 << 40; }
    if color_write { ctrl |= 1 << 41; }
    ctrl
}
```

### Migration Checklist

**GPU Driver Code (INT-020)**:
- [ ] Update all register address constants (TEX1-3, perf counters)
- [ ] Add `pack_color()`, `pack_light_dir()`, `pack_render_mode()`, `pack_tex_fmt()`, `pack_fb_control()` helpers
- [ ] Update `BlendMode` enum (add DOT3)
- [ ] Add `FilterMode` enum (Nearest, Bilinear, Trilinear)
- [ ] Add `ZCompare` enum (8 modes)
- [ ] Update performance counter read functions (unpack 2×32-bit)

**Firmware (host_app)**:
- [ ] Update GPU initialization (write new RENDER_MODE defaults)
- [ ] Update all vertex submission code (pack diffuse+specular, optionally add LIGHT_DIR)
- [ ] Update material switching code (write RENDER_MODE instead of 3 separate registers)
- [ ] Update texture configuration code (new TEXn_FMT packing, new addresses)
- [ ] Update UI rendering code (use FB_CONTROL for scissor rects)
- [ ] Update performance profiling code (unpack 2×32-bit counters)

**Asset Build Tool**:
- [ ] Update texture format presets (add FILTER and BLEND to output)
- [ ] Optionally add normal map generation for DOT3 bump mapping

**RTL (Hardware)**:
- [ ] Update UNIT-003 (Register File) for new register map
- [ ] Update UNIT-006 (Pixel Pipeline) for DOT3, trilinear, scissor, write enables
- [ ] Update UNIT-020 (Texture Sampler) for trilinear filtering
- [ ] Update testbenches for new register addresses and formats

---

## Edge Cases & Behavioral Specifications

### Texture Dimensions

**Power-of-2 Enforcement**: The register encoding (WIDTH_LOG2, HEIGHT_LOG2) inherently enforces power-of-2 dimensions. Valid values are 3-10, giving dimensions from 8 to 1024 pixels.

**Non-Power-of-2 Textures**: Not supported. If needed, pad texture data to the next power-of-2.

### UV Coordinate Wrapping

Behavior is controlled by TEXn_WRAP register:
- **REPEAT** (00): UV mod texture_size (U=1.5 becomes U=0.5)
- **CLAMP_TO_EDGE** (01): Clamp to [0, size-1], prevents edge sampling artifacts
- **CLAMP_TO_ZERO** (10): Out of bounds samples return RGBA=(0,0,0,0)
- **MIRROR** (11): Reflect at boundaries (0→1→0→1...), reduces tiling artifacts

### Texture Blend Operation Order

Textures are evaluated sequentially in ascending order (0→1→2→3):
```
Step 1: Sample TEX0 → color = tex0_rgba
Step 2: Sample TEX1, blend with TEX1_BLEND: color = blend(color, tex1_rgba)
Step 3: Sample TEX2, blend with TEX2_BLEND: color = blend(color, tex2_rgba)
Step 4: Sample TEX3, blend with TEX3_BLEND: color = blend(color, tex3_rgba)
Step 5: Multiply by vertex color if GOURAUD enabled
Step 6: Apply alpha blend with framebuffer if ALPHA_BLEND != DISABLED
```

TEX0_BLEND is ignored since there's no previous texture to blend with.

### Invalid Swizzle Patterns

Swizzle is encoded as a 4-bit index (0x0-0xF). Undefined patterns (0xD-0xF) default to RGBA (0x0).

### Alpha Blending Edge Cases

When alpha is 0 or 1 in ALPHA_BLEND mode, the math still applies correctly:
- **alpha = 0**: result = src × 0 + dst × 1 = dst (fully transparent)
- **alpha = 1**: result = src × 1 + dst × 0 = src (fully opaque)

No special casing required.

### Z-Buffer Memory Overlap

**Undefined Behavior**: Z-buffer must not overlap framebuffer memory. The hardware does not validate address ranges. If overlap occurs:
- Reading Z may return color data (corrupted depth test)
- Writing Z may corrupt color data
- Visual artifacts and incorrect depth sorting will occur

**Recommended Layout** (640×480):
```
0x000000: FB_A (1,228,800 bytes)
0x12C000: FB_B (1,228,800 bytes)
0x258000: Z-buffer (1,228,800 bytes)
0x384000: Textures
```

### BC1 Texture Dimensions

BC1 compressed textures require both width and height to be multiples of 4. Since power-of-2 dimensions (8, 16, 32, ..., 1024) are all multiples of 4, this constraint is automatically satisfied by the WIDTH_LOG2/HEIGHT_LOG2 encoding.

**BC1 Block Address Calculation**:
```
block_x = pixel_x / 4
block_y = pixel_y / 4
block_addr = TEXn_BASE + (block_y * (width / 4) + block_x) * 8
```

See INT-014 for full BC1 decompression algorithm.

### Texture Address Validation

**Invalid Memory Addresses**: The hardware does not validate texture addresses. If TEXn_BASE points to invalid or unmapped memory:
- Behavior is undefined (may return garbage, zeros, or hang)
- Software must ensure all texture addresses are valid
- Textures must fit within SRAM bounds (0x000000-0x1FFFFFF)

---

## Programming Examples

### Example 1: Multi-Texture Rendering (Diffuse + Lightmap)

```c
// Configure texture unit 0: diffuse map (RGBA4444) at 0x384000, 256x256
gpu_write(REG_TEX0_BASE, 0x384000);
gpu_write(REG_TEX0_FMT,
    (0x0 << 16) |  // Swizzle: RGBA
    (8 << 8) |     // HEIGHT_LOG2: 256
    (8 << 4) |     // WIDTH_LOG2: 256
    (0x0 << 1) |   // FORMAT: RGBA4444
    (1 << 0)       // ENABLE: yes
);
gpu_write(REG_TEX0_BLEND, 0x00);  // MULTIPLY (ignored for tex0)
gpu_write(REG_TEX0_WRAP, 0x0);    // REPEAT on both axes

// Configure texture unit 1: lightmap (BC1) at 0x3C4000, 256x256
gpu_write(REG_TEX1_BASE, 0x3C4000);
gpu_write(REG_TEX1_FMT,
    (0x0 << 16) |  // Swizzle: RGBA
    (8 << 8) |     // HEIGHT_LOG2: 256
    (8 << 4) |     // WIDTH_LOG2: 256
    (0x1 << 1) |   // FORMAT: BC1
    (1 << 0)       // ENABLE: yes
);
gpu_write(REG_TEX1_BLEND, 0x00);  // MULTIPLY (modulate with tex0)
gpu_write(REG_TEX1_WRAP, 0x0);    // REPEAT on both axes

// Disable texture units 2 and 3
gpu_write(REG_TEX2_FMT, 0x0);
gpu_write(REG_TEX3_FMT, 0x0);

// Set rendering mode: Gouraud + textured + Z-buffer
gpu_write(REG_TRI_MODE,
    (1 << 3) |  // Z_WRITE
    (1 << 2) |  // Z_TEST
    (1 << 0)    // GOURAUD
);

// Draw triangle with two sets of UV coordinates
gpu_write(REG_COLOR, 0xFFFFFFFF);           // White (no tint)
gpu_write(REG_UV0, PACK_UVQ(0.0, 0.0, q0)); // Diffuse UV
gpu_write(REG_UV1, PACK_UVQ(0.0, 0.0, q0)); // Lightmap UV
gpu_write(REG_VERTEX, PACK_XYZ(x0, y0, z0));

gpu_write(REG_COLOR, 0xFFFFFFFF);
gpu_write(REG_UV0, PACK_UVQ(1.0, 0.0, q1));
gpu_write(REG_UV1, PACK_UVQ(1.0, 0.0, q1));
gpu_write(REG_VERTEX, PACK_XYZ(x1, y1, z1));

gpu_write(REG_COLOR, 0xFFFFFFFF);
gpu_write(REG_UV0, PACK_UVQ(0.5, 1.0, q2));
gpu_write(REG_UV1, PACK_UVQ(0.5, 1.0, q2));
gpu_write(REG_VERTEX, PACK_XYZ(x2, y2, z2));  // Triggers draw
```

---

### Example 2: BC1 Compressed Texture Setup

```c
// Upload BC1-compressed texture to SRAM at 0x404000
// For 128x128 texture: (128/4) x (128/4) = 1024 blocks x 8 bytes = 8192 bytes
gpu_write(REG_MEM_ADDR, 0x404000);
for (int i = 0; i < 8192 / 4; i++) {
    gpu_write(REG_MEM_DATA, bc1_data[i]);  // Auto-increments by 4
}

// Configure texture unit 0 for BC1 compressed format
gpu_write(REG_TEX0_BASE, 0x404000);
gpu_write(REG_TEX0_FMT,
    (0x0 << 16) |  // Swizzle: RGBA
    (7 << 8) |     // HEIGHT_LOG2: 128
    (7 << 4) |     // WIDTH_LOG2: 128
    (0x1 << 1) |   // FORMAT: BC1
    (1 << 0)       // ENABLE: yes
);
gpu_write(REG_TEX0_WRAP, 0x0);  // REPEAT
```

---

### Example 3: Z-Buffer with Compare Functions

```c
// Configure Z-buffer at 0x258000 with LEQUAL compare
gpu_write(REG_FB_ZBUFFER,
    (0x001ULL << 32) |  // Z_COMPARE: LEQUAL (≤)
    0x258000            // Z-buffer base address
);

// Enable Z-test and Z-write in TRI_MODE
gpu_write(REG_TRI_MODE,
    (1 << 3) |  // Z_WRITE
    (1 << 2) |  // Z_TEST
    (1 << 0)    // GOURAUD
);

// Clear Z-buffer to maximum depth
// First, configure to always pass and write far plane
gpu_write(REG_FB_ZBUFFER,
    (0x006ULL << 32) |  // Z_COMPARE: ALWAYS
    0x258000
);

// Draw full-screen triangles with Z=0x1FFFFFF (far)
uint32_t far_z = 0x1FFFFFF;
gpu_write(REG_COLOR, 0x00000000);
gpu_write(REG_VERTEX, PACK_XYZ(0, 0, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(639, 0, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(639, 479, far_z));

gpu_write(REG_VERTEX, PACK_XYZ(0, 0, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(639, 479, far_z));
gpu_write(REG_VERTEX, PACK_XYZ(0, 479, far_z));

// Restore LEQUAL compare
gpu_write(REG_FB_ZBUFFER,
    (0x001ULL << 32) |  // Z_COMPARE: LEQUAL
    0x258000
);
```

---

### Example 4: Alpha Blending for Transparency

```c
// Enable standard alpha blend mode
gpu_write(REG_ALPHA_BLEND, 0x03);  // Mode 11: alpha blend

// Configure rendering (no Z-write for transparent objects)
gpu_write(REG_TRI_MODE,
    (0 << 3) |  // Z_WRITE: no
    (1 << 2) |  // Z_TEST: yes (still test depth)
    (1 << 0)    // GOURAUD: yes
);

// Draw particle with alpha=0.5 (semi-transparent)
gpu_write(REG_COLOR, 0x80FFFFFF);  // RGBA: white, alpha=128
gpu_write(REG_VERTEX, PACK_XYZ(x0, y0, z0));
gpu_write(REG_VERTEX, PACK_XYZ(x1, y1, z1));
gpu_write(REG_VERTEX, PACK_XYZ(x2, y2, z2));

// After rendering transparent objects, disable alpha blend
gpu_write(REG_ALPHA_BLEND, 0x00);  // DISABLED
```

---

### Example 5: Channel Swizzling (Grayscale)

```c
// Use a single-channel grayscale texture (RGBA4444)
// Swizzle 0x7: RRR1 (replicate R to RGB, alpha=1)
gpu_write(REG_TEX0_BASE, 0x384000);
gpu_write(REG_TEX0_FMT,
    (0x7 << 16) |  // Swizzle: RRR1 (grayscale to RGB)
    (8 << 8) |     // HEIGHT_LOG2: 256
    (8 << 4) |     // WIDTH_LOG2: 256
    (0x0 << 1) |   // FORMAT: RGBA4444
    (1 << 0)       // ENABLE: yes
);

// When sampled, if texture R=128:
// Output will be RGBA=(128, 128, 128, 255)
```

---

## Reset State

After hardware reset or power-on (v8.0):

| Register | Reset Value | Description |
|----------|-------------|-------------|
| COLOR | 0x00000000_00000000 | Both diffuse and specular transparent black (v8.0) |
| UV0_UV1 | 0x0000000000000000 | Zero coordinates |
| UV2_UV3 | 0x0000000000000000 | Zero coordinates |
| LIGHT_DIR | 0x0000000000000000 | Zero vector (v8.0 NEW) |
| VERTEX_NOKICK | N/A | Write-only trigger |
| VERTEX_KICK_012 | N/A | Write-only trigger |
| VERTEX_KICK_021 | N/A | Write-only trigger |
| TEX0-TEX3 BASE | 0x0000000000000000 | Address 0x000000 |
| TEX0-TEX3 FMT | 0x0000000000000000 | Disabled, RGBA4444, nearest, multiply, 8×8 (v8.0) |
| TEX0-TEX3 MIP_BIAS | 0x0000000000000000 | No bias |
| TEX0-TEX3 WRAP | 0x0000000000000000 | REPEAT both axes |
| RENDER_MODE | 0x0000000000000401 | GOURAUD=1, DITHER_EN=1, Z_COMPARE=LEQUAL, all else 0 (v8.0) |
| COLOR_GRADE_CTRL | 0x0000000000000000 | Disabled |
| COLOR_GRADE_LUT_ADDR | 0x0000000000000000 | Red LUT, entry 0 |
| COLOR_GRADE_LUT_DATA | N/A | Write-only |
| FB_DRAW | 0x0000000000000000 | Address 0x000000 |
| FB_DISPLAY | 0x0000000000000000 | Address 0x000000 |
| FB_ZBUFFER | 0x0000000000000000 | Address 0x000000 (v8.0: Z_COMPARE moved to RENDER_MODE) |
| FB_CONTROL | 0x00000000_3FF003FF | Full screen scissor 1024×1024, all writes enabled (v8.0 NEW) |
| PERF_TEX0-3 | 0x0000000000000000 | Both hits and misses zero (v8.0 packed) |
| PERF_PIXELS | 0x0000000000000000 | Both counters zero (v8.0 packed) |
| PERF_FRAGMENTS | 0x0000000000000000 | Both counters zero (v8.0 packed) |
| PERF_STALL_VS | 0x0000000000000000 | Both counters zero (v8.0 packed) |
| PERF_STALL_CT | 0x0000000000000000 | Both counters zero (v8.0 packed) |
| MEM_ADDR | 0x0000000000000000 | Address 0x000000 |
| MEM_DATA | N/A | Depends on memory |
| STATUS | 0x0000000000000000 | Idle, FIFO empty |
| ID | 0x0000080000006702 | **Version 8.0**, device 0x6702 (v8.0) |
| vertex_count | 0 | Internal state counter |

---

## GPIO Signals

Active-high outputs from GPU to host.

| Signal | Description |
|--------|-------------|
| CMD_FULL | FIFO depth ≥ (MAX - 2), host should pause writes |
| CMD_EMPTY | FIFO depth = 0, safe to read STATUS register |
| VSYNC | Pulses high for one clk_50 cycle at frame boundary |

**Timing Notes**:
- CMD_FULL has 2-slot slack: host may complete in-flight transaction
- VSYNC aligns with display vertical blanking start
- Poll GPIO or STATUS register; both provide FIFO information

---

## Transaction Timing

**Write Transaction** (72 bits @ 25 MHz SPI):
- Duration: 2.88 µs
- Latency: Command visible to GPU within 100 clk_50 cycles of CS rising

**Read Transaction** (72 bits @ 25 MHz SPI):
- Duration: 2.88 µs
- Data valid on MISO starting from bit 63
- Only read STATUS when CMD_EMPTY to avoid stale data

**Triangle Submission** (typical multi-texture):
- Minimum: 3 VERTEX writes = 8.64 µs
- Typical (1 texture): TRI_MODE + 3×(COLOR + UV0 + VERTEX) = 28.8 µs
- Multi-texture (2 textures): TRI_MODE + 3×(COLOR + UV0 + UV1 + VERTEX) = 37.44 µs
- Max (4 textures): TRI_MODE + 3×(COLOR + UV0-UV3 + VERTEX) = 54.72 µs
- Theoretical max (1 texture): ~35,000 triangles/second
- Theoretical max (4 textures): ~18,000 triangles/second

---

## Version History

**Version 8.0** (February 2026):
- **BREAKING CHANGE**: COLOR register format changed to pack diffuse[63:32] + specular[31:0]
  - Enables separate diffuse (multiply) and specular (add) vertex colors
  - All vertex submission code must pack both colors
- **BREAKING CHANGE**: Texture registers reorganized and condensed
  - TEX1-3 moved: TEX1 from 0x18-0x1F to 0x14-0x17, TEX2 from 0x20-0x27 to 0x18-0x1B, TEX3 from 0x28-0x2F to 0x1C-0x1F
  - TEXn_BLEND registers eliminated (0x12, 0x1A, 0x22, 0x2A) - blend mode packed into TEXn_FMT[26:24]
  - TEXn_MIP_BIAS and TEXn_WRAP addresses changed to accommodate 4-register-per-unit layout
  - Freed addresses 0x20-0x2F (16 registers)
- **BREAKING CHANGE**: TRI_MODE, ALPHA_BLEND, DITHER_MODE consolidated into unified RENDER_MODE register (0x30)
  - GOURAUD, ALPHA_BLEND[3b], CULL_MODE[2b], Z_TEST_EN, Z_WRITE_EN, Z_COMPARE[3b], DITHER_EN, DITHER_PATTERN[2b]
  - Z_COMPARE moved from FB_ZBUFFER[34:32] to RENDER_MODE[15:13]
  - Registers 0x31, 0x32 now reserved
  - Reduces material switch overhead by 40-85%
- **BREAKING CHANGE**: Performance counters packed from 15 registers to 8 registers
  - Each register now holds 2×32-bit saturating counters instead of 1×64-bit counter
  - Natural pairings: hits/misses, passed/failed, stall types
  - Addresses changed: counters now at 0x50-0x57, freed 0x58-0x6F (24 registers)
- Added LIGHT_DIR register (0x03) for DOT3 bump mapping
  - X8Y8Z8 format (signed 8-bit components)
  - Interpolated linearly across triangle (Gouraud-style)
- Added DOT3 texture blend mode to TEXn_FMT[26:24]
  - Dot product of normal map (texture RGB) with interpolated light direction
  - Enables per-pixel bump mapping without vertex normals
- Added trilinear texture filtering to TEXn_FMT[7:6]
  - 00=nearest, 01=bilinear, 10=trilinear (blend between mip levels)
- Added FB_CONTROL register (0x43) for scissor rect and write enables
  - SCISSOR_X/Y/W/H (10-bit each, 1024 max resolution)
  - COLOR_WRITE_EN, Z_WRITE_EN_OVERRIDE, STENCIL_WRITE_EN flags
- FB_ZBUFFER simplified: Z_COMPARE moved to RENDER_MODE, register now only holds address
- **Register count**: 53 → 46 active registers (13% reduction), 75 → 82 reserved (more expansion room)

**Version 6.0** (February 2026):
- **BREAKING CHANGE**: UV registers reorganized for better packing
  - UV0, UV1, UV2, UV3 (0x01-0x04) replaced with UV0_UV1 (0x01), UV2_UV3 (0x02)
  - Q (1/W) moved from UV registers to VERTEX registers ([63:48])
  - Reduces vertex submission from 6 registers to 4 registers (33-50% fewer writes)
- **BREAKING CHANGE**: VERTEX register (0x05) deprecated, aliased to VERTEX_KICK_012 for compatibility
- Added three vertex kick registers for flexible primitive submission:
  - VERTEX_NOKICK (0x06): Accumulate vertex without drawing
  - VERTEX_KICK_012 (0x07): Draw triangle with v[0], v[1], v[2] order
  - VERTEX_KICK_021 (0x08): Draw triangle with v[0], v[2], v[1] order (reversed winding)
  - Enables triangle strips, fans, and complex mesh topologies
- Added backface culling via TRI_MODE[CULL_MODE] field ([7:6]):
  - 00 = CULL_NONE (default), 01 = CULL_CW, 10 = CULL_CCW
  - Culling based on signed area in Triangle Setup (UNIT-004)
- Added 15 performance counter registers (0x50-0x5E) with clear-on-read behavior:
  - 8 texture cache hit/miss counters (4 samplers × 2)
  - Pixel/fragment counters (pixels written, Z-test passed/failed)
  - Pipeline stall counters (vertex, SRAM, cache)
  - Triangle submission counter
- Freed registers 0x03-0x04 for future vertex attributes (normals, tangents, etc.)
- All changes maintain backward compatibility via register aliasing and default modes

**Version 5.0** (February 2026):
- Added DITHER_MODE register (0x32) for ordered dithering control
- Added COLOR_GRADE_CTRL (0x44), COLOR_GRADE_LUT_ADDR (0x45), COLOR_GRADE_LUT_DATA (0x46) for color grading LUT
- All blend operations specified in 10.8 fixed-point format
- Dithering enabled by default (DITHER_MODE reset = 0x01)
- Added UNIT-008 (Display Controller) as consumer for color grading registers

**Version 3.0** (February 2026):
- Replaced RGBA8888 with RGBA4444 texture format
- Replaced 8-bit indexed compression with BC1 block compression
- TEXn_FMT.COMPRESSED bit replaced with 2-bit FORMAT field
- Removed TEXn_LUT_BASE registers (no longer needed)
- Added INT-014 (Texture Memory Layout) reference for format details

**Version 2.0** (January 2026):
- Added 4 independent texture units (TEX0-TEX3)
- Added texture blend modes, swizzle patterns, wrapping modes
- Added compressed texture format with lookup tables
- Added z-buffer configuration with compare functions
- Added alpha blending modes
- Added memory upload interface (MEM_ADDR/MEM_DATA)
- Removed CLEAR_COLOR, CLEAR, CLEAR_Z registers
- Reorganized address space for logical grouping
- Device ID changed to 0x6702

**Version 1.0** (January 2026):
- Initial release
- Single texture unit
- Basic rendering modes
- Device ID 0x6701


## Constraints

See specification details above.

## Texture Cache Interaction (REQ-131)

Writing to **TEXn_BASE** or **TEXn_FMT** registers implicitly invalidates the corresponding sampler's texture cache. All valid bits for the affected sampler are cleared, ensuring the next texture access fetches fresh data from SRAM.

**Performance Counters** (v6.0): Cache hit/miss statistics are now available via performance counter registers (0x50-0x57). Read these counters to measure cache efficiency and validate the >85% hit rate target from REQ-131.

No explicit cache control registers are defined beyond the performance counters. Future versions may add a `CACHE_CTRL` register for explicit flush/invalidate commands.

## Notes

Migrated from speckit contract: specs/001-spi-gpu/contracts/register-map.md
