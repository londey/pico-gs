# Memory Map Specification

**Version**: 1.0  
**Date**: January 2026

---

## SRAM Overview

| Parameter | Value |
|-----------|-------|
| Total Capacity | 32 MB (33,554,432 bytes) |
| Data Width | 16 bits |
| Clock Frequency | 100 MHz |
| Address Range | 0x000000 - 0x1FFFFFF |
| Peak Bandwidth | 200 MB/s |

---

## Address Space Allocation

```
0x0000000 ┌─────────────────────────────────────────┐
          │                                         │
          │         Framebuffer A (Color)           │
          │         640×480×4 = 1,228,800 bytes     │
          │                                         │
0x012C000 ├─────────────────────────────────────────┤
          │                                         │
          │         Framebuffer B (Color)           │
          │         640×480×4 = 1,228,800 bytes     │
          │                                         │
0x0258000 ├─────────────────────────────────────────┤
          │                                         │
          │         Z-Buffer                        │
          │         640×480×3 = 921,600 bytes       │
          │         (padded to 4 bytes/pixel)       │
          │         Actual: 640×480×4 = 1,228,800   │
          │                                         │
0x0384000 ├─────────────────────────────────────────┤
          │                                         │
          │         Texture Memory                  │
          │         ~768 KB available               │
          │                                         │
0x0440000 ├─────────────────────────────────────────┤
          │                                         │
          │                                         │
          │         Reserved / Free                 │
          │         ~27.7 MB                        │
          │                                         │
          │                                         │
0x2000000 └─────────────────────────────────────────┘
```

---

## Detailed Regions

### Framebuffer A (Color)

| Parameter | Value |
|-----------|-------|
| Base Address | 0x000000 |
| End Address | 0x12BFFF |
| Size | 1,228,800 bytes |
| Pixel Format | RGB565 (16 bits) stored in 32-bit words |
| Dimensions | 640 × 480 |
| Row Pitch | 2,560 bytes (640 × 4) |

**Storage Format**:
```
[31:16]   Unused (zeros)
[15:11]   Red (5 bits)
[10:5]    Green (6 bits)
[4:0]     Blue (5 bits)
```

**Address Calculation**:
```
pixel_addr = FB_BASE + (y * 640 + x) * 4
```

**Note**: RGB565 uses only lower 16 bits of each 32-bit word. This wastes 50% of storage but simplifies addressing. Upper 16 bits are written as zero. Future optimization could pack 2 pixels per word.

**4K Alignment**: Base address 0x000000 is naturally 4K aligned.

---

### Framebuffer B (Color)

| Parameter | Value |
|-----------|-------|
| Base Address | 0x12C000 |
| End Address | 0x257FFF |
| Size | 1,228,800 bytes |
| Pixel Format | RGB565 (16 bits) stored in 32-bit words |
| Dimensions | 640 × 480 |
| Row Pitch | 2,560 bytes |

**Storage Format**: Same as Framebuffer A (RGB565 in lower 16 bits, upper 16 bits unused)

**4K Alignment**: 0x12C000 = 1,228,800 = 300 × 4096, aligned.

---

### Z-Buffer

| Parameter | Value |
|-----------|-------|
| Base Address | 0x258000 |
| End Address | 0x383FFF |
| Size | 1,228,800 bytes (padded) |
| Depth Format | 24-bit in 32-bit word |
| Dimensions | 640 × 480 |
| Row Pitch | 2,560 bytes |

**Storage Format**:
```
[31:24]   Unused (reads as 0)
[23:0]    Depth value (0 = near, 0xFFFFFF = far)
```

**Address Calculation**:
```
z_addr = Z_BASE + (y * 640 + x) * 4
```

**Note**: 32-bit aligned storage wastes 25% space but simplifies addressing and SRAM access (16-bit SRAM needs 2 cycles per pixel anyway).

---

### Texture Memory

| Parameter | Value |
|-----------|-------|
| Base Address | 0x384000 |
| End Address | 0x43FFFF |
| Size | 786,432 bytes (~768 KB) |
| Pixel Format | RGBA8888 (32 bits, full 32-bit usage) |

**Note**: Textures use full RGBA8888 format (all 32 bits used) unlike framebuffer which stores RGB565 in lower 16 bits. Textures maintain higher quality for sampling and filtering; conversion to RGB565 happens during rasterization when writing to framebuffer.

**Capacity Examples**:

| Texture Size | Bytes | Count in Region |
|--------------|-------|-----------------|
| 256×256 | 262,144 | 3 |
| 128×128 | 65,536 | 12 |
| 64×64 | 16,384 | 48 |
| 32×32 | 4,096 | 192 |

**Texture Address Alignment**: Textures must be 4K aligned for TEX_BASE register.

**Recommended Texture Layout**:
```
0x384000  Texture 0 (up to 256×256)
0x3C4000  Texture 1 (up to 256×256)
0x404000  Texture 2 (up to 256×256)
0x440000  (end of default texture region)
```

---

### Reserved / Free Region

| Parameter | Value |
|-----------|-------|
| Base Address | 0x440000 |
| End Address | 0x1FFFFFF |
| Size | 29,097,984 bytes (~27.7 MB) |

**Potential Uses**:
- Additional framebuffers (triple buffering)
- Larger texture storage
- Future: vertex buffers, command lists
- Host scratch memory

---

## Memory Access Patterns

### Display Scanout (Read)

```
Priority: HIGHEST
Pattern: Sequential read, one scanline at a time
Bandwidth: 640 × 4 × 60 × 480 = 73.7 MB/s (32-bit words)
Effective: 640 × 2 × 60 × 480 = 36.9 MB/s (RGB565 data only)
Access: Burst read, 2560 bytes per scanline
Timing: Must complete before next scanline starts
```

**Note**: Bandwidth reflects 32-bit word reads, but only lower 16 bits contain RGB565 pixel data. Upper 16 bits are discarded. Effective bandwidth for pixel data is half of memory bandwidth.

**Scanline Timing**:
- Pixel clock: 25.175 MHz
- Pixels per line (total): 800
- Time per line: 31.78 µs
- Visible pixels: 640 (25.4 µs)
- Blanking: 160 pixels (6.4 µs)

FIFO prefetch uses blanking time to stay ahead.

---

### Triangle Rasterization (Write)

```
Priority: LOW (yields to display)
Pattern: Semi-sequential within triangle bbox
Bandwidth: Variable, up to 100 MB/s burst
Access: Single pixel or short burst writes
```

**Write Coalescing**:
- Rasterizer emits pixels in scanline order
- Adjacent pixels can be combined into burst
- Typical burst: 4-16 pixels (16-64 bytes)

---

### Texture Fetch (Read)

```
Priority: MEDIUM
Pattern: Random access within texture bounds
Bandwidth: Up to 50 MB/s (depends on texture cache hit rate)
Access: Single texel (4 bytes) per fetch
```

**Optimization**: Future versions may add small texture cache in BRAM to reduce SRAM traffic.

---

### Z-Buffer (Read/Write)

```
Priority: LOW
Pattern: Matches rasterization pattern
Bandwidth: ~50 MB/s for read + write
Access: Read-test-write per pixel
```

**Z-Buffer Access Sequence**:
1. Read current Z at (x, y)
2. Compare with incoming Z
3. If test passes: write new Z and color
4. If test fails: discard pixel

---

## Bandwidth Budget

### Theoretical Maximum

```
16-bit × 100 MHz = 200 MB/s peak
```

### Allocated Budget

| Consumer | Bandwidth | % of Total |
|----------|-----------|------------|
| Display scanout | 74 MB/s | 37% |
| Framebuffer write | 50 MB/s | 25% |
| Z-buffer R/W | 40 MB/s | 20% |
| Texture fetch | 30 MB/s | 15% |
| **Headroom** | 6 MB/s | 3% |

### Fill Rate Estimate

At 50 MB/s write bandwidth:
```
50 MB/s ÷ 4 bytes/pixel = 12.5 Mpixels/sec
```

For 640×480 @ 60 Hz (18.4 Mpixels/sec visible):
- Can fill ~68% of screen per frame
- Sufficient for typical 3D scenes with occlusion

---

## SRAM Timing

### Async SRAM (typical)

| Parameter | Value |
|-----------|-------|
| Read cycle time | 10 ns |
| Write cycle time | 10 ns |
| Address setup | 2 ns |
| Data valid after address | 8 ns |

### Controller Implementation

```
State machine (100 MHz, 10 ns cycle):

READ:
  Cycle 0: Drive address, OE low
  Cycle 1: Data valid, latch data
  
WRITE:
  Cycle 0: Drive address and data, WE low
  Cycle 1: WE high (data latched on rising edge)
```

**32-bit Access**: Two cycles for 32-bit word (16-bit data bus)

```
WRITE_32:
  Cycle 0: Write low 16 bits
  Cycle 1: Write high 16 bits

READ_32:
  Cycle 0: Read low 16 bits
  Cycle 1: Read high 16 bits
```

---

## Address Encoding in Registers

### FB_DRAW / FB_DISPLAY Registers

```
Register value: [31:12] = address >> 12
Effective address: value << 12

Examples:
  FB_A (0x000000): register = 0x00000
  FB_B (0x12C000): register = 0x0012C
```

### TEX_BASE Register

Same encoding as framebuffer registers.

```
Texture at 0x384000: register = 0x00384
```

---

## Host Memory Upload

To upload texture data from host:

1. **Direct Register Write** (slow, for small data):
   - No dedicated upload register in current spec
   - Would require adding MEM_ADDR and MEM_DATA registers

2. **DMA via Second SPI** (future enhancement):
   - Dedicated bulk transfer interface
   - Not in initial specification

3. **Pre-loaded SRAM** (practical for development):
   - Load textures at power-on via test interface
   - Or use RP2350's second core for SRAM init

**Recommendation for MVP**: Add MEM_ADDR (0x70) and MEM_DATA (0x71) registers for host memory access:

```
MEM_ADDR: Write sets SRAM address pointer
MEM_DATA: Write stores 32 bits at pointer, auto-increments
          Read returns 32 bits at pointer, auto-increments
```

This allows host to upload textures at ~3 MB/s (limited by SPI).

---

## Alternative Memory Maps

### Single Buffer (Reduced Memory)

For simpler applications without double-buffering:

```
0x000000  Framebuffer (1.2 MB)
0x12C000  Z-Buffer (1.2 MB)
0x258000  Textures (remaining)
```

Saves 1.2 MB for larger texture storage.

### Triple Buffer

For lowest latency input response:

```
0x000000  Framebuffer A (1.2 MB)
0x12C000  Framebuffer B (1.2 MB)
0x258000  Framebuffer C (1.2 MB)
0x384000  Z-Buffer (1.2 MB)
0x4B0000  Textures (remaining ~26 MB)
```

Host renders to A, GPU displays B, C is ready for next frame.

### High Resolution (Future)

For 800×600 or 1024×768 (requires faster pixel clock):

```
800×600×4 = 1,920,000 bytes per buffer
Two buffers + Z = 5.76 MB
Still fits easily in 32 MB
```
