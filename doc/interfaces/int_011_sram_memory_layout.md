# INT-011: SRAM Memory Layout

## Type

Internal

## Parties

- **Provider:** External
- **Consumer:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-007 (SRAM Arbiter)
- **Consumer:** UNIT-008 (Display Controller)

## Referenced By

- REQ-002 (Framebuffer Management)
- REQ-005 (Depth Tested Triangle)
- REQ-006 (Textured Triangle)
- REQ-014 (Enhanced Z-Buffer)
- REQ-025 (Framebuffer Format)
- INT-014 (Texture Memory Layout)
- REQ-123 (Double-Buffered Rendering)
- REQ-050 (Performance Targets)
- REQ-051 (Resource Constraints)
- REQ-027 (Z-Buffer Operations)
- REQ-024 (Texture Sampling)
- REQ-023 (Rasterization Algorithm)

## Specification


**Version**: 2.0
**Date**: February 2026

---

## SRAM Overview

| Parameter | Value |
|-----------|-------|
| Total Capacity | 32 MB (33,554,432 bytes) |
| Data Width | 16 bits |
| Clock Frequency | 100 MHz |
| Address Range | 0x000000 - 0x1FFFFFF |
| Peak Bandwidth | 200 MB/s |

**Clock Domain Note**: The SRAM interface operates at 100 MHz, which is the same clock domain as the GPU core (`clk_core`).
All SRAM requestors (rasterizer, pixel pipeline, display controller, texture cache) and the SRAM controller share this single 100 MHz clock domain.
This eliminates the need for clock domain crossing (CDC) logic between the GPU core and SRAM, simplifying the arbiter and reducing access latency.
The only remaining asynchronous CDC boundary is between the SPI slave interface and the GPU core.

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
| Depth Format | 16-bit in 32-bit word |
| Dimensions | 640 × 480 |
| Row Pitch | 2,560 bytes |

**Storage Format**:
```
[31:16]   Unused (reads as 0)
[15:0]    Depth value (0 = near, 0xFFFF = far)
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
| Formats Supported | RGBA4444 (16 bpp), BC1 (0.5 bpp compressed) |

**Memory layout:** See INT-014 (Texture Memory Layout) for detailed format
specifications. All textures are organized in 4x4 texel blocks.

**Note**: Textures use RGBA4444 or BC1 formats as specified in INT-014.
Unlike the framebuffer (RGB565 in lower 16 bits), textures utilize full
storage efficiency with no padding. BC1 provides 8:1 compression over
legacy RGBA8888.

**RGBA4444 Capacity (16 bpp):**

| Texture Size | Bytes | Count in 768 KB |
|--------------|-------|-----------------|
| 512x512 | 524,288 | 1 |
| 256x256 | 131,072 | 6 |
| 128x128 | 32,768 | 24 |
| 64x64 | 8,192 | 96 |

**BC1 Capacity (0.5 bpp compressed):**

| Texture Size | Bytes | Count in 768 KB |
|--------------|-------|-----------------|
| 1024x1024 | 524,288 | 1 |
| 512x512 | 131,072 | 6 |
| 256x256 | 32,768 | 24 |
| 128x128 | 8,192 | 96 |

**Texture Address Alignment**: Textures must be 4K aligned for TEX_BASE register.

**Recommended Texture Layout (RGBA4444, 256x256)**:
```
0x384000  Texture 0 (128 KB)
0x3A4000  Texture 1 (128 KB)
0x3C4000  Texture 2 (128 KB)
0x3E4000  Texture 3 (128 KB)
0x404000  Texture 4 (128 KB)
0x424000  Texture 5 (128 KB)
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
- **Color grading LUTs** (v9.0 recommendation)
- Additional framebuffers (triple buffering)
- Larger texture storage
- Future: vertex buffers, command lists
- Host scratch memory

**Recommended Color Grading LUT Region (v9.0)**:
```
0x440000 ┬─────────────────────────────────────────┐
         │  Color Grading LUTs                     │
         │  (Recommended allocation)               │
0x441000 │  LUT 0 (identity, 4KiB)                 │
0x442000 │  LUT 1 (gamma 2.2, 4KiB)                │
0x443000 │  LUT 2 (warm tint, 4KiB)                │
0x444000 │  LUT 3 (cool tint, 4KiB)                │
0x445000 │  LUT 4 (high contrast, 4KiB)            │
         │  ... (16 LUTs fit in 64KiB)             │
0x450000 ├─────────────────────────────────────────┤
         │  Free / Additional LUTs                 │
         │  ~27.6 MB                               │
0x2000000 └─────────────────────────────────────────┘
```

**LUT Format** (384 bytes per LUT, padded to 4KiB alignment):
```
Offset  | Data           | Description
--------|----------------|----------------------------------
0x000   | RGB888         | Red LUT entry 0 (R_in=0)
0x003   | RGB888         | Red LUT entry 1 (R_in=1)
...     | ...            | ...
0x05D   | RGB888         | Red LUT entry 31 (R_in=31)
0x060   | RGB888         | Green LUT entry 0 (G_in=0)
...     | ...            | ...
0x11D   | RGB888         | Green LUT entry 63 (G_in=63)
0x120   | RGB888         | Blue LUT entry 0 (B_in=0)
...     | ...            | ...
0x17D   | RGB888         | Blue LUT entry 31 (B_in=31)
0x180   | (padding)      | Unused (pad to 4KiB boundary)
```

Each RGB888 entry: 3 bytes in order R[7:0], G[7:0], B[7:0]

**Usage Notes**:
- Each LUT: 384 bytes actual data + padding to 4KiB
- Firmware can pre-prepare multiple LUTs at boot for instant switching
- LUT auto-load triggered via FB_DISPLAY or FB_DISPLAY_SYNC writes (see INT-010 v9.0)
- Typical setup: identity, gamma correction, various artistic grades

---

## Memory Access Patterns

### Display Scanout (Read)

```
Priority: HIGHEST
Pattern: Sequential burst read, one scanline at a time
Bandwidth: 640 × 4 × 60 × 480 = 73.7 MB/s (32-bit words)
Effective: 640 × 2 × 60 × 480 = 36.9 MB/s (RGB565 data only)
Access: Burst read, 2560 bytes per scanline (1280 × 16-bit burst reads)
Timing: Must complete before next scanline starts
```

**Note**: Bandwidth reflects 32-bit word reads, but only lower 16 bits contain RGB565 pixel data.
Upper 16 bits are discarded.
Effective bandwidth for pixel data is half of memory bandwidth.

**Burst Access**: Display scanout is the primary beneficiary of SRAM burst mode.
Each scanline is 2560 bytes = 1280 sequential 16-bit SRAM reads.
With burst mode, the initial address setup costs 1 cycle (BURST_READ_SETUP), then each subsequent 16-bit word is read in 1 cycle (BURST_READ_NEXT) with auto-incremented addressing.
A full scanline burst of 1280 words costs 1 + 1280 = 1281 cycles.
Without burst mode, each 32-bit word requires 3 cycles (READ_LOW + READ_HIGH + DONE), so 640 words cost 1920 cycles.
Burst mode improves scanline fetch throughput by ~33% (1281 vs 1920 cycles), reducing display bandwidth pressure on the arbiter and freeing cycles for rendering.

**Note**: The arbiter may preempt a display burst to service a higher-latency-sensitive request.
The maximum burst length before preemption check is configurable (see UNIT-007).

**Scanline Timing**:
- Pixel clock: 25.000 MHz (derived as 4:1 divisor from 100 MHz core clock)
- Pixels per line (total): 800
- Time per line: 32.00 us
- Visible pixels: 640 (25.6 us)
- Blanking: 160 pixels (6.4 us)

FIFO prefetch uses blanking time to stay ahead.

---

### Triangle Rasterization (Write)

```
Priority: LOW (yields to display)
Pattern: Semi-sequential within triangle bbox
Bandwidth: Variable, up to 200 MB/s burst (GPU core at 100 MHz)
Access: Single pixel writes or short burst writes (burst_len up to 16)
```

**Write Coalescing / Burst Writes**:
- Rasterizer emits pixels in scanline order
- Adjacent pixels within the same scanline can be combined into a burst write
- Typical burst: 4-16 pixels (8-32 bytes on 16-bit bus)
- Burst writes eliminate per-word DONE-to-IDLE-to-WRITE_LOW overhead, saving 1 cycle per additional word in the burst

---

### Texture Fetch (Read)

```
Priority: MEDIUM
Pattern: Burst block reads on cache miss (REQ-131)
Bandwidth: ~5-15 MB/s average (with >85% cache hit rate)
Access: BC1: 8 bytes per cache miss (burst), RGBA4444: 32 bytes per cache miss (burst)
```

**Texture Cache (REQ-131)**: Each sampler has an on-chip 4-way set-associative texture cache (4x1024x18-bit EBR banks).
On cache hit, no SRAM access is needed.
On cache miss, the full 4x4 block is fetched using a burst read:
- BC1: 8 bytes = 4 sequential 16-bit burst reads (1 setup + 4 data = ~5 cycles)
- RGBA4444: 32 bytes = 16 sequential 16-bit burst reads (1 setup + 16 data = ~17 cycles)

**Improvement over single-word access**: Without burst mode, BC1 required ~8 SRAM bus cycles (4 x 2-cycle 16-bit reads) and RGBA4444 required ~18 SRAM bus cycles (using interleaved address/data cycles).
Burst mode reduces BC1 SRAM transfer time from ~8 to ~5 cycles (37% reduction) and RGBA4444 from ~18 to ~17 cycles (6% reduction).
The BC1 improvement is proportionally larger because the per-burst setup overhead is amortized over fewer words.
End-to-end cache fill latency (including decompression/conversion overlap) is lower; see INT-032 for pipeline-level cache miss latency figures.

With >85% expected hit rate, average texture SRAM bandwidth is significantly reduced from a worst-case ~50 MB/s, freeing bandwidth for framebuffer and Z-buffer operations.

---

### Z-Buffer (Read/Write)

```
Priority: LOW
Pattern: Matches rasterization pattern
Bandwidth: ~50 MB/s for read + write (max), reduced with early Z-test
Access: Read-test (early, before texture) + write (late, after all processing)
```

**Burst Applicability**: Z-buffer accesses follow the rasterization scan order.
When the rasterizer processes consecutive pixels within a scanline, Z-buffer reads and writes can be issued as short bursts (typically 2-8 words).
However, since Z reads and writes are interleaved with depth test decisions (pass/fail), burst lengths are shorter and less predictable than display scanout or texture cache fills.
The primary benefit is eliminating per-word re-arbitration overhead for adjacent pixel Z accesses.

**Z-Buffer Access Sequence** (with early Z-test, v10.0):
1. **Stage 0 (Early)**: Read current Z at (x, y)
2. Compare with incoming Z (using RENDER_MODE.Z_COMPARE function)
3. If test fails: discard fragment immediately (no texture fetch, no color write, no Z write)
4. If test passes: proceed through texture/blend pipeline (Stages 1-5)
5. **Stage 6 (Late)**: If Z_WRITE_EN=1, write new Z value to Z-buffer

**Note**: Z-buffer reads now occur before texture reads in the pipeline (UNIT-006 Stage 0 vs Stage 1+).
This may improve bandwidth utilization: early fragment rejection reduces total SRAM accesses for texture, framebuffer read (alpha blend), and Z write.
In scenes with high overdraw (3-4x), early Z-test can reduce effective Z+texture+FB bandwidth by 30-50%.
No changes to Z-buffer addresses, sizes, or data format.

---

## Bandwidth Budget

### Theoretical Maximum

```
16-bit × 100 MHz = 200 MB/s peak (single-word access)
```

With burst mode, effective throughput approaches the peak for sequential access patterns because burst transfers eliminate per-word address setup and DONE-state overhead.
In single-word mode, a 32-bit access costs 3 cycles (READ_LOW + READ_HIGH + DONE), yielding an effective rate of ~133 MB/s for 32-bit words (66 MB/s for 16-bit payload due to RGB565 padding).
In burst mode, after 1 setup cycle, each subsequent 16-bit word takes 1 cycle, approaching the full 200 MB/s bus rate for long bursts.

### Allocated Budget

| Consumer | Bandwidth (single) | Bandwidth (burst) | % of Total (burst) | Notes |
|----------|--------------------|--------------------|---------------------|-------|
| Display scanout | 74 MB/s | ~50 MB/s | 25% | Burst reads reduce overhead by ~33% |
| Framebuffer write | 50 MB/s | ~40 MB/s | 20% | Short burst writes (4-16 pixels) |
| Z-buffer R/W | 40 MB/s | ~35 MB/s | 17.5% | Short bursts for adjacent pixels |
| Texture fetch | ~10 MB/s | ~8 MB/s | 4% | Burst cache fills (REQ-131), >85% hit rate |
| **Headroom** | ~26 MB/s | ~67 MB/s | 33.5% | Significantly increased by burst efficiency |

**Burst mode impact summary**: Burst mode does not change the peak bus rate (200 MB/s), but it increases the *effective* throughput by reducing per-access overhead (address setup, DONE state, re-arbitration).
The primary benefit is a larger headroom budget: burst mode frees ~41 MB/s of additional headroom compared to single-word mode, enabling higher fill rates and reducing arbiter contention.

**Note**: Pre-cache texture fetch budget was 30 MB/s (15%).
The per-sampler texture cache (REQ-131) reduces average texture SRAM bandwidth to ~5-15 MB/s depending on scene complexity and cache hit rate, freeing ~15-25 MB/s for other consumers.

**Clock Domain Note**: Because the GPU core and SRAM now share the same 100 MHz clock domain, there is no CDC overhead on any arbiter port.
All requestors (display controller, rasterizer, pixel pipeline, texture cache) issue requests synchronously, and the arbiter can grant access with single-cycle latency after an ack.

### Fill Rate Estimate

At 100 MB/s write bandwidth (GPU core and SRAM at 100 MHz):
```
100 MB/s ÷ 4 bytes/pixel = 25 Mpixels/sec
```

For 640×480 @ 60 Hz (18.4 Mpixels/sec visible):
- Can fill ~136% of screen per frame (>1× overdraw budget)
- Sufficient for complex 3D scenes with moderate overdraw

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

**Single-Word Access** (backward-compatible, burst_len=0):

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

**Burst Access** (burst_len>0):

Burst mode reads or writes N sequential 16-bit words starting from a base address.
The SRAM auto-increments the address internally after each access, eliminating per-word address setup overhead.

```
BURST_READ (N words):
  Cycle 0: BURST_READ_SETUP — Drive base address, OE low
  Cycle 1..N: BURST_READ_NEXT — Latch 16-bit word, address auto-increments
  Cycle N+1: DONE — Pulse ack
  Total: N+2 cycles for N×16-bit words

BURST_WRITE (N words):
  Cycle 0: BURST_WRITE_SETUP — Drive base address and first data word, WE low
  Cycle 1..N-1: BURST_WRITE_NEXT — Drive next data word, address auto-increments
  Cycle N: DONE — Pulse ack
  Total: N+1 cycles for N×16-bit words
```

**Burst Length**: The burst_len signal specifies the number of 16-bit words to transfer (1-255).
A burst_len of 0 selects single-word (legacy) mode.

**Throughput Comparison** (reading 8 sequential 16-bit words):
- Single-word mode: 8 words x 3 cycles/word = 24 cycles
- Burst mode: 1 setup + 8 data + 1 done = 10 cycles (2.4x faster)

**Preemption**: The arbiter (UNIT-007) may terminate a burst early by deasserting a grant signal.
When preempted, the SRAM controller completes the current 16-bit transfer, transitions to DONE, and reports the number of words actually transferred.
The requestor is responsible for re-issuing the remaining burst from the next address.

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


## Constraints

See specification details above.

## Notes

Migrated from speckit contract: specs/001-spi-gpu/contracts/memory-map.md
