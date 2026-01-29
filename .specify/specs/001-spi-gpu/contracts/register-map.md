# Register Map Specification

**Version**: 1.0  
**Date**: January 2026

---

## Overview

The GPU is controlled via a 7-bit address space providing 128 register locations. Each register is 64 bits wide, though many use fewer bits (unused bits are reserved and must be written as zero, read as zero).

**Transaction Format** (72 bits total):
```
[71]      R/W̄ (1 = read, 0 = write)
[70:64]   Register address (7 bits)
[63:0]    Register value (64 bits)
```

---

## Register Summary

| Addr | Name | R/W | Description |
|------|------|-----|-------------|
| 0x00 | COLOR | W | Vertex color (latched) |
| 0x01 | UV | W | Vertex texture coordinates (latched) |
| 0x02 | VERTEX | W | Vertex position + push trigger |
| 0x04 | TRI_MODE | R/W | Triangle rendering mode |
| 0x05 | TEX_BASE | R/W | Texture base address |
| 0x06 | TEX_FMT | R/W | Texture format and dimensions |
| 0x08 | FB_DRAW | R/W | Draw target framebuffer address |
| 0x09 | FB_DISPLAY | R/W | Display scanout framebuffer address |
| 0x0A | CLEAR_COLOR | R/W | Framebuffer clear color |
| 0x0B | CLEAR | W | Trigger framebuffer clear |
| 0x0C | CLEAR_Z | W | Trigger Z-buffer clear |
| 0x10 | STATUS | R | GPU status and FIFO depth |
| 0x7F | ID | R | GPU identification |

---

## Vertex State Registers

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

---

### 0x01: UV

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
- Host must compute 1/W, U/W, V/W per vertex
- GPU reconstructs U = UQ/Q, V = VQ/Q per pixel
- In non-textured mode, UV values are ignored

---

### 0x02: VERTEX

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
  vertex[vertex_count] = {current_COLOR, current_UV, X, Y, Z}
  vertex_count++
  if vertex_count == 3:
    submit_triangle(vertex[0], vertex[1], vertex[2])
    vertex_count = 0
```

---

## Rendering Configuration Registers

### 0x04: TRI_MODE

Controls triangle rendering behavior. Affects all subsequent triangles.

```
[63:8]    Reserved (write as 0)
[7:4]     Reserved
[3]       Z_WRITE: Write to Z-buffer on depth test pass
[2]       Z_TEST: Enable depth testing
[1]       TEXTURED: Enable texture mapping
[0]       GOURAUD: Enable Gouraud shading (vs flat)
```

**Mode Combinations**:

| GOURAUD | TEXTURED | Z_TEST | Z_WRITE | Effect |
|---------|----------|--------|---------|--------|
| 0 | 0 | 0 | 0 | Flat color, no depth |
| 1 | 0 | 0 | 0 | Gouraud shaded, no depth |
| 0 | 1 | 0 | 0 | Flat + textured |
| 1 | 1 | 0 | 0 | Gouraud + textured |
| 1 | 1 | 1 | 1 | Full 3D: Gouraud + texture + Z |

---

### 0x05: TEX_BASE

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

---

### 0x06: TEX_FMT

Texture dimensions and format.

```
[63:16]   Reserved (write as 0)
[15:8]    Reserved (future: pixel format)
[7:4]     HEIGHT_LOG2: log₂(height), valid 3-8 (8×8 to 256×256)
[3:0]     WIDTH_LOG2: log₂(width), valid 3-8 (8×8 to 256×256)
```

**Dimension Encoding**:

| Value | Dimension |
|-------|-----------|
| 3 | 8 |
| 4 | 16 |
| 5 | 32 |
| 6 | 64 |
| 7 | 128 |
| 8 | 256 |

**Example**: 64×64 texture → WIDTH_LOG2=6, HEIGHT_LOG2=6 → write 0x66

---

## Framebuffer Registers

### 0x08: FB_DRAW

Address where triangles are rendered. Must be 4K aligned.

```
[63:32]   Reserved (write as 0)
[31:12]   Base address bits [31:12]
[11:0]    Ignored (assumed 0)
```

**Notes**:
- Default after reset: 0x000000
- Changing FB_DRAW mid-frame allows render-to-texture

---

### 0x09: FB_DISPLAY

Address scanned out to display. Must be 4K aligned.

```
[63:32]   Reserved (write as 0)
[31:12]   Base address bits [31:12]
[11:0]    Ignored (assumed 0)
```

**Notes**:
- Change takes effect at next VSYNC (no tearing)
- Default after reset: 0x000000

---

### 0x0A: CLEAR_COLOR

Color used by CLEAR command.

```
[63:32]   Reserved (write as 0)
[31:24]   Alpha
[23:16]   Blue
[15:8]    Green
[7:0]     Red
```

---

### 0x0B: CLEAR

Writing any value triggers framebuffer clear.

```
[63:0]    Ignored (any write triggers clear)
```

**Behavior**:
- Fills FB_DRAW region with CLEAR_COLOR
- Blocks until complete (~3ms for 640×480×32bpp)
- Does not clear Z-buffer (use CLEAR_Z separately)

---

### 0x0C: CLEAR_Z

Writing any value triggers Z-buffer clear.

```
[63:0]    Ignored (any write triggers clear)
```

**Behavior**:
- Fills Z-buffer with maximum depth (0x1FFFFFF)
- Blocks until complete (~2ms for 640×480×24bpp)

---

## Status Registers

### 0x10: STATUS

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

---

### 0x7F: ID

GPU identification (read-only).

```
[63:32]   Reserved (reads as 0)
[31:16]   VERSION: Major.Minor (8.8)
[15:0]    DEVICE_ID: 0x6701 ("gp" + version)
```

**Example**: Version 1.0 → reads as 0x00000100_00006701

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

**Triangle Submission** (10 writes @ 25 MHz SPI):
- Minimum: 3 VERTEX writes = 8.64 µs
- Typical: TRI_MODE + 3×(COLOR + UV + VERTEX) = 28.8 µs
- Theoretical max: ~35,000 triangles/second

---

## Reset State

After hardware reset or power-on:

| Register | Reset Value |
|----------|-------------|
| TRI_MODE | 0x00 (flat, untextured, no Z) |
| TEX_BASE | 0x00000000 |
| TEX_FMT | 0x00 |
| FB_DRAW | 0x00000000 |
| FB_DISPLAY | 0x00000000 |
| CLEAR_COLOR | 0x00000000 (black) |
| vertex_count | 0 |

---

## Programming Examples

### Initialize Double Buffering

```c
#define FB_A  0x000000
#define FB_B  0x12C000

gpu_write(REG_FB_DRAW, FB_A);
gpu_write(REG_FB_DISPLAY, FB_B);
```

### Clear Screen to Blue

```c
gpu_write(REG_CLEAR_COLOR, 0xFF0000FF);  // RGBA: blue, full alpha
gpu_write(REG_CLEAR, 0);                  // Trigger clear
while (gpu_read(REG_STATUS) & STATUS_BUSY);  // Wait for completion
```

### Draw Flat Red Triangle

```c
gpu_write(REG_TRI_MODE, 0x00);           // Flat, no texture, no Z
gpu_write(REG_COLOR, 0xFF0000FF);        // Red

// Vertex 0
gpu_write(REG_VERTEX, PACK_XYZ(320, 100, 0));

// Vertex 1  
gpu_write(REG_VERTEX, PACK_XYZ(200, 380, 0));

// Vertex 2 (triggers draw)
gpu_write(REG_VERTEX, PACK_XYZ(440, 380, 0));
```

### Draw Textured Triangle with Z

```c
gpu_write(REG_TRI_MODE, TRI_GOURAUD | TRI_TEXTURED | TRI_Z_TEST | TRI_Z_WRITE);
gpu_write(REG_TEX_BASE, 0x340000);
gpu_write(REG_TEX_FMT, 0x66);            // 64×64

gpu_write(REG_COLOR, 0xFFFFFFFF);        // White (no tint)
gpu_write(REG_UV, PACK_UVQ(u0, v0, q0));
gpu_write(REG_VERTEX, PACK_XYZ(x0, y0, z0));

gpu_write(REG_COLOR, 0xFFFFFFFF);
gpu_write(REG_UV, PACK_UVQ(u1, v1, q1));
gpu_write(REG_VERTEX, PACK_XYZ(x1, y1, z1));

gpu_write(REG_COLOR, 0xFFFFFFFF);
gpu_write(REG_UV, PACK_UVQ(u2, v2, q2));
gpu_write(REG_VERTEX, PACK_XYZ(x2, y2, z2));  // Triggers draw
```

### Swap Buffers at VSYNC

```c
// Wait for VSYNC
while (!(GPIO_IN & GPIO_VSYNC));

// Swap
uint32_t temp = current_draw;
current_draw = current_display;
current_display = temp;

gpu_write(REG_FB_DRAW, current_draw);
gpu_write(REG_FB_DISPLAY, current_display);
```
