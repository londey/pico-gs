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
- **Consumer:** UNIT-010 (Color Combiner)

## Serves Requirement Areas

- Area 1: GPU SPI Controller (REQ-001.01, REQ-001.02, REQ-001.05, REQ-013.01)
- Area 2: Rasterizer (REQ-002.01, REQ-002.02, REQ-002.03)
- Area 3: Texture Samplers (REQ-003.01, REQ-003.02, REQ-003.03, REQ-003.04, REQ-003.05, REQ-003.06, REQ-003.08)
- Area 4: Fragment Processor/Color Combiner (REQ-004.01, REQ-004.02)
- Area 5: Blend/Frame Buffer Store (REQ-005.01, REQ-005.02, REQ-005.04, REQ-005.05, REQ-005.06, REQ-005.07, REQ-005.08, REQ-005.09, REQ-005.10)
- Area 6: Screen Scan Out (REQ-006.02, REQ-006.03)
- Area 11: System Constraints (REQ-011.01, REQ-011.02, REQ-011.03)

## Referenced By

- REQ-001.01 (Basic Host Communication) — Area 1: GPU SPI Controller
- REQ-005.01 (Framebuffer Management) — Area 5: Blend/Frame Buffer Store
- REQ-002.01 (Flat Shaded Triangle) — Area 2: Rasterizer
- REQ-002.02 (Gouraud Shaded Triangle) — Area 2: Rasterizer
- REQ-005.02 (Depth Tested Triangle) — Area 5: Blend/Frame Buffer Store
- REQ-003.01 (Textured Triangle) — Area 3: Texture Samplers
- REQ-003.02 (Multi-Texture Rendering) — Area 3: Texture Samplers
- REQ-004.01 (Texture Blend Modes) — Area 4: Fragment Processor/Color Combiner
- REQ-003.03 (Compressed Textures) — Area 3: Texture Samplers
- REQ-003.04 (Swizzle Patterns) — Area 3: Texture Samplers
- REQ-003.05 (UV Wrapping Modes) — Area 3: Texture Samplers
- REQ-005.03 (Alpha Blending) — Area 5: Blend/Frame Buffer Store
- REQ-005.04 (Enhanced Z-Buffer) — Area 5: Blend/Frame Buffer Store
- REQ-001.02 (Memory Upload Interface) — Area 1: GPU SPI Controller
- REQ-005.05 (Triangle-Based Clearing) — Area 5: Blend/Frame Buffer Store
- REQ-001.05 (Vertex Submission Protocol) — Area 1: GPU SPI Controller
- REQ-002.03 (Rasterization Algorithm) — Area 2: Rasterizer
- REQ-003.06 (Texture Sampling) — Area 3: Texture Samplers
- REQ-006.02 (Display Output Timing) — Area 6: Screen Scan Out
- REQ-005.07 (Z-Buffer Operations) — Area 5: Blend/Frame Buffer Store
- REQ-011.01 (Performance Targets) — Area 11: System Constraints
- REQ-011.02 (Resource Constraints) — Area 11: System Constraints
- REQ-011.03 (Reliability Requirements) — Area 11: System Constraints
- REQ-013.01 (GPU Communication Protocol) — Area 1: GPU SPI Controller
- REQ-005.08 (Clear Framebuffer) — Area 5: Blend/Frame Buffer Store
- REQ-005.09 (Double-Buffered Rendering) — Area 5: Blend/Frame Buffer Store
- REQ-003.08 (Texture Cache) — Area 3: Texture Samplers
- REQ-005.10 (Ordered Dithering) — Area 5: Blend/Frame Buffer Store
- REQ-006.03 (Color Grading LUT) — Area 6: Screen Scan Out
- REQ-004.02 (Extended Precision Fragment Processing) — Area 4: Fragment Processor/Color Combiner

Note: REQ-110 (GPU Initialization) and REQ-028 (Alpha Blending, duplicate) and REQ-029 (Memory Upload Interface, duplicate) are retired; their references have been removed.

## Specification

## Overview

The GPU is controlled via a 7-bit address space providing 128 register locations. Each register is 64 bits wide, though many use fewer bits (unused bits are reserved and must be written as zero, read as zero).

**Transaction Format** (72 bits total):
```
[71]      R/W̄ (1 = read, 0 = write)
[70:64]   Register address (7 bits)
[63:0]    Register value (64 bits)
```

**Command Sources:** Register writes arrive at the register file (UNIT-003) from the command FIFO (UNIT-002), which has two sources:
1. **SPI transactions** from the host (primary, steady-state source)
2. **Pre-populated boot commands** baked into the FIFO memory at bitstream generation time (autonomous, power-on only; see DD-019)

The boot sequence uses registers COLOR (0x00), VERTEX_KICK_012 (0x07), RENDER_MODE (0x30), FB_DRAW (0x40), and FB_DISPLAY (0x41) to render a self-test screen.
All register semantics are identical regardless of command source.

**Major Features**:
- **2 independent texture units with separate UV coordinates**
- **Dedicated color combiner module with programmable input selection**
- **DOT3 bump mapping with interpolated light direction**
- **Dual vertex colors: diffuse (VER_COLOR0) + specular (VER_COLOR1)**
- **Trilinear texture filtering for smooth LOD transitions**
- RGBA4444 and BC1 block-compressed texture formats (see INT-014)
- Swizzle patterns for channel reordering
- **Unified RENDER_MODE register (TRI_MODE + ALPHA_BLEND + Z-modes + dithering)**
- **Scissor rectangle for pixel clipping**
- **Framebuffer write enable masks (Z-buffer, color buffer)**
- Memory upload interface
- Color grading LUT at scanout
- Integrated triangle kick mode control
- **Packed performance counters: 2×32-bit per register**
- Backface culling based on winding order
- **Material colors (MAT_COLOR0, MAT_COLOR1) and fog via Z_COLOR**

---

## Address Space Organization

```
0x00-0x0F: Vertex State (COLOR, UV0_UV1, LIGHT_DIR, VERTEX variants)
0x10-0x17: Texture Configuration (2 units × 4 registers each)
0x18-0x1F: Color Combiner (CC_MODE, MAT_COLOR0, MAT_COLOR1, FOG_COLOR, reserved)
0x20-0x2F: Reserved (freed from old texture registers)
0x30-0x3F: Rendering Configuration (RENDER_MODE consolidated)
0x40-0x4F: Framebuffer, Z-Buffer, Scissor, Color Grading
0x50-0x5F: Performance Counters (PACKED: 2×32-bit per register)
0x60-0x6F: Reserved (freed from old performance counters)
0x70-0x7F: Status & Control (MEM_ADDR, MEM_DATA, STATUS, ID)
```

**Key Optimizations**:
- Texture units reduced from 4 to 2, with 4x larger per-unit cache (16K texels)
- Color combiner replaces sequential 4-texture blend with flexible N64/GeForce2-style combining
- UV2_UV3 register eliminated (0x02 freed), texture registers 0x18-0x1F repurposed for color combiner
- Performance counter registers for TEX2/TEX3 freed (0x52-0x53 now reserved)

---

## Register Summary

| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| **Vertex State** ||||
| 0x00 | COLOR | W | Diffuse[63:32] + Specular[31:0] vertex colors |
| 0x01 | UV0_UV1 | W | Texture units 0+1 coordinates (packed) |
| 0x02 | - | - | Reserved |
| 0x03 | LIGHT_DIR | W | Light direction XYZ for DOT3 (X8Y8Z8) |
| 0x04-0x05 | - | - | Reserved (future vertex attributes) |
| 0x06 | VERTEX_NOKICK | W | Vertex position + 1/W, no triangle draw |
| 0x07 | VERTEX_KICK_012 | W | Vertex position + 1/W, draw tri (v[0], v[1], v[2]) |
| 0x08 | VERTEX_KICK_021 | W | Vertex position + 1/W, draw tri (v[0], v[2], v[1]) |
| 0x09-0x0F | - | - | Reserved (future vertex attributes) |
| **Texture Unit 0** ||||
| 0x10 | TEX0_BASE | R/W | Texture 0 base address |
| 0x11 | TEX0_FMT | R/W | Format, dimensions, swizzle, **blend, filter** |
| 0x12 | TEX0_MIP_BIAS | R/W | Mipmap LOD bias |
| 0x13 | TEX0_WRAP | R/W | UV wrapping mode |
| **Texture Unit 1** ||||
| 0x14 | TEX1_BASE | R/W | Texture 1 base address |
| 0x15 | TEX1_FMT | R/W | Format, dimensions, swizzle, blend, filter |
| 0x16 | TEX1_MIP_BIAS | R/W | Mipmap LOD bias |
| 0x17 | TEX1_WRAP | R/W | UV wrapping mode |
| **Color Combiner** ||||
| 0x18 | CC_MODE | R/W | Color combiner mode and input selection |
| 0x19 | MAT_COLOR0 | R/W | Material color 0 (RGBA8888) |
| 0x1A | MAT_COLOR1 | R/W | Material color 1 (RGBA8888) |
| 0x1B | FOG_COLOR | R/W | Fog color (RGBA8888) |
| 0x1C-0x1F | - | - | Reserved |
| 0x20-0x2F | - | - | Reserved |
| **Rendering Config** ||||
| 0x30 | RENDER_MODE | R/W | **Unified rendering state** |
| 0x31 | Z_RANGE | R/W | **Depth range clipping min/max** |
| 0x32 | - | - | Reserved |
| 0x33-0x3F | - | - | Reserved (rendering config) |
| **Framebuffer** ||||
| 0x40 | FB_DRAW | R/W | Draw target framebuffer address |
| 0x41 | FB_DISPLAY | R/W | **Display scanout + LUT control (non-blocking)** |
| 0x42 | FB_ZBUFFER | R/W | Z-buffer address (Z_COMPARE in RENDER_MODE) |
| 0x43 | FB_CONTROL | R/W | **Scissor rect + write enables** |
| 0x44-0x46 | - | - | Reserved |
| 0x47 | FB_DISPLAY_SYNC | R/W | **Display scanout + LUT control (vsync-blocking)** |
| 0x48-0x4F | - | - | Reserved (framebuffer config) |
| **Performance Counters** ||||
| 0x50 | PERF_TEX0 | R | **TEX0 hits[31:0] + misses[63:32]** |
| 0x51 | PERF_TEX1 | R | TEX1 hits + misses |
| 0x52 | - | - | Reserved |
| 0x53 | - | - | Reserved |
| 0x54 | PERF_PIXELS | R | Pixels written[31:0] + fragments passed[63:32] |
| 0x55 | PERF_FRAGMENTS | R | Fragments failed[31:0] + reserved[63:32] |
| 0x56 | PERF_STALL_VS | R | Vertex stalls[31:0] + SDRAM stalls[63:32] |
| 0x57 | PERF_STALL_CT | R | Cache stalls[31:0] + triangles[63:32] |
| 0x58-0x6F | - | - | Reserved |
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

**Blending Pipeline** (Color Combiner):
```
Step 1: Sample TEX0, TEX1 (2 texture units max)
Step 2: Color combiner combines inputs per CC_MODE equation:
        Inputs: VER_COLOR0 (diffuse), VER_COLOR1 (specular), TEX_COLOR0, TEX_COLOR1,
                MAT_COLOR0, MAT_COLOR1, Z_COLOR (fog)
Step 3: Apply alpha blend with framebuffer if ALPHA_BLEND != DISABLED
```

**Notes**:
- VER_COLOR0 (diffuse) and VER_COLOR1 (specular) are the two vertex colors
- The color combiner (CC_MODE register 0x18) controls how these inputs are combined
- In flat shading mode (GOURAUD=0), only vertex 0's colors are used
- Values are 0-255, where 255 = full intensity
- Color is associated with the next VERTEX write

**Reset Value**: 0x00000000_00000000 (both transparent black)

---

### 0x01: UV0_UV1

Latches texture coordinates for texture units 0 and 1. Values are pre-divided by W for perspective correction. **Note**: 1/W (Q) is stored in VERTEX registers.

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

### 0x02: UV2_UV3 (Removed)

Removed. With only 2 texture units, UV0_UV1 (0x01) provides all needed texture coordinates. This address is now reserved.

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
[63:48]   Q = 1/W (1.15 signed fixed-point)
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
  vertex[vertex_count] = {current_COLOR, current_UV0_UV1, X, Y, Z}
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
  vertex_buffer[vertex_count] = {current_COLOR, current_UV0_UV1, X, Y, Z, Q}
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
  vertex_buffer[vertex_count] = {current_COLOR, current_UV0_UV1, X, Y, Z, Q}
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
  vertex_buffer[vertex_count] = {current_COLOR, current_UV0_UV1, X, Y, Z, Q}
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

## Texture Configuration Registers (0x10-0x17)

Each texture unit has 4 registers (0x10-0x13 for unit 0, 0x14-0x17 for unit 1). The register layout is identical for both units. Reduced from 4 texture units to 2.

**Cache Invalidation**: Any write to a texture configuration register invalidates the texture cache for the corresponding texture unit.
Software does not need to issue a separate cache flush command when changing texture parameters or base address.

### TEXn_BASE (0x10, 0x14)

Base address of texture in SDRAM. Must be 4K aligned.

```
[63:32]   Reserved (write as 0)
[31:12]   Base address bits [31:12]
[11:0]    Ignored (assumed 0 for 4K alignment)
```

**Example**:
- Texture at SDRAM address 0x340000
- Write value: 0x00000000_00340000
- Effective address: 0x340000

**Reset Value**: 0x0000000000000000

---

### TEXn_FMT (0x11, 0x15) - Expanded

Texture format, dimensions, swizzle, **blend mode**, **filtering**, and mipmap levels.

```
[63:27]   Reserved (write as 0)
[26:24]   Reserved (was BLEND, now handled by CC_MODE color combiner register)
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
[7:6]     FILTER: Filtering mode (2 bits)
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

**BLEND Mode** (Removed):

TEXn_FMT.BLEND has been removed. Texture blending is now handled by the color combiner (CC_MODE register 0x18). DOT3 bump mapping is configured via CC_MODE input selection.

**FILTER Mode Details**:

- **NEAREST** (00): Sample single texel, no interpolation. Sharp pixelated look, lowest cost.
- **BILINEAR** (01): 2×2 texel interpolation within a mip level. Smooth, moderate cost.
- **TRILINEAR** (10): Bilinear + blend between two mip levels. Smoothest, highest cost. Falls back to BILINEAR if MIP_LEVELS ≤ 1.

**Texture Sampling**: Textures are sampled independently and passed to the color combiner:
```
Step 1: Sample TEX0, filter → TEX_COLOR0
Step 2: Sample TEX1, filter → TEX_COLOR1 (if enabled)
Step 3: Color combiner combines all inputs per CC_MODE equation (see 0x18)
Step 4: Apply alpha blend with framebuffer if ALPHA_BLEND mode enabled
```

**Note**: Sequential texture blending has been replaced by the color combiner. See CC_MODE (0x18) for combining equations.

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

### TEXn_BLEND (Removed)

Previously at addresses 0x12, 0x1A, 0x22, 0x2A.
BLEND mode is now packed into TEXn_FMT[26:24]. This register no longer exists as a separate entity.

These addresses are now used for TEXn_MIP_BIAS.

---

### TEXn_MIP_BIAS (0x12, 0x16)

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

---

### TEXn_WRAP (0x13, 0x17)

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

## Color Combiner Registers (0x18-0x1F)

> **Status: Preliminary.**
> The exact register layout, combiner equation parameters, and input source encoding below are provisional.
> The color combiner will be defined as its own design unit (UNIT-010) with a detailed data flow diagram.
> Addresses 0x18–0x1F are reserved for color combiner registers; final field definitions will be determined by UNIT-010.

The color combiner replaces the sequential 4-texture blending pipeline with a programmable combiner inspired by N64 RDP and GeForce2 register combiners.
It takes up to 7 input sources and produces a final color via a configurable equation.

### 0x18: CC_MODE (Color Combiner Mode)

Selects the combiner equation and input mapping.

```
[63:32]   Reserved (write as 0)
[31:28]   CC_D_SOURCE: Input D source select (4 bits, see source table)
[27:24]   CC_C_SOURCE: Input C source select (4 bits)
[23:20]   CC_B_SOURCE: Input B source select (4 bits)
[19:16]   CC_A_SOURCE: Input A source select (4 bits)
[15:12]   CC_ALPHA_D: Alpha input D source (4 bits)
[11:8]    CC_ALPHA_C: Alpha input C source (4 bits)
[7:4]     CC_ALPHA_B: Alpha input B source (4 bits)
[3:0]     CC_ALPHA_A: Alpha input A source (4 bits)
```

**Combiner Equation** (applied independently to RGB and Alpha):
```
result = (A - B) × C + D
```

**Source Select Encoding** (4 bits):

| Code | Source | Description |
|------|--------|-------------|
| 0x0 | TEX_COLOR0 | Sampled+filtered output from texture unit 0 |
| 0x1 | TEX_COLOR1 | Sampled+filtered output from texture unit 1 |
| 0x2 | VER_COLOR0 | Interpolated vertex color 0 (diffuse) |
| 0x3 | VER_COLOR1 | Interpolated vertex color 1 (specular) |
| 0x4 | MAT_COLOR0 | Material color 0 (from register 0x19) |
| 0x5 | MAT_COLOR1 | Material color 1 (from register 0x1A) |
| 0x6 | Z_COLOR | Derived from high byte of interpolated Z (fog factor) |
| 0x7 | ZERO | Constant zero (0, 0, 0, 0) |
| 0x8 | ONE | Constant one (1, 1, 1, 1) |
| 0x9 | ONE_MINUS_A | 1 - input A (computed, only valid for C source) |
| 0xA-0xF | Reserved | Defaults to ZERO |

**Common Combiner Presets**:

| Use Case | A | B | C | D | Equation |
|----------|---|---|---|---|----------|
| Texture × Diffuse | TEX0 | ZERO | VER0 | ZERO | `TEX0 × VER_COLOR0` |
| Dual-texture modulate | TEX0 | ZERO | TEX1 | ZERO | `TEX0 × TEX1` |
| Diffuse + Specular | TEX0 | ZERO | VER0 | VER1 | `TEX0 × VER_COLOR0 + VER_COLOR1` |
| Fog blend | TEX0 | FOG | Z_COLOR | FOG | `(TEX0 - FOG_COLOR) × Z_COLOR + FOG_COLOR` |
| Lightmap (TEX0 × TEX1 × Diffuse) | TEX0 | ZERO | TEX1 | ZERO | First pass; chain with diffuse in alpha |
| Material color only | MAT0 | ZERO | ONE | ZERO | `MAT_COLOR0` |

**Notes**:
- All operations are performed in 10.8 fixed-point format (REQ-004.02)
- DOT3 bump mapping: configure TEX0 as normal map, use CC_MODE to select DOT3 operation via the LIGHT_DIR register interaction (computed in pixel pipeline before combiner)
- Z_COLOR is computed as `interpolated_Z[15:8]` (high byte), providing 256-level fog granularity
- The combiner equation `(A - B) × C + D` can express multiply, add, subtract, lerp, and fog operations

**Reset Value**: 0x0000000000720020 (A=TEX0, B=ZERO, C=VER0, D=ZERO → `TEX0 × VER_COLOR0`, default textured Gouraud)

---

### 0x19: MAT_COLOR0 (Material Color 0)

Per-material constant color for use in the color combiner.

```
[63:32]   Reserved (write as 0)
[31:24]   Alpha (8 bits)
[23:16]   Blue (8 bits)
[15:8]    Green (8 bits)
[7:0]     Red (8 bits)
```

**Use Cases**:
- Constant diffuse tint (environment color)
- Fog color (when used as D input with Z_COLOR as C)
- Material-specific flat color

**Reset Value**: 0x00000000FFFFFFFF (opaque white)

---

### 0x1A: MAT_COLOR1 (Material Color 1)

Second per-material constant color for use in the color combiner.

```
[63:32]   Reserved (write as 0)
[31:24]   Alpha (8 bits)
[23:16]   Blue (8 bits)
[15:8]    Green (8 bits)
[7:0]     Red (8 bits)
```

**Use Cases**:
- Secondary material color (e.g., highlight color, rim light color)
- Blend target for material transitions

**Reset Value**: 0x0000000000000000 (transparent black)

---

### 0x1B: FOG_COLOR

Fog color for distance-based fogging. Used as a combiner input source (Z_COLOR selects fog intensity from interpolated Z depth).

```
[63:32]   Reserved (write as 0)
[31:24]   Alpha (8 bits)
[23:16]   Blue (8 bits)
[15:8]    Green (8 bits)
[7:0]     Red (8 bits)
```

**Fog Implementation**:
```
Z_COLOR = interpolated_Z[15:8] / 255.0  // 0.0 (near) to 1.0 (far)
fog_result = (fragment_color - FOG_COLOR) × (1 - Z_COLOR) + FOG_COLOR
           = lerp(FOG_COLOR, fragment_color, 1 - Z_COLOR)
```

To achieve fog, configure CC_MODE: A=computed_color, B=FOG_COLOR, C=ONE_MINUS_Z_COLOR, D=FOG_COLOR.

**Notes**:
- Z_COLOR derives from the high byte of interpolated Z (0-255 → 0.0-1.0)
- For non-linear fog curves, a fog LUT could be added in future (using reserved address space)

**Reset Value**: 0x0000000000000000 (transparent black, no fog)

---

### 0x1C-0x1F: Reserved

Reserved for future color combiner expansion (additional combiner stages, fog LUT pointer, etc.).

**Reset Value**: N/A (reserved)

---

## Rendering Configuration Registers (0x30-0x3F)

### 0x30: RENDER_MODE (Unified Rendering State)

Consolidated rendering state register. Combines TRI_MODE, ALPHA_BLEND, Z-buffer modes, and dithering.

```
[63:16]   Reserved (write as 0)
[15:13]   Z_COMPARE: Depth test comparison function (3 bits)
          000 = LESS (<)
          001 = LEQUAL (≤)
          010 = EQUAL (=)
          011 = GEQUAL (≥)
          100 = GREATER (>)
          101 = NOTEQUAL (≠)
          110 = ALWAYS (always pass, no Z-test)
          111 = NEVER (always fail)
[12:11]   DITHER_PATTERN: Ordered dither pattern (2 bits)
          00 = Blue noise 16×16 (default)
          01-11 = Reserved
[10]      DITHER_EN: Dithering enable (1=enabled, 0=disabled)
[9:7]     ALPHA_BLEND: Framebuffer alpha blending mode (3 bits)
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
[4]       COLOR_WRITE_EN: Enable color buffer writes (1=enabled, 0=Z-only pass)
[3]       Z_WRITE_EN: Write to Z-buffer on depth test pass
[2]       Z_TEST_EN: Enable depth testing
[1]       Reserved
[0]       GOURAUD: Enable Gouraud shading (vs flat shading)
```

**Update Frequency by Field**:
- **Per-material**: GOURAUD, ALPHA_BLEND, CULL_MODE (changes when switching materials/objects)
- **Per-render-pass**: Z_TEST_EN, Z_WRITE_EN, Z_COMPARE (e.g., opaque pass vs transparent pass)
- **Per-scene/frame**: DITHER_EN, DITHER_PATTERN (rarely changes)

**Common Mode Combinations**:

| Use Case | GOURAUD | Z_TEST_EN | Z_WRITE_EN | COLOR_WRITE_EN | Z_COMPARE | ALPHA_BLEND | CULL_MODE |
|----------|---------|-----------|------------|----------------|-----------|-------------|-----------|
| Opaque 3D object | 1 | 1 | 1 | 1 | LEQUAL | DISABLED | CULL_CW |
| Transparent object | 1 | 1 | 0 | 1 | LEQUAL | ALPHA_BLEND | CULL_NONE |
| Skybox | 1 | 0 | 0 | 1 | ALWAYS | DISABLED | CULL_NONE |
| Particle additive | 1 | 1 | 0 | 1 | LEQUAL | ADD | CULL_NONE |
| UI/HUD 2D | 0 | 0 | 0 | 1 | ALWAYS | ALPHA_BLEND | CULL_NONE |
| Z-prepass | 0 | 1 | 1 | 0 | LEQUAL | DISABLED | CULL_CW |
| Depth-only shadow | 0 | 1 | 1 | 0 | LEQUAL | DISABLED | CULL_CW |

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

**Reset Value**: 0x0000000000000411 (GOURAUD=1, COLOR_WRITE_EN=1, DITHER_EN=1, DITHER_PATTERN=0, Z_COMPARE=LEQUAL, all else 0)

---

### 0x31: Z_RANGE (Depth Range Clipping)

Depth range clipping register (Z scissor). Fragments whose Z value falls outside [Z_RANGE_MIN, Z_RANGE_MAX] are discarded before any SDRAM access.

```
[63:32]   Reserved (write as 0)
[31:16]   Z_RANGE_MAX: Maximum Z value (16-bit unsigned, inclusive)
[15:0]    Z_RANGE_MIN: Minimum Z value (16-bit unsigned, inclusive)
```

**Depth Range Test**:
```
if fragment_z < Z_RANGE_MIN or fragment_z > Z_RANGE_MAX:
    discard fragment (no SDRAM access, no Z-test, no color write)
```

**Use Cases**:
- **Fog/distance culling**: Set Z_RANGE_MAX to discard fragments beyond a fog distance
- **Near-plane clipping**: Set Z_RANGE_MIN to discard fragments too close to camera
- **Depth slicing**: Render specific depth layers for multi-pass effects
- **Disabled (default)**: Z_RANGE_MIN=0x0000, Z_RANGE_MAX=0xFFFF passes all fragments

**Notes**:
- Test uses inclusive comparison: MIN <= fragment_z <= MAX
- Combined with early Z-test in Stage 0 of pixel pipeline (UNIT-006)
- Z_RANGE applies regardless of RENDER_MODE.Z_TEST_EN setting (independent clip test)
- This address was previously ALPHA_BLEND (moved to RENDER_MODE[9:7])

**Reset Value**: 0x00000000FFFF0000 (Z_RANGE_MAX=0xFFFF, Z_RANGE_MIN=0x0000 -- all fragments pass)

---

### 0x32: DITHER_MODE (Removed)

Separate DITHER_MODE register at address 0x32 has been removed.
Dithering control is now packed into RENDER_MODE[12:10].

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

### 0x41: FB_DISPLAY (Non-Blocking)

Display scanout framebuffer address with optional color grading LUT auto-load. Non-blocking write (returns immediately).

```
[63:48]   Reserved (write as 0)
[47:32]   FB_ADDR: Framebuffer base address >> 9 (512-byte aligned, 16 bits)
          Effective address range: 0x000000 - 0x1FFFE00 (32 MiB SDRAM)
          Same encoding as texture BASE_ADDR
[31:16]   LUT_ADDR: Color grading LUT base address >> 9 (512-byte aligned, 16 bits)
          Effective address range: 0x000000 - 0x1FFFE00
          Special value: 0x0000 = skip LUT auto-load, keep current LUT
[15:1]    Reserved (write as 0)
[0]       COLOR_GRADE_ENABLE: 1=color grading enabled, 0=bypass (RGB565→RGB888 expansion)
```

**Behavior**:
- Write returns immediately (non-blocking)
- Framebuffer switch and LUT auto-load (if enabled) take effect at next vsync
- If `LUT_ADDR != 0`: Hardware auto-loads 384-byte LUT from SDRAM to inactive EBR bank during vblank, then swaps banks atomically with framebuffer switch
- If `LUT_ADDR == 0`: Skip LUT auto-load, only switch framebuffer
- Non-blocking allows firmware to continue work during frame rendering

**SDRAM LUT Format** (384 bytes at LUT_ADDR):
```
Offset  | Data    | Description
--------|---------|----------------------------------
0x000   | RGB888  | Red LUT entry 0 (R_in=0)
0x003   | RGB888  | Red LUT entry 1 (R_in=1)
...     | ...     | ...
0x05D   | RGB888  | Red LUT entry 31 (R_in=31)
0x060   | RGB888  | Green LUT entry 0 (G_in=0)
...     | ...     | ...
0x11D   | RGB888  | Green LUT entry 63 (G_in=63)
0x120   | RGB888  | Blue LUT entry 0 (B_in=0)
...     | ...     | ...
0x17D   | RGB888  | Blue LUT entry 31 (B_in=31)
```

Each RGB888 entry: 3 bytes (R[23:16], G[15:8], B[7:0])

**Notes**:
- Replaces register-based LUT upload
- LUT data must be prepared in SDRAM by firmware before write (see REQ-006.03)
- Address encoding matches texture BASE_ADDR (16-bit, 512-byte granularity, 32 MiB addressable)
- LUT auto-load DMA takes ~2µs during vblank (~1.43ms available)
- For blocking write (waits for vsync), use FB_DISPLAY_SYNC (0x47) instead
- Writing only FB address with LUT_ADDR=0, ENABLE=0 behaves as address-only mode

**Reset Value**: 0x0000000000000000 (FB at 0x000000, no LUT, color grading disabled)

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
- Z_COMPARE function now in RENDER_MODE[15:13]
- Z_WRITE_EN and Z_TEST_EN now in RENDER_MODE[3:2]
- This register now only holds the buffer address
- Must be 4K aligned (same as framebuffer)

**Reset Value**: 0x0000000000000000 (address 0x000000)

---

### 0x43: FB_CONTROL

Framebuffer control: scissor rectangle and write enable masks.

```
[63:43]   Reserved (write as 0)
[42]      STENCIL_WRITE_EN: Enable stencil buffer writes (future use)
[41]      Reserved (COLOR_WRITE_EN moved to RENDER_MODE[4])
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
- **COLOR_WRITE_EN**: Moved to RENDER_MODE[4]. See RENDER_MODE register (0x30) for color write control.
  - Use RENDER_MODE.COLOR_WRITE_EN for Z-only prepass (render depth but not color)
  - Z-test still occurs if RENDER_MODE.Z_TEST_EN=1

- **Z_WRITE_EN_OVERRIDE** (bit 40): **Future use, currently reserved**
  - Intended for per-pixel Z-write control
  - If implemented: 1 = use RENDER_MODE.Z_WRITE_EN, 0 = force Z-write off

- **STENCIL_WRITE_EN** (bit 42): Reserved for future stencil buffer support

**Common Use Cases**:

| Use Case | Z_WRITE_EN_OVERRIDE | SCISSOR |
|----------|---------------------|---------|
| Normal rendering | 0 (use RENDER_MODE) | Full screen or UI bounds |
| Z-only prepass | 0 (use RENDER_MODE) | Full screen |
| UI element | 0 | UI element bounding box |
| HUD overlay | 0 | HUD region |

**Reset Value**: 0x00000000_3FF003FF (full screen scissor 1024×1024 at 0,0, all writes enabled)

---

### 0x47: FB_DISPLAY_SYNC (V-Sync Blocking)

Display scanout framebuffer address with optional color grading LUT auto-load. **Blocking write** (waits for vsync).

```
[63:48]   Reserved (write as 0)
[47:32]   FB_ADDR: Framebuffer base address >> 9 (512-byte aligned, 16 bits)
          Effective address range: 0x000000 - 0x1FFFE00 (32 MiB SDRAM)
          Same encoding as texture BASE_ADDR
[31:16]   LUT_ADDR: Color grading LUT base address >> 9 (512-byte aligned, 16 bits)
          Effective address range: 0x000000 - 0x1FFFE00
          Special value: 0x0000 = skip LUT auto-load, keep current LUT
[15:1]    Reserved (write as 0)
[0]       COLOR_GRADE_ENABLE: 1=color grading enabled, 0=bypass (RGB565→RGB888 expansion)
```

**Behavior**:
- **Write blocks** until next vsync edge (SPI CS remains asserted)
- Framebuffer switch and LUT auto-load (if enabled) happen atomically at vsync
- SPI transaction completes only after vsync trigger and updates applied
- If `LUT_ADDR != 0`: Hardware auto-loads 384-byte LUT from SDRAM to inactive EBR bank during vblank, then swaps banks atomically with framebuffer switch
- If `LUT_ADDR == 0`: Skip LUT auto-load, only switch framebuffer
- Blocking write ties up SPI bus for 0-16.67ms (max one frame period)

**SDRAM LUT Format** (384 bytes at LUT_ADDR):
```
Offset  | Data    | Description
--------|---------|----------------------------------
0x000   | RGB888  | Red LUT entry 0 (R_in=0)
0x003   | RGB888  | Red LUT entry 1 (R_in=1)
...     | ...     | ...
0x05D   | RGB888  | Red LUT entry 31 (R_in=31)
0x060   | RGB888  | Green LUT entry 0 (G_in=0)
...     | ...     | ...
0x11D   | RGB888  | Green LUT entry 63 (G_in=63)
0x120   | RGB888  | Blue LUT entry 0 (B_in=0)
...     | ...     | ...
0x17D   | RGB888  | Blue LUT entry 31 (B_in=31)
```

Each RGB888 entry: 3 bytes (R[23:16], G[15:8], B[7:0])

**Use Cases**:
- Game rendering: Atomic frame flip + color grading update
- PS2/N64-style rendering: Natural sync point between frames
- Simplified firmware: No explicit `gpu_wait_vsync()` needed
- Prevents tearing artifacts

**Implementation**:
- SPI slave keeps CS asserted during vsync wait via `spi_cs_hold` signal
- Register data latched on write, applied at vsync edge
- LUT DMA triggered during vblank if `LUT_ADDR != 0`

**Notes**:
- Same register format as FB_DISPLAY (0x41), only difference is blocking behavior
- LUT data must be prepared in SDRAM by firmware before write (see REQ-006.03)
- Address encoding matches texture BASE_ADDR (16-bit, 512-byte granularity, 32 MiB addressable)
- LUT auto-load DMA takes ~2µs during vblank (~1.43ms available)
- For non-blocking write, use FB_DISPLAY (0x41) instead

**Reset Value**: N/A (write-only blocking register)

---

## Performance Counter Registers (0x50-0x5F)

Performance counters packed as **pairs of 32-bit unsigned saturating counters** per register. All are **clear-on-read** (reading returns value AND resets both counters to 0).

```
[63:32]   Counter B (32-bit unsigned, saturates at 0xFFFFFFFF)
[31:0]    Counter A (32-bit unsigned, saturates at 0xFFFFFFFF)
```

**Clear-on-Read Protocol**:
```c
uint64_t value = gpu_read(REG_PERF_TEX0);
uint32_t hits = value & 0xFFFFFFFF;
uint32_t misses = (value >> 32) & 0xFFFFFFFF;
// Both counters now reset to 0, start counting again
```

**Saturation Behavior**:
- Counters saturate at 0xFFFFFFFF (4,294,967,295) and stop incrementing
- Reading a saturated counter clears it back to 0
- 32-bit range sufficient for typical per-frame sampling (at 60 FPS, would take ~2.27 years of continuous max hits to saturate)

**Use Cases**:
- **Performance Profiling**: Sample counters every frame to measure triangle throughput, fill rate, cache efficiency
- **Bottleneck Detection**: Compare stall counters to identify pipeline bottlenecks
- **Cache Tuning**: Measure texture cache hit rates to validate cache architecture
- **Debugging**: Track pixels written, triangles submitted for correctness verification

---

### 0x50-0x51: PERF_TEXn (Packed Hit/Miss Counters)

Texture cache hit/miss counters for each of the 2 texture samplers, **packed 2×32-bit per register**.

**Register Layout**:

| Addr | Name | Counter A [31:0] | Counter B [63:32] |
|------|------|------------------|-------------------|
| 0x50 | PERF_TEX0 | TEX0 cache hits | TEX0 cache misses |
| 0x51 | PERF_TEX1 | TEX1 cache hits | TEX1 cache misses |
| 0x52 | - | Reserved | Reserved |
| 0x53 | - | Reserved | Reserved |

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

**Expected Performance** (per REQ-003.08):
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

### 0x56: PERF_STALL_VS (Packed Vertex/SDRAM Stalls)

Cycles stalled waiting for vertex data or SDRAM arbiter, **packed 2×32-bit**.

```
[63:32]   SDRAM stall cycles (32-bit unsigned)
[31:0]    Vertex stall cycles (32-bit unsigned)
```

**Increment Conditions**:
- **Vertex stalls [31:0]**: Increments once per clk_core cycle when rasterizer (UNIT-005) is idle waiting for tri_valid signal from register file.
- **SDRAM stalls [63:32]**: Increments once per clk_core cycle when any rendering unit has a pending SDRAM request not granted by arbiter (UNIT-007).

**Use Cases**:
- **Bottleneck Detection**: High vertex stalls indicate host not submitting triangles fast enough
- **Memory Bandwidth Analysis**: High SDRAM stalls indicate memory contention
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
- **Cache stalls [31:0]**: Increments once per clk_core cycle when pixel pipeline is stalled waiting for texture cache miss to complete (SDRAM fetch + decompress + bank write).
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

Reserved for future performance counters.

**Potential Future Counters**:
- PERF_VERTICES_SUBMITTED (vertex write count)
- PERF_TRIANGLES_CULLED (backface + degenerate count)
- PERF_CACHE_EVICTIONS (cache line replacements)
- PERF_DMA_TRANSFERS (SPI→SDRAM bulk uploads)

---

## Status & Control Registers (0x70-0x7F)

### 0x70: MEM_ADDR

Memory address pointer for bulk data transfer.

```
[63:32]   Reserved (write as 0)
[31:0]    SDRAM address pointer
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
- Writes 32-bit value to SDRAM at MEM_ADDR
- Auto-increments MEM_ADDR by 4
- Allows host to upload textures via SPI

**Read Behavior**:
- Reads 32-bit value from SDRAM at MEM_ADDR
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

**Example**: Version 10.0 → reads as 0x00000A00_00006702

**Reset Value**: 0x00000A0000006702

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

### Color Combiner Operation

Textures are sampled independently, then combined via the color combiner:
```
Step 1: Sample TEX0 → TEX_COLOR0
Step 2: Sample TEX1 → TEX_COLOR1 (if enabled)
Step 3: Color combiner: result = (A - B) × C + D (per CC_MODE register)
Step 4: Apply alpha blend with framebuffer if ALPHA_BLEND != DISABLED
```

The combiner inputs (A, B, C, D) are selected from: TEX_COLOR0, TEX_COLOR1, VER_COLOR0, VER_COLOR1, MAT_COLOR0, MAT_COLOR1, Z_COLOR, ZERO, ONE.
See CC_MODE (0x18) for details.

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
- Textures must fit within SDRAM bounds (0x000000-0x1FFFFFF)

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
// Upload BC1-compressed texture to SDRAM at 0x404000
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

After hardware reset or power-on:

| Register | Reset Value | Description |
|----------|-------------|-------------|
| COLOR | 0x00000000_00000000 | Both diffuse and specular transparent black |
| UV0_UV1 | 0x0000000000000000 | Zero coordinates |
| UV2_UV3 | N/A | Removed |
| LIGHT_DIR | 0x0000000000000000 | Zero vector |
| VERTEX_NOKICK | N/A | Write-only trigger |
| VERTEX_KICK_012 | N/A | Write-only trigger |
| VERTEX_KICK_021 | N/A | Write-only trigger |
| TEX0-TEX1 BASE | 0x0000000000000000 | Address 0x000000 |
| TEX0-TEX1 FMT | 0x0000000000000000 | Disabled, RGBA4444, nearest, 8×8 |
| TEX0-TEX1 MIP_BIAS | 0x0000000000000000 | No bias |
| TEX0-TEX1 WRAP | 0x0000000000000000 | REPEAT both axes |
| CC_MODE | 0x0000000000720020 | TEX0 × VER_COLOR0 (default textured Gouraud) |
| MAT_COLOR0 | 0x00000000FFFFFFFF | Opaque white |
| MAT_COLOR1 | 0x0000000000000000 | Transparent black |
| FOG_COLOR | 0x0000000000000000 | Transparent black |
| RENDER_MODE | 0x0000000000000401 | GOURAUD=1, DITHER_EN=1, Z_COMPARE=LEQUAL, all else 0 |
| FB_DRAW | 0x0000000000000000 | Address 0x000000 |
| FB_DISPLAY | 0x0000000000000000 | FB=0x000000, LUT=0x0, color grading disabled |
| FB_ZBUFFER | 0x0000000000000000 | Address 0x000000 (Z_COMPARE in RENDER_MODE) |
| FB_CONTROL | 0x00000000_3FF003FF | Full screen scissor 1024×1024, all writes enabled |
| FB_DISPLAY_SYNC | N/A | Write-only blocking register |
| PERF_TEX0-1 | 0x0000000000000000 | Both hits and misses zero |
| PERF_PIXELS | 0x0000000000000000 | Both counters zero |
| PERF_FRAGMENTS | 0x0000000000000000 | Both counters zero |
| PERF_STALL_VS | 0x0000000000000000 | Both counters zero |
| PERF_STALL_CT | 0x0000000000000000 | Both counters zero |
| MEM_ADDR | 0x0000000000000000 | Address 0x000000 |
| MEM_DATA | N/A | Depends on memory |
| STATUS | 0x0000000000000000 | Idle, FIFO empty |
| ID | 0x00000A0000006702 | Device 0x6702 |
| vertex_count | 0 | Internal state counter |

---

## GPIO Signals

Active-high outputs from GPU to host.

| Signal | Description |
|--------|-------------|
| CMD_FULL | FIFO depth ≥ (MAX - 2), host should pause writes |
| CMD_EMPTY | FIFO depth = 0, safe to read STATUS register |
| VSYNC | Pulses high for one clk_core cycle at frame boundary |

**Timing Notes**:
- CMD_FULL has 2-slot slack: host may complete in-flight transaction
- VSYNC aligns with display vertical blanking start
- Poll GPIO or STATUS register; both provide FIFO information

---

## Transaction Timing

**Write Transaction** (72 bits @ 25 MHz SPI):
- Duration: 2.88 µs
- Latency: Command visible to GPU within 100 clk_core cycles of CS rising

**Read Transaction** (72 bits @ 25 MHz SPI):
- Duration: 2.88 µs
- Data valid on MISO starting from bit 63
- Only read STATUS when CMD_EMPTY to avoid stale data

**Triangle Submission** (typical multi-texture):
- Minimum: 3 VERTEX writes = 8.64 µs
- Typical (1 texture): RENDER_MODE + 3×(COLOR + UV0_UV1 + VERTEX) = 28.8 µs
- Max (2 textures): RENDER_MODE + 3×(COLOR + UV0_UV1 + VERTEX) = 28.8 µs (same, UV0_UV1 holds both)
- Theoretical max: ~35,000 triangles/second

## Constraints

See specification details above.

## Texture Cache Interaction (REQ-003.08)

Writing to **TEXn_BASE** or **TEXn_FMT** registers (n=0,1) implicitly invalidates the corresponding sampler's texture cache. All valid bits for the affected sampler are cleared, ensuring the next texture access fetches fresh data from SDRAM.

**Performance Counters**: Cache hit/miss statistics are available via performance counter registers (0x50-0x51) for the 2 texture samplers. Read these counters to measure cache efficiency and validate the >85% hit rate target from REQ-003.08.

No explicit cache control registers are defined beyond the performance counters. Future versions may add a `CACHE_CTRL` register for explicit flush/invalidate commands.

## Notes

Migrated from speckit contract: specs/001-spi-gpu/contracts/register-map.md
