# INT-011: SDRAM Memory Layout

## Type

Internal

## Parties

- **Provider:** External (W9825G6KH-6 SDRAM)
- **Consumer:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-007 (Memory Arbiter)
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


**Version**: 3.0
**Date**: February 2026

---

## SDRAM Overview

| Parameter | Value |
|-----------|-------|
| Device | Winbond W9825G6KH-6 |
| Total Capacity | 32 MB (256 Mbit) |
| Organization | 4 banks x 8192 rows x 512 columns x 16 bits |
| Data Width | 16 bits |
| Clock Frequency | 100 MHz |
| CAS Latency | 3 cycles (CL=3) |
| Address Range | 0x000000 - 0x1FFFFFF |
| Peak Bandwidth | 200 MB/s (16 bits x 100 MHz) |

**Clock Domain Note**: The SDRAM interface operates at 100 MHz (`clk_core`), which is the same clock domain as the GPU core.
A PLL generates the 100 MHz core clock and a 90-degree phase-shifted 100 MHz clock for the SDRAM chip (`sdram_clk`).
The 90-degree phase shift ensures SDRAM data is valid and centered relative to the internal clock edge, compensating for PCB trace delays and SDRAM output hold times.
All SDRAM requestors (rasterizer, pixel pipeline, display controller, texture cache) and the SDRAM controller share this single 100 MHz clock domain.
The only remaining asynchronous CDC boundary is between the SPI slave interface and the GPU core.

### SDRAM Signal Interface

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `sdram_clk` | 1 | Output | 100 MHz clock, 90-degree phase shift from `clk_core` |
| `sdram_cke` | 1 | Output | Clock enable (always high during normal operation) |
| `sdram_csn` | 1 | Output | Chip select (active low) |
| `sdram_rasn` | 1 | Output | Row address strobe (active low) |
| `sdram_casn` | 1 | Output | Column address strobe (active low) |
| `sdram_wen` | 1 | Output | Write enable (active low) |
| `sdram_ba` | 2 | Output | Bank address |
| `sdram_a` | 13 | Output | Address bus (row: A[12:0], column: A[8:0]) |
| `sdram_dq` | 16 | Bidirectional | Data bus |
| `sdram_dqm` | 2 | Output | Data mask (upper/lower byte) |

### SDRAM Timing Parameters (100 MHz, -6 speed grade)

| Parameter | Symbol | Value | Cycles at 100 MHz |
|-----------|--------|-------|-------------------|
| CAS latency | CL | 3 | 3 |
| RAS to CAS delay | tRCD | 18 ns | 2 |
| Row precharge time | tRP | 18 ns | 2 |
| Row active time (min) | tRAS | 42 ns | 5 |
| Row cycle time | tRC | 60 ns | 6 |
| Auto-refresh period | tREF | 64 ms / 8192 rows | 781 cycles per row |
| Write recovery time | tWR | 2 cycles | 2 |
| Mode register set delay | tMRD | 2 cycles | 2 |
| Power-up delay | — | 200 us | 20,000 |

### SDRAM Initialization Sequence

After power-on and PLL lock, the SDRAM controller must execute the following initialization sequence before any read or write access:

1. Wait at least 200 us with CKE high and stable clock
2. Issue PRECHARGE ALL command (A10=1)
3. Wait tRP (2 cycles)
4. Issue 2x AUTO REFRESH commands (each followed by tRC = 6 cycle wait)
5. Issue LOAD MODE REGISTER: CL=3, burst length=1 (full page burst not used), sequential burst type
6. Wait tMRD (2 cycles)
7. SDRAM is now ready for normal operation

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
With SDRAM's 16-bit data bus, a 32-bit pixel access requires two sequential column reads/writes within the same active row.

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

**Note**: 32-bit aligned storage wastes 25% space but simplifies addressing and SDRAM access (16-bit SDRAM bus needs 2 column accesses per pixel anyway).

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
Access: Burst read, 2560 bytes per scanline (1280 × 16-bit reads)
Timing: Must complete before next scanline starts
```

**Note**: Bandwidth reflects 32-bit word reads, but only lower 16 bits contain RGB565 pixel data.
Upper 16 bits are discarded.
Effective bandwidth for pixel data is half of memory bandwidth.

**SDRAM Burst Access**: Display scanout is the primary beneficiary of SDRAM sequential access.
Each scanline is 2560 bytes = 1280 sequential 16-bit SDRAM column reads.
With SDRAM, reading sequential columns within an active row requires only 1 cycle per word after the initial CAS latency (CL=3).
A burst within a single row: ACTIVATE (1 cycle) + tRCD (2 cycles) + READ command (1 cycle) + CL (3 cycles) + N data words = 7 + N cycles.
For a full scanline of 1280 words spanning multiple rows (each row has 512 columns), row changes require PRECHARGE + ACTIVATE overhead (tRP + tRCD = 4 cycles).
A 640-pixel scanline at 32-bit per pixel requires 1280 16-bit accesses spanning approximately 3 SDRAM rows (1280 / 512 = 2.5), incurring ~2 row changes.
Total: ~7 + 1280 + 2 × 4 = ~1295 cycles (vs ~1920 cycles for non-burst 32-bit access).

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
- Adjacent pixels within the same SDRAM row can be combined into a burst write
- Typical burst: 4-16 pixels (8-32 bytes on 16-bit bus)
- Once an SDRAM row is activated, sequential column writes take 1 cycle per word with no CAS latency overhead (write data is presented immediately)
- Row changes within a burst require PRECHARGE + ACTIVATE overhead (tRP + tRCD = 4 cycles)

---

### Texture Fetch (Read)

```
Priority: MEDIUM
Pattern: Burst block reads on cache miss (REQ-131)
Bandwidth: ~5-15 MB/s average (with >85% cache hit rate)
Access: BC1: 8 bytes per cache miss (burst), RGBA4444: 32 bytes per cache miss (burst)
```

**Texture Cache (REQ-131)**: Each sampler has an on-chip 4-way set-associative texture cache (4x1024x18-bit EBR banks).
On cache hit, no SDRAM access is needed.
On cache miss, the full 4x4 block is fetched using a sequential read from SDRAM:
- BC1: 8 bytes = 4 sequential 16-bit reads.
  SDRAM timing: ACTIVATE (1) + tRCD (2) + READ (1) + CL (3) + 4 data = ~11 cycles (all within one row)
- RGBA4444: 32 bytes = 16 sequential 16-bit reads.
  SDRAM timing: ACTIVATE (1) + tRCD (2) + READ (1) + CL (3) + 16 data = ~23 cycles (all within one row)

**Comparison to async SRAM**: The SDRAM CAS latency (CL=3) adds a fixed overhead per burst that did not exist with async SRAM.
However, once the first word arrives, subsequent words stream at 1 word per cycle, identical to the async SRAM burst rate.
The net increase is ~6 cycles per cache miss for the ACTIVATE + tRCD + CL pipeline fill.
For long bursts (RGBA4444, 16 words), this overhead is amortized and the effective throughput approaches the peak bus rate.
End-to-end cache fill latency (including decompression/conversion overlap) is documented in INT-032.

With >85% expected hit rate, average texture SDRAM bandwidth is significantly reduced from a worst-case ~50 MB/s, freeing bandwidth for framebuffer and Z-buffer operations.

---

### Z-Buffer (Read/Write)

```
Priority: LOW
Pattern: Matches rasterization pattern
Bandwidth: ~50 MB/s for read + write (max), reduced with early Z-test
Access: Read-test (early, before texture) + write (late, after all processing)
```

**SDRAM Access Pattern**: Z-buffer accesses follow the rasterization scan order.
When the rasterizer processes consecutive pixels within a scanline, Z-buffer reads and writes can be issued as short sequential accesses (typically 2-8 words) within an active SDRAM row.
However, since Z reads and writes are interleaved with depth test decisions (pass/fail), burst lengths are shorter and less predictable than display scanout or texture cache fills.
The SDRAM row activation overhead (tRCD = 2 cycles) and CAS latency (CL = 3 cycles) apply to each new row.
The primary benefit of sequential access is eliminating per-word re-arbitration overhead for adjacent pixel Z accesses within the same row.

**Z-Buffer Access Sequence** (with early Z-test, v10.0):
1. **Stage 0 (Early)**: Read current Z at (x, y)
2. Compare with incoming Z (using RENDER_MODE.Z_COMPARE function)
3. If test fails: discard fragment immediately (no texture fetch, no color write, no Z write)
4. If test passes: proceed through texture/blend pipeline (Stages 1-5)
5. **Stage 6 (Late)**: If Z_WRITE_EN=1, write new Z value to Z-buffer

**Note**: Z-buffer reads now occur before texture reads in the pipeline (UNIT-006 Stage 0 vs Stage 1+).
This may improve bandwidth utilization: early fragment rejection reduces total SDRAM accesses for texture, framebuffer read (alpha blend), and Z write.
In scenes with high overdraw (3-4x), early Z-test can reduce effective Z+texture+FB bandwidth by 30-50%.
No changes to Z-buffer addresses, sizes, or data format.

---

## Bandwidth Budget

### Theoretical Maximum

```
16-bit × 100 MHz = 200 MB/s peak bus rate
```

SDRAM effective throughput is lower than the peak bus rate due to command overhead:
- **Row activation**: ACTIVATE + tRCD = 3 cycles before the first column access in a new row
- **CAS latency**: CL=3 cycles before the first read data word arrives
- **Auto-refresh**: Each refresh steals ~6 cycles (tRC); with 8192 refreshes per 64 ms, refresh consumes ~0.8% of total bandwidth (~1.6 MB/s)
- **Precharge**: tRP = 2 cycles when switching rows

For long sequential reads within a single row, effective throughput approaches 200 MB/s after the initial CL overhead.
For random single-word accesses (ACTIVATE + tRCD + READ + CL + 1 data + PRECHARGE = ~11 cycles per 16-bit word), effective throughput drops to ~18 MB/s.
Typical GPU access patterns are semi-sequential, yielding effective throughput between these extremes.

### Allocated Budget

| Consumer | Bandwidth (random) | Bandwidth (sequential) | % of Total (seq.) | Notes |
|----------|--------------------|-----------------------|---------------------|-------|
| Display scanout | — | ~50 MB/s | 25% | Long sequential reads, ~2 row changes per scanline |
| Framebuffer write | — | ~40 MB/s | 20% | Short sequential writes (4-16 pixels per row) |
| Z-buffer R/W | ~30 MB/s | ~35 MB/s | 17.5% | Short sequential within rows, some row changes |
| Texture fetch | ~8 MB/s | ~8 MB/s | 4% | Sequential cache fills (REQ-131), >85% hit rate |
| Auto-refresh | ~1.6 MB/s | ~1.6 MB/s | 0.8% | Non-negotiable SDRAM maintenance |
| **Headroom** | — | ~65 MB/s | 32.7% | Available for higher fill rates |

**SDRAM overhead summary**: Compared to async SRAM, SDRAM adds CAS latency (CL=3) and row activation overhead (tRCD=2) per access.
For sequential access patterns (display scanout, cache fills), the overhead is amortized over many words and effective throughput is similar to async SRAM burst mode.
For random access patterns (Z-buffer with scattered fragments), the per-access overhead is higher.
Auto-refresh consumes a small but non-negotiable fraction of bandwidth.

**Note**: Pre-cache texture fetch budget was 30 MB/s (15%).
The per-sampler texture cache (REQ-131) reduces average texture SDRAM bandwidth to ~5-15 MB/s depending on scene complexity and cache hit rate, freeing ~15-25 MB/s for other consumers.

**Clock Domain Note**: Because the GPU core and SDRAM controller share the same 100 MHz clock domain, there is no CDC overhead on any arbiter port.
All requestors (display controller, rasterizer, pixel pipeline, texture cache) issue requests synchronously, and the arbiter can grant access with single-cycle latency after an ack.

### Fill Rate Estimate

At ~90 MB/s effective sequential write bandwidth (GPU core and SDRAM at 100 MHz, accounting for row activation overhead on typical rasterization patterns):
```
90 MB/s ÷ 4 bytes/pixel ≈ 22.5 Mpixels/sec
```

For 640×480 @ 60 Hz (18.4 Mpixels/sec visible):
- Can fill ~122% of screen per frame (>1x overdraw budget)
- Sufficient for complex 3D scenes with moderate overdraw
- Write bandwidth is slightly lower than async SRAM due to SDRAM row activation overhead on non-sequential pixel patterns

---

## SDRAM Controller Timing

### SDRAM Command Encoding

Commands are encoded via the combination of CS#, RAS#, CAS#, WE# signals:

| Command | CS# | RAS# | CAS# | WE# | Description |
|---------|-----|------|------|-----|-------------|
| NOP | 0 | 1 | 1 | 1 | No operation |
| ACTIVATE | 0 | 0 | 1 | 1 | Open row in bank (row address on A[12:0], bank on BA[1:0]) |
| READ | 0 | 1 | 0 | 1 | Read column (column address on A[8:0], A10=auto-precharge) |
| WRITE | 0 | 1 | 0 | 0 | Write column (column address on A[8:0], A10=auto-precharge) |
| PRECHARGE | 0 | 0 | 1 | 0 | Close row (A10=1 for all banks, A10=0 for selected bank) |
| AUTO REFRESH | 0 | 0 | 0 | 1 | Refresh one row (all banks must be idle) |
| LOAD MODE REG | 0 | 0 | 0 | 0 | Set operating parameters (CL, burst length, burst type) |

### Controller Implementation

**Single-Word Read** (burst_len=0):

```
State machine (100 MHz, 10 ns cycle):

READ_SINGLE:
  Cycle 0: ACTIVATE — Open row, drive bank + row address
  Cycle 1-2: Wait tRCD (2 cycles)
  Cycle 3: READ command — Drive column address (low half)
  Cycle 4-5: Wait CL-1 (2 cycles)
  Cycle 6: Latch low 16-bit data
  Cycle 7: READ command — Drive column address (high half)
  Cycle 8-9: Wait CL-1 (2 cycles)
  Cycle 10: Latch high 16-bit data, assemble 32-bit word
  Cycle 11: PRECHARGE
  Total: ~12 cycles for one 32-bit word
```

**Single-Word Write** (burst_len=0):

```
WRITE_SINGLE:
  Cycle 0: ACTIVATE — Open row, drive bank + row address
  Cycle 1-2: Wait tRCD (2 cycles)
  Cycle 3: WRITE command — Drive column address (low half) + data
  Cycle 4: WRITE command — Drive column address (high half) + data
  Cycle 5-6: Wait tWR (2 cycles)
  Cycle 7: PRECHARGE (auto-precharge can be used via A10)
  Total: ~8 cycles for one 32-bit word
```

**Sequential Read** (burst_len>0):

The SDRAM controller reads N sequential 16-bit words within an active row.
The SDRAM mode register is configured for burst length 1 (controller-managed sequential access), with the controller issuing sequential READ commands to consecutive column addresses.

```
SEQUENTIAL_READ (N words, same row):
  Cycle 0: ACTIVATE — Open row
  Cycle 1-2: Wait tRCD (2 cycles)
  Cycle 3: READ command — Column 0
  Cycle 4: READ command — Column 1 (pipelined)
  ...
  Cycle 3+N-1: READ command — Column N-1
  Cycle 6: First data word valid (CL=3 after first READ)
  Cycle 6+N-1: Last data word valid
  Cycle 6+N: PRECHARGE
  Total: ~7 + N cycles for N words (same row)

ROW CHANGE (during sequential access):
  When column address crosses a row boundary (every 512 columns):
  - PRECHARGE current row (1 cycle) + wait tRP (2 cycles)
  - ACTIVATE new row (1 cycle) + wait tRCD (2 cycles)
  - Resume READ commands
  - Overhead: ~5 cycles per row change
```

**Sequential Write** (burst_len>0):

```
SEQUENTIAL_WRITE (N words, same row):
  Cycle 0: ACTIVATE — Open row
  Cycle 1-2: Wait tRCD (2 cycles)
  Cycle 3: WRITE command + data — Column 0
  Cycle 4: WRITE command + data — Column 1
  ...
  Cycle 3+N-1: WRITE command + data — Column N-1
  Cycle 3+N: Wait tWR (2 cycles)
  Cycle 3+N+2: PRECHARGE
  Total: ~6 + N cycles for N words (same row)
```

**Burst Length**: The burst_len signal specifies the number of 16-bit words to transfer (1-255).
A burst_len of 0 selects single-word mode.

**Throughput Comparison** (reading 8 sequential 16-bit words, same row):
- Single-word mode: 8 words x 12 cycles/word = 96 cycles
- Sequential mode: 7 + 8 = 15 cycles (6.4x faster)

**Auto-Refresh Scheduling**: The SDRAM controller must issue AUTO REFRESH commands at a rate of at least 8192 refreshes per 64 ms (one every 781 cycles at 100 MHz).
The controller inserts refresh commands during arbiter idle periods.
If no idle period occurs within the refresh deadline, the controller preempts the current access, issues the refresh, and resumes.
Each AUTO REFRESH takes tRC = 6 cycles.

**Preemption**: The arbiter (UNIT-007) may terminate a sequential access early.
When preempted, the SDRAM controller completes the current 16-bit transfer, issues a PRECHARGE to close the row, and reports the number of words actually transferred.
The requestor is responsible for re-issuing the remaining access from the next address.

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

3. **Pre-loaded SDRAM** (practical for development):
   - Load textures at power-on via test interface
   - Or use RP2350's second core for SDRAM init
   - Note: SDRAM contents are lost on power loss (volatile memory)

**Recommendation for MVP**: Add MEM_ADDR (0x70) and MEM_DATA (0x71) registers for host memory access:

```
MEM_ADDR: Write sets SDRAM address pointer
MEM_DATA: Write stores 32 bits at pointer, auto-increments
          Read returns 32 bits at pointer, auto-increments
```

This allows host to upload textures at ~3 MB/s (limited by SPI).
Note: Unlike SRAM, SDRAM requires initialization before first access (see Initialization Sequence above).
The SDRAM controller handles initialization autonomously after PLL lock.

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

**SDRAM-Specific Constraints:**
- SDRAM contents are volatile and lost on power loss (unlike SRAM)
- Auto-refresh must be maintained continuously; failure to refresh within 64 ms will cause data loss
- The SDRAM controller must complete initialization before any GPU access is permitted
- Bank conflicts (accessing a different row in the same bank) incur PRECHARGE + ACTIVATE overhead
- The 90-degree phase-shifted SDRAM clock requires a PLL output; see INT-002 for PLL configuration

## Notes

Migrated from speckit contract: specs/001-spi-gpu/contracts/memory-map.md.
Updated from async SRAM (v2.0) to synchronous DRAM W9825G6KH (v3.0) in February 2026.
