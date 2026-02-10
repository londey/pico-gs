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

## Specification


**Version**: 5.0
**Date**: February 2026
**Status**: Color Pipeline Enhancement

---

## Overview

The GPU is controlled via a 7-bit address space providing 128 register locations. Each register is 64 bits wide, though many use fewer bits (unused bits are reserved and must be written as zero, read as zero).

**Transaction Format** (72 bits total):
```
[71]      R/W̄ (1 = read, 0 = write)
[70:64]   Register address (7 bits)
[63:0]    Register value (64 bits)
```

**Major Features** (v5.0):
- 4 independent texture units with separate UV coordinates
- Texture blend modes (multiply, add, subtract, inverse subtract)
- RGBA4444 and BC1 block-compressed texture formats (see INT-014)
- Swizzle patterns for channel reordering
- Z-buffer with configurable compare functions
- Alpha blending modes
- Memory upload interface
- Ordered dithering control (v5.0)
- Color grading LUT at scanout (v5.0)

---

## Address Space Organization

```
0x00-0x0F: Vertex State (COLOR, UV0-UV3, VERTEX)
0x10-0x2F: Texture Configuration (4 units × 8 registers)
0x30-0x3F: Rendering Configuration (TRI_MODE, ALPHA_BLEND)
0x40-0x4F: Framebuffer & Z-Buffer
0x70-0x7F: Status & Control (MEM_ADDR, MEM_DATA, STATUS, ID)
```

---

## Register Summary

| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| **Vertex State** ||||
| 0x00 | COLOR | W | Vertex color (latched) |
| 0x01 | UV0 | W | Texture unit 0 coordinates |
| 0x02 | UV1 | W | Texture unit 1 coordinates |
| 0x03 | UV2 | W | Texture unit 2 coordinates |
| 0x04 | UV3 | W | Texture unit 3 coordinates |
| 0x05 | VERTEX | W | Vertex position + push trigger |
| 0x06-0x0F | - | - | Reserved (future vertex attributes) |
| **Texture Unit 0** ||||
| 0x10 | TEX0_BASE | R/W | Texture 0 base address |
| 0x11 | TEX0_FMT | R/W | Texture 0 format, dimensions, swizzle |
| 0x12 | TEX0_BLEND | R/W | Texture 0 blend function |
| 0x13 | - | - | Reserved |
| 0x14 | TEX0_WRAP | R/W | Texture 0 UV wrapping mode |
| 0x15-0x17 | - | - | Reserved (texture 0) |
| **Texture Unit 1** ||||
| 0x18 | TEX1_BASE | R/W | Texture 1 base address |
| 0x19 | TEX1_FMT | R/W | Texture 1 format, dimensions, swizzle |
| 0x1A | TEX1_BLEND | R/W | Texture 1 blend function |
| 0x1B | - | - | Reserved |
| 0x1C | TEX1_WRAP | R/W | Texture 1 UV wrapping mode |
| 0x1D-0x1F | - | - | Reserved (texture 1) |
| **Texture Unit 2** ||||
| 0x20 | TEX2_BASE | R/W | Texture 2 base address |
| 0x21 | TEX2_FMT | R/W | Texture 2 format, dimensions, swizzle |
| 0x22 | TEX2_BLEND | R/W | Texture 2 blend function |
| 0x23 | - | - | Reserved |
| 0x24 | TEX2_WRAP | R/W | Texture 2 UV wrapping mode |
| 0x25-0x27 | - | - | Reserved (texture 2) |
| **Texture Unit 3** ||||
| 0x28 | TEX3_BASE | R/W | Texture 3 base address |
| 0x29 | TEX3_FMT | R/W | Texture 3 format, dimensions, swizzle |
| 0x2A | TEX3_BLEND | R/W | Texture 3 blend function |
| 0x2B | - | - | Reserved |
| 0x2C | TEX3_WRAP | R/W | Texture 3 UV wrapping mode |
| 0x2D-0x2F | - | - | Reserved (texture 3) |
| **Rendering Config** ||||
| 0x30 | TRI_MODE | R/W | Triangle rendering mode |
| 0x31 | ALPHA_BLEND | R/W | Alpha blending mode |
| 0x32 | DITHER_MODE | R/W | Ordered dithering control |
| 0x33-0x3F | - | - | Reserved (rendering config) |
| **Framebuffer** ||||
| 0x40 | FB_DRAW | R/W | Draw target framebuffer address |
| 0x41 | FB_DISPLAY | R/W | Display scanout framebuffer address |
| 0x42 | FB_ZBUFFER | R/W | Z-buffer address + compare function |
| 0x43 | FB_STENCIL | - | Reserved (stencil buffer) |
| 0x44 | COLOR_GRADE_CTRL | R/W | Color grading LUT control |
| 0x45 | COLOR_GRADE_LUT_ADDR | R/W | Color grading LUT address |
| 0x46 | COLOR_GRADE_LUT_DATA | W | Color grading LUT data |
| 0x47-0x4F | - | - | Reserved (framebuffer config) |
| **Status & Control** ||||
| 0x70 | MEM_ADDR | R/W | Memory upload address pointer |
| 0x71 | MEM_DATA | R/W | Memory upload data (auto-increment) |
| 0x72-0x7D | - | - | Reserved |
| 0x7E | STATUS | R | GPU status and FIFO depth |
| 0x7F | ID | R | GPU identification |

---

## Vertex State Registers (0x00-0x0F)

### 0x00: COLOR

Latches RGBA color for the next vertex push.

```
[63:32]   Reserved (write as 0)
[31:24]   Alpha (8 bits)
[23:16]   Blue (8 bits)
[15:8]    Green (8 bits)
[7:0]     Red (8 bits)
```

**Notes**:
- Color is associated with the next VERTEX write
- In flat shading mode (GOURAUD=0), only vertex 0's color is used
- Values are 0-255, where 255 = full intensity

**Reset Value**: 0x00000000 (transparent black)

---

### 0x01-0x04: UV0, UV1, UV2, UV3

Latches texture coordinates for the next vertex push. Values are pre-divided by W for perspective correction.

```
[63:48]   Reserved (write as 0)
[47:32]   Q = 1/W (1.15 signed fixed-point)
[31:16]   VQ = V/W (1.15 signed fixed-point)
[15:0]    UQ = U/W (1.15 signed fixed-point)
```

**Fixed-Point Format (1.15)**:
- Bit 15: Sign
- Bits 14:0: Fractional value
- Range: -1.0 to +0.99997
- Resolution: 1/32768 ≈ 0.00003

**Notes**:
- Host must compute 1/W, U/W, V/W per vertex for each texture unit
- GPU reconstructs U = UQ/Q, V = VQ/Q per pixel
- UV coordinates for disabled texture units are ignored
- Each texture unit uses its corresponding UVn register

**Reset Value**: 0x0000000000000000

---

### 0x05: VERTEX

Latches vertex position and triggers vertex push. Third push submits triangle.

```
[63:57]   Reserved (write as 0)
[56:32]   Z depth (25 bits unsigned)
[31:16]   Y coordinate (12.4 signed fixed-point)
[15:0]    X coordinate (12.4 signed fixed-point)
```

**Fixed-Point Format (12.4)**:
- Bits 15:4: Signed integer (-2048 to +2047)
- Bits 3:0: Fractional (1/16 pixel)

**Z Format (25 bits)**:
- Unsigned, 0 = near plane, 0x1FFFFFF = far plane
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

### TEXn_FMT (0x11, 0x19, 0x21, 0x29)

Texture format, dimensions, swizzle pattern, and mipmap levels.

```
[63:24]   Reserved (write as 0)
[23:20]   MIP_LEVELS: Number of mipmap levels (0-15)
          0000 = No mipmaps (disabled, single level only)
          0001 = Base level only (equivalent to 0, backward compatible)
          0010 = Base + 1 mip level (2 levels total)
          ...
          1011 = Base + 10 mip levels (11 levels total, max for 1024×1024)
          1100-1111 = Reserved
[19:16]   Swizzle pattern (4 bits, see encoding below)
[15:8]    HEIGHT_LOG2: log₂(height), valid 3-10 (8 to 1024 pixels)
[7:4]     WIDTH_LOG2: log₂(width), valid 3-10 (8 to 1024 pixels)
[3]       Reserved (write as 0)
[2:1]     FORMAT: Texture format encoding
          00 = RGBA4444 (16 bits per pixel, see INT-014)
          01 = BC1 (block compressed, 64 bits per 4x4 block, see INT-014)
          10 = Reserved (future format)
          11 = Reserved (future format)
[0]       ENABLE: 0=disabled, 1=enabled
```

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

**Example**: 64x64 texture, RGBA4444, enabled, no mipmaps → WIDTH_LOG2=6, HEIGHT_LOG2=6, FORMAT=00, MIP_LEVELS=1 → write 0x00000000_00100661
**Example**: 256x256 texture, BC1, enabled, 9 mipmap levels → WIDTH_LOG2=8, HEIGHT_LOG2=8, FORMAT=01, MIP_LEVELS=9 → write 0x00000000_00900883

**Reset Value**: 0x0000000000000000 (disabled)

---

### TEXn_BLEND (0x12, 0x1A, 0x22, 0x2A)

Texture blend function applied when combining with previous texture.

```
[63:2]    Reserved (write as 0)
[1:0]     Blend function:
          00 = MULTIPLY (component-wise: result = prev × current)
          01 = ADD (component-wise: result = prev + current, saturate)
          10 = SUBTRACT (component-wise: result = prev - current, saturate)
          11 = INVERSE_SUBTRACT (component-wise: result = current - prev, saturate)
```

**Blend Order**: Textures are evaluated sequentially (0→1→2→3):
```
Step 1: Sample TEX0 → color = tex0_rgba
Step 2: Sample TEX1, blend: color = blend(color, tex1_rgba, TEX1_BLEND.func)
Step 3: Sample TEX2, blend: color = blend(color, tex2_rgba, TEX2_BLEND.func)
Step 4: Sample TEX3, blend: color = blend(color, tex3_rgba, TEX3_BLEND.func)
Step 5: Multiply by vertex color if GOURAUD enabled
Step 6: Apply alpha blend with framebuffer if ALPHA_BLEND != DISABLED
```

**Note**: TEX0_BLEND is ignored (no previous texture to blend with).

**Reset Value**: 0x0000000000000000 (multiply)

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

### 0x30: TRI_MODE

Controls triangle rendering behavior. Affects all subsequent triangles.

```
[63:8]    Reserved (write as 0)
[7:5]     Reserved
[4]       ANY_TEXTURED: Read-only computed flag
[3]       Z_WRITE: Write to Z-buffer on depth test pass
[2]       Z_TEST: Enable depth testing
[1]       Reserved (was TEXTURED in v1.0, now per-texture)
[0]       GOURAUD: Enable Gouraud shading (vs flat)
```

**ANY_TEXTURED Flag** (bit 4, read-only):
- Computed by GPU as: TEX0_FMT.ENABLE | TEX1_FMT.ENABLE | TEX2_FMT.ENABLE | TEX3_FMT.ENABLE
- Writes to this bit are ignored
- Allows software to query if any texture unit is active

**Mode Combinations**:

| GOURAUD | Z_TEST | Z_WRITE | ANY_TEXTURED | Effect |
|---------|--------|---------|--------------|--------|
| 0 | 0 | 0 | 0 | Flat color, no depth |
| 1 | 0 | 0 | 0 | Gouraud shaded, no depth |
| 1 | 0 | 0 | 1 | Gouraud + multi-textured |
| 1 | 1 | 1 | 1 | Full 3D: Gouraud + textures + Z |

**Reset Value**: 0x0000000000000000 (flat, no texture, no Z)

---

### 0x31: ALPHA_BLEND

Framebuffer alpha blending mode.

```
[63:2]    Reserved (write as 0)
[1:0]     Blend mode:
          00 = DISABLED (overwrite destination)
          01 = ADD (result = src.rgba + dst.rgba, saturate)
          10 = SUBTRACT (result = src.rgba - dst.rgba, saturate)
          11 = ALPHA_BLEND (result = src × α + dst × (1-α))
```

**ALPHA_BLEND Operation** (mode 11):
```
R_out = R_src × A_src + R_dst × (1 - A_src)
G_out = G_src × A_src + G_dst × (1 - A_src)
B_out = B_src × A_src + B_dst × (1 - A_src)
A_out = A_src + A_dst × (1 - A_src)
```

**Notes**:
- All blend operations performed in 10.8 fixed-point format (see REQ-134)
- ADD/SUBTRACT: Per-component, saturate to [0, 1023] in 10-bit integer range
- ALPHA_BLEND: Standard Porter-Duff source-over operator in 10.8 precision
- Disable Z_WRITE when rendering transparent objects (keep Z_TEST enabled)

**Reset Value**: 0x0000000000000000 (disabled)

---

### 0x32: DITHER_MODE

Controls ordered dithering before RGB565 framebuffer conversion. See REQ-132.

```
[63:4]    Reserved (write as 0)
[3:2]     PATTERN: Dither pattern selection
          00 = Blue noise 16x16 (default)
          01-11 = Reserved
[1]       Reserved (write as 0)
[0]       ENABLE: 1=dithering enabled (default), 0=disabled
```

**Notes**:
- Dithering is enabled by default after reset
- Dithering adds spatial noise to smooth the 10.8→RGB565 quantization
- When disabled, 10.8 values truncate directly to RGB565

**Reset Value**: 0x0000000000000001 (enabled, blue noise)

**Version**: Added in v5.0

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

### 0x42: FB_ZBUFFER

Z-buffer configuration: base address and compare function.

```
[63:35]   Reserved (write as 0)
[34:32]   Z_COMPARE function:
          000 = LESS (<)
          001 = LEQUAL (≤)
          010 = EQUAL (=)
          011 = GEQUAL (≥)
          100 = GREATER (>)
          101 = NOTEQUAL (≠)
          110 = ALWAYS (always pass)
          111 = NEVER (always fail)
[31:12]   Z-buffer base address bits [31:12] (4K aligned)
[11:0]    Ignored (assumed 0)
```

**Z-Compare Function**:
- Test passes when: `incoming_z COMPARE zbuffer_value` evaluates to true
- If test passes and Z_WRITE=1: write incoming_z to Z-buffer
- If test passes: write fragment color
- If test fails: discard fragment

**Z-Buffer Memory Format**: 32-bit words with 24-bit depth:
```
[31:24] = unused (should be 0)
[23:0]  = depth value (0 = near, 0xFFFFFF = far)
```

**Typical Usage**:
- Normal 3D rendering: LESS or LEQUAL
- Reverse Z (far-to-near): GREATER or GEQUAL
- Stencil-like behavior: EQUAL
- Override depth: ALWAYS
- Disable rendering: NEVER

**Reset Value**: 0x0000000000000000 (LESS compare, address=0)

---

### 0x43: FB_STENCIL

Reserved for future stencil buffer configuration.

```
[63:0]    Reserved (write as 0)
```

**Future Features** (placeholder):
- Stencil base address
- Stencil compare function
- Stencil pass/fail operations
- Stencil reference value

**Reset Value**: 0x0000000000000000

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
[63:15]   Reserved (write as 0)
[14:10]   R output (5 bits)
[9:5]     G output (5 bits)
[4:0]     B output (5 bits)
```

**Entry Format**: R5G5B5 (15 bits per entry). Each LUT entry specifies the RGB contribution of that input channel to the final output.

**Lookup Process** (per scanout pixel):
```
lut_r_out = red_lut[pixel_R5]     // R5G5B5
lut_g_out = green_lut[pixel_G6]   // R5G5B5
lut_b_out = blue_lut[pixel_B5]    // R5G5B5

final_R5 = saturate(lut_r_out.R + lut_g_out.R + lut_b_out.R, 31)
final_G5 = saturate(lut_r_out.G + lut_g_out.G + lut_b_out.G, 31)
final_B5 = saturate(lut_r_out.B + lut_g_out.B + lut_b_out.B, 31)
```

**Upload Protocol**:
1. Write COLOR_GRADE_CTRL[2] (RESET_ADDR) to reset pointer
2. For each LUT entry: write COLOR_GRADE_LUT_ADDR, then COLOR_GRADE_LUT_DATA
3. Write COLOR_GRADE_CTRL[1] (SWAP_BANKS) to activate at next vblank

**Reset Value**: 0x0000000000000000

**Version**: Added in v5.0

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

After hardware reset or power-on:

| Register | Reset Value | Description |
|----------|-------------|-------------|
| COLOR | 0x00000000 | Transparent black |
| UV0-UV3 | 0x0000000000000000 | Zero coordinates |
| VERTEX | N/A | Write-only trigger |
| TEX0-TEX3 BASE | 0x0000000000000000 | Address 0x000000 |
| TEX0-TEX3 FMT | 0x0000000000000000 | Disabled, RGBA4444, 8x8 default |
| TEX0-TEX3 BLEND | 0x0000000000000000 | MULTIPLY |
| TEX0-TEX3 WRAP | 0x0000000000000000 | REPEAT both axes |
| TRI_MODE | 0x0000000000000000 | Flat, no texture, no Z |
| ALPHA_BLEND | 0x0000000000000000 | Disabled |
| DITHER_MODE | 0x0000000000000001 | Enabled, blue noise |
| COLOR_GRADE_CTRL | 0x0000000000000000 | Disabled |
| COLOR_GRADE_LUT_ADDR | 0x0000000000000000 | Red LUT, entry 0 |
| COLOR_GRADE_LUT_DATA | N/A | Write-only |
| FB_DRAW | 0x0000000000000000 | Address 0x000000 |
| FB_DISPLAY | 0x0000000000000000 | Address 0x000000 |
| FB_ZBUFFER | 0x0000000000000000 | LESS compare, address 0x000000 |
| FB_STENCIL | 0x0000000000000000 | Reserved |
| MEM_ADDR | 0x0000000000000000 | Address 0x000000 |
| MEM_DATA | N/A | Depends on memory |
| STATUS | 0x0000000000000000 | Idle, FIFO empty |
| ID | 0x0000020000006702 | Version 2.0, device 0x6702 |
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

No explicit cache control registers are defined for MVP. Future versions may add a `CACHE_CTRL` register for:
- Explicit cache flush/invalidate
- Cache hit/miss statistics for performance tuning

## Notes

Migrated from speckit contract: specs/001-spi-gpu/contracts/register-map.md
