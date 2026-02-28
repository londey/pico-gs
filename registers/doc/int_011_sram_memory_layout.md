# INT-011: SDRAM Memory Layout

## Type

Internal

## Parties

- **Provider:** External (W9825G6KH-6 SDRAM)
- **Consumer:** UNIT-006 (Pixel Pipeline)
- **Consumer:** UNIT-007 (Memory Arbiter)
- **Consumer:** UNIT-008 (Display Controller)

## Referenced By

- REQ-005.01 (Framebuffer Management) — area 5: Blend/Frame Buffer Store
- REQ-005.02 (Depth Tested Triangle) — area 5: Blend/Frame Buffer Store
- REQ-003.01 (Textured Triangle) — area 3: Texture Samplers
- REQ-005.04 (Enhanced Z-Buffer) — area 5: Blend/Frame Buffer Store
- REQ-005.06 (Framebuffer Format) — area 5: Blend/Frame Buffer Store
- INT-014 (Texture Memory Layout)
- REQ-005.09 (Double-Buffered Rendering) — area 5: Blend/Frame Buffer Store
- REQ-011.01 (Performance Targets) — area 11: System Constraints
- REQ-011.02 (Resource Constraints) — area 11: System Constraints
- REQ-005.07 (Z-Buffer Operations) — area 5: Blend/Frame Buffer Store
- REQ-003.06 (Texture Sampling) — area 3: Texture Samplers
- REQ-002.03 (Rasterization Algorithm) — area 2: Rasterizer
- REQ-006.03 (Color Grading LUT) — area 6: Screen Scan Out

## Specification

## SDRAM Overview

| Parameter | Value |
|-----------|-------|
| Device | Winbond W9825G6KH-6 |
| Total Capacity | 32 MB (256 Mbit) |
| Organization | 4 banks × 8192 rows × 512 columns × 16 bits |
| Data Width | 16 bits |
| Clock Frequency | 100 MHz |
| CAS Latency | 3 cycles (CL=3) |
| Address Range | 0x000000 – 0x1FFFFFF |
| Peak Bandwidth | 200 MB/s (16 bits × 100 MHz) |

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
4. Issue 2× AUTO REFRESH commands (each followed by tRC = 6 cycle wait)
5. Issue LOAD MODE REGISTER: CL=3, burst length=1 (full page burst not used), sequential burst type
6. Wait tMRD (2 cycles)
7. SDRAM is now ready for normal operation

---

## 4×4 Block-Tiled Layout

All color buffers, Z-buffers, and textures use **4×4 block-tiled layout**.
Pixels within each 4×4 block are stored in row-major order; blocks themselves are arranged in row-major order across the surface.
Surface dimensions must be a power of two per axis (non-square surfaces permitted).

Each pixel and each depth value occupies exactly **one 16-bit SDRAM column** (native 16-bit addressing).
This eliminates the storage waste of 32-bit-per-pixel alignment — every SDRAM column transfer carries useful data.

**Block-tiled address calculation** for a pixel at position (x, y) in a surface with `width = 1 << WIDTH_LOG2`:

```
block_x    = x >> 2
block_y    = y >> 2
local_x    = x & 3
local_y    = y & 3
block_idx  = (block_y << (WIDTH_LOG2 - 2)) | block_x
word_addr  = base_word + block_idx * 16 + (local_y * 4 + local_x)
byte_addr  = word_addr * 2
```

Where `base_word` is the surface base address in 16-bit word units (= `BASE_ADDR_BYTES / 2`).

The same formula applies to both color pixels (RGB565) and depth values (Z16).

**Example (512×512 surface):**
- `WIDTH_LOG2 = 9`
- Pixel (8, 4): `block_x=2`, `block_y=1`, `local_x=0`, `local_y=0`, `block_idx = (1 << 7) | 2 = 130`, `word_addr = base + 130*16 + 0 = base + 2080`

---

## Address Space Allocation

```
0x0000000 ┌─────────────────────────────────────────┐
          │                                         │
          │         Framebuffer A (Color)           │
          │         512×512×2 = 524,288 bytes       │
          │                                         │
0x0080000 ├─────────────────────────────────────────┤
          │                                         │
          │         Framebuffer B (Color)           │
          │         512×512×2 = 524,288 bytes       │
          │                                         │
0x0100000 ├─────────────────────────────────────────┤
          │                                         │
          │         Z-Buffer                        │
          │         512×512×2 = 524,288 bytes       │
          │                                         │
0x0180000 ├─────────────────────────────────────────┤
          │                                         │
          │         Texture Memory                  │
          │         ~1.5 MB available               │
          │                                         │
0x0300000 ├─────────────────────────────────────────┤
          │                                         │
          │         Reserved / Free                 │
          │         ~29.0 MB                        │
          │                                         │
0x2000000 └─────────────────────────────────────────┘
```

---

## Detailed Regions

### Framebuffer A (Color)

| Parameter | Value |
|-----------|-------|
| Base Address | 0x000000 |
| End Address | 0x07FFFF |
| Size | 524,288 bytes |
| Pixel Format | RGB565 (16 bits per pixel) |
| Dimensions | 512 × 512 (display uses 512×480; bottom 32 rows unused) |
| Layout | 4×4 block-tiled |
| Bytes per pixel | 2 (one 16-bit SDRAM column) |

**Storage Format** (per pixel):
```
[15:11]   Red (5 bits)
[10:5]    Green (6 bits)
[4:0]     Blue (5 bits)
```

**Address Calculation**: See block-tiled formula above with `WIDTH_LOG2 = 9`.

**4K Alignment**: Base address 0x000000 is naturally 4K aligned.
Register encoding: `COLOR_BASE = 0x0000` (address >> 9).

---

### Framebuffer B (Color)

| Parameter | Value |
|-----------|-------|
| Base Address | 0x080000 |
| End Address | 0x0FFFFF |
| Size | 524,288 bytes |
| Pixel Format | RGB565 (16 bits per pixel) |
| Dimensions | 512 × 512 |
| Layout | 4×4 block-tiled |

**Storage Format**: Same as Framebuffer A (RGB565, 16-bit per pixel).

**4K Alignment**: 0x080000 = 524,288 = 128 × 4096, aligned.
Register encoding: `COLOR_BASE = 0x0400` (address >> 9).

---

### Z-Buffer

| Parameter | Value |
|-----------|-------|
| Base Address | 0x100000 |
| End Address | 0x17FFFF |
| Size | 524,288 bytes |
| Depth Format | 16-bit unsigned (Z16) |
| Dimensions | 512 × 512 |
| Layout | 4×4 block-tiled |
| Bytes per depth value | 2 (one 16-bit SDRAM column) |

**Storage Format** (per depth value):
```
[15:0]    Depth value (0 = near plane, 0xFFFF = far plane)
```

**Address Calculation**: Identical formula to the color buffer, using `Z_BASE` in place of `COLOR_BASE`.

**Note**: Z-buffer accesses are absorbed by the Z-buffer tile cache (4-way, 16 sets, 4×4 tiles) in UNIT-006.
Only cache misses and dirty-line evictions generate SDRAM traffic via the arbiter.

**4K Alignment**: 0x100000 = 1,048,576 = 256 × 4096, aligned.
Register encoding: `Z_BASE = 0x0800` (address >> 9).

---

### Texture Memory

| Parameter | Value |
|-----------|-------|
| Base Address | 0x180000 |
| End Address | 0x2FFFFF |
| Size | 1,572,864 bytes (~1.5 MB) |
| Formats Supported | BC1, BC2, BC3, BC4, RGB565 (tiled), RGBA8888 (tiled), R8 (tiled) |

**Memory layout:** See INT-014 (Texture Memory Layout) for detailed format specifications.
All textures use 4×4 block-tiled layout.

**RGB565 Capacity (16 bpp, tiled):**

| Texture Size | Bytes | Count in 1.5 MB |
|--------------|-------|-----------------|
| 512×512 | 524,288 | 3 |
| 256×256 | 131,072 | 12 |
| 128×128 | 32,768 | 48 |
| 64×64 | 8,192 | 192 |

**BC1 Capacity (4 bpp compressed):**

| Texture Size | Bytes | Count in 1.5 MB |
|--------------|-------|-----------------|
| 1024×1024 | 524,288 | 3 |
| 512×512 | 131,072 | 12 |
| 256×256 | 32,768 | 48 |
| 128×128 | 8,192 | 192 |

**Texture Address Alignment**: Textures must be 512-byte aligned for the TEX_CFG BASE_ADDR register (512-byte granularity).

**Recommended Texture Layout (RGB565, 256×256)**:
```
0x180000  Texture 0 (128 KB)
0x1A0000  Texture 1 (128 KB)
0x1C0000  Texture 2 (128 KB)
0x1E0000  Texture 3 (128 KB)
0x200000  Texture 4 (128 KB)
0x220000  Texture 5 (128 KB)
0x240000  Texture 6 (128 KB)
0x260000  Texture 7 (128 KB)
0x280000  Texture 8 (128 KB)
0x2A0000  Texture 9 (128 KB)
0x2C0000  Texture 10 (128 KB)
0x2E0000  Texture 11 (128 KB)
0x300000  (end of default texture region)
```

---

### Reserved / Free Region

| Parameter | Value |
|-----------|-------|
| Base Address | 0x300000 |
| End Address | 0x1FFFFFF |
| Size | ~29.0 MB |

**Potential Uses**:
- Color grading LUTs
- Additional framebuffers (triple buffering, off-screen render targets)
- Larger texture storage
- Future: vertex buffers, command lists
- Host scratch memory

**Recommended Color Grading LUT Region**:
```
0x300000 ┬─────────────────────────────────────────┐
         │  Color Grading LUTs                     │
         │  (Recommended allocation)               │
0x300000 │  LUT 0 (identity, 4KiB)                 │
0x301000 │  LUT 1 (gamma 2.2, 4KiB)                │
0x302000 │  LUT 2 (warm tint, 4KiB)                │
0x303000 │  LUT 3 (cool tint, 4KiB)                │
0x304000 │  LUT 4 (high contrast, 4KiB)            │
         │  ... (16 LUTs fit in 64KiB)             │
0x310000 ├─────────────────────────────────────────┤
         │  Free / Additional LUTs                 │
         │  ~29.0 MB                               │
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
- LUT auto-load triggered via FB_DISPLAY writes (see INT-010)
- Typical setup: identity, gamma correction, various artistic grades

---

## Memory Access Patterns

### Display Scanout (Read)

```
Priority: HIGHEST
Pattern: Sequential burst reads, tile-by-tile along each source scanline
Source width: 1 << FB_DISPLAY.FB_WIDTH_LOG2 pixels (configurable; see INT-010)
Bandwidth: source_width × 2 × 60 × source_height = variable
  512-wide (WIDTH_LOG2=9), 480 rows:  512 × 2 × 60 × 480 ≈ 29.5 MB/s
  256-wide (WIDTH_LOG2=8), 240 rows:  256 × 2 × 60 × 240 ≈  7.4 MB/s (with LINE_DOUBLE=1)
Access: Burst read, 16 words per 4×4 tile, tiles in row-major order per source scanline
Timing: Must complete before next scanline starts; see tile count calculation below
```

**Configurable Source Width:**
The display controller (UNIT-008) reads `source_width = 1 << FB_DISPLAY.FB_WIDTH_LOG2` RGB565 pixels per source scanline.
After fetching, a Bresenham nearest-neighbor scaler stretches the `source_width` pixels to the 640-pixel DVI output (INT-002, REQ-006.01) without additional SDRAM reads.
The output is always 640×480 regardless of the source surface dimensions.

**4×4 Tile Access**: The display controller reads tiles in row-major order along each source scanline.
For each 4-pixel-wide tile, 16 consecutive 16-bit words are read in a burst from SDRAM.
Each burst fits within a single SDRAM row (16 words = 32 bytes, well within a 512-column row).
SDRAM timing per tile: ACTIVATE (1 cycle) + tRCD (2 cycles) + READ (1 cycle) + CL (3 cycles) + 16 data words = ~23 cycles.

Number of tiles per source scanline = `source_width / 4 = 1 << (FB_WIDTH_LOG2 - 2)`.
- 512-wide source: 128 tiles; total cycles per scanline ≈ 128 × 23 = ~2,944 cycles.
- 256-wide source: 64 tiles; total cycles per scanline ≈ 64 × 23 = ~1,472 cycles.

Available time per scanline at 100 MHz = 3,200 cycles (32 µs × 100 MHz).
FIFO prefetch during blanking keeps scanout ahead of the display beam.

**LINE_DOUBLE Impact:**
When `FB_DISPLAY.LINE_DOUBLE=1`, each source scanline is read from SDRAM only once and output twice (rows `2s` and `2s+1` from the same source row `s`).
This halves display SDRAM reads: 240 source rows × `source_width/4` tiles instead of 480 rows.
For a 256×240 surface with LINE_DOUBLE=1, display bandwidth ≈ 7.4 MB/s — less than one-quarter of the 512-wide reference.

**Scanline Timing**:
- Pixel clock: 25.000 MHz (derived as 4:1 divisor from 100 MHz core clock)
- Pixels per line (total): 800
- Time per line: 32.00 µs
- Visible pixels: 640 (25.6 µs)
- Blanking: 160 pixels (6.4 µs)

---

### Triangle Rasterization (Write)

```
Priority: LOW (yields to display)
Pattern: 4×4 tile order within bounding box; burst writes per tile
Bandwidth: Variable, up to ~28–35 Mpixels/sec (see ARCHITECTURE.md)
Access: Write-coalescing buffer collects pixels within a tile; issues 16-word burst per tile
```

**Write Coalescing**:
- Rasterizer walks the triangle bounding box in 4×4 tile order (aligned with block-tiled layout and Z-cache block size)
- Adjacent pixels within the same tile are collected by the write-coalescing buffer
- A full tile: 16-word burst write, ~22 cycles (ACTIVATE + tRCD + 16 writes + tWR + PRECHARGE)
- A partial tile (edge/corner): shorter burst; cost amortized over tile count, not individual pixels
- Row changes: tiles within the same SDRAM row proceed without PRECHARGE; a new tile column may cross row boundaries (~5 cycle overhead per row change)

---

### Texture Fetch (Read)

```
Priority: MEDIUM
Pattern: Burst block reads on cache miss (REQ-003.08)
Bandwidth: ~5–15 MB/s average (with >90% cache hit rate)
Access: BC1: 4 words per cache miss (burst); RGB565 tiled: 16 words per cache miss (burst)
```

**Texture Cache**: Each of the 2 texture samplers has an on-chip 4-way set-associative texture cache with 16,384 texels.
On cache hit, no SDRAM access is needed.
On cache miss, the full 4×4 block is fetched using a sequential burst read from SDRAM:
- BC1: 4 × 16-bit words = 8 bytes. SDRAM timing: ~11 cycles.
- RGB565 tiled: 16 × 16-bit words = 32 bytes. SDRAM timing: ~23 cycles.
- RGBA8888 tiled: 32 × 16-bit words = 64 bytes. SDRAM timing: ~39 cycles (may cross row boundary).
- R8 tiled: 8 × 16-bit words = 16 bytes. SDRAM timing: ~15 cycles.

End-to-end cache fill latency (including decompression/conversion overlap) is documented in INT-032.

---

### Z-Buffer (Read/Write)

```
Priority: LOW
Pattern: Matches 4×4 tile rasterization order
Bandwidth: Low (tile cache absorbs most traffic)
Access: 16-word burst fill on cache miss; 16-word burst evict on dirty eviction
```

**Z-Buffer Tile Cache**: A 4-way set-associative Z-buffer tile cache (16 sets, 4×4 tiles) in UNIT-006 absorbs Z read/write traffic.
Each cache line holds a 4×4 tile of 16-bit Z values (256 bits = 16 × 16-bit words).
Expected hit rate: 85–95% for typical scenes, reducing Z-buffer SDRAM traffic by 5–7×.

**SDRAM Access Sequence** (cache miss):
1. Dirty line eviction: 16-word burst write to the evicted tile's address (~22 cycles)
2. New line fill: 16-word burst read from the new tile's address (~23 cycles)
3. Total cache miss cost: ~45 cycles, amortized over up to 16 subsequent Z hits

**Z-Buffer Access Sequence** (with early Z-test, per pipeline stage):
1. Stage 0 (Early): Read Z from cache (or trigger miss/fill)
2. Compare with incoming Z (using RENDER_MODE.Z_COMPARE function)
3. If test fails: discard fragment immediately
4. If test passes: proceed through texture/blend pipeline
5. Stage 6 (Late): If Z_WRITE_EN=1, update cache entry (mark dirty)

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
The 4×4 block-tiled layout ensures most accesses are 16-word bursts within a single SDRAM row, keeping effective throughput close to the sequential optimum.

### Allocated Budget

| Consumer | Bandwidth | % of Total | Notes |
|----------|-----------|------------|-------|
| Display scanout | ~30 MB/s (max) | 15% | 16-word tile bursts; 512-wide surface at 60 Hz (LINE_DOUBLE=0) |
| Display scanout | ~7.4 MB/s (min) | 3.7% | 256-wide surface with LINE_DOUBLE=1 at 60 Hz |
| Framebuffer write | ~40 MB/s | 20% | 16-word tile bursts; coalesced writes |
| Z-buffer R/W | ~10 MB/s | 5% | Tile cache absorbs 85–95% of Z traffic |
| Texture fetch | ~5–15 MB/s | 2.5–7.5% | Sequential cache fills; >90% hit rate |
| Auto-refresh | ~1.6 MB/s | 0.8% | Non-negotiable SDRAM maintenance |
| **Headroom** | ~100–115 MB/s | ~51–57% | Available for fill rate, overdraw (at 512-wide reference) |

**Note**: Display scanout bandwidth is proportional to `(1 << FB_WIDTH_LOG2) × source_rows × 2 × 60`.
The 512-wide surface (WIDTH_LOG2=9, 480 rows, LINE_DOUBLE=0) is the reference case (~30 MB/s).
Smaller surfaces or LINE_DOUBLE=1 reduce display bandwidth and free more arbitration time for rendering.
The display controller always stretches the source image to the full 640-pixel DVI output using a Bresenham nearest-neighbor scaler, without additional SDRAM reads (INT-010, INT-002).

### Fill Rate Estimate

With native 16-bit addressing and burst coalescing (ARCHITECTURE.md):
```
~28–35 Mpixels/sec (rasterizer sustained throughput)
```

For 640×480 @ 60 Hz (18.4 Mpixels/sec visible):
- Can fill ~152–190% of screen per frame (>1× overdraw budget)
- Sufficient for complex 3D scenes with moderate overdraw
- Improvement over the 22.5 Mpixels/sec figure of the prior 32-bit-per-pixel layout, because native 16-bit addressing halves framebuffer and Z-buffer SDRAM traffic per pixel

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
READ_SINGLE:
  Cycle 0: ACTIVATE — Open row, drive bank + row address
  Cycle 1-2: Wait tRCD (2 cycles)
  Cycle 3: READ command — Drive column address
  Cycle 4-5: Wait CL-1 (2 cycles)
  Cycle 6: Latch 16-bit data
  Cycle 7: PRECHARGE
  Total: ~8 cycles for one 16-bit word
```

**Single-Word Write** (burst_len=0):

```
WRITE_SINGLE:
  Cycle 0: ACTIVATE — Open row, drive bank + row address
  Cycle 1-2: Wait tRCD (2 cycles)
  Cycle 3: WRITE command — Drive column address + data
  Cycle 4-5: Wait tWR (2 cycles)
  Cycle 6: PRECHARGE
  Total: ~7 cycles for one 16-bit word
```

**Sequential Read** (burst_len>0):

The SDRAM controller reads N sequential 16-bit words within an active row.

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

**Burst Length**: The burst_len signal specifies the number of 16-bit words to transfer (1–255).
A burst_len of 0 selects single-word mode.

**Throughput Comparison** (reading 16 sequential 16-bit words, same row):
- Single-word mode: 16 words × 8 cycles/word = 128 cycles
- Sequential mode: 7 + 16 = 23 cycles (5.6× faster)

**Auto-Refresh Scheduling**: The SDRAM controller must issue AUTO REFRESH commands at a rate of at least 8192 refreshes per 64 ms (one every 781 cycles at 100 MHz).
The controller inserts refresh commands during arbiter idle periods.
If no idle period occurs within the refresh deadline, the controller preempts the current access, issues the refresh, and resumes.
Each AUTO REFRESH takes tRC = 6 cycles.

**Preemption**: The arbiter (UNIT-007) may terminate a sequential access early.
When preempted, the SDRAM controller completes the current 16-bit transfer, issues a PRECHARGE to close the row, and reports the number of words actually transferred.
The requestor is responsible for re-issuing the remaining access from the next address.

---

## Address Encoding in Registers

### FB_CONFIG: COLOR_BASE and Z_BASE

```
Register field value (16-bit): address >> 9
Effective address: value << 9    (512-byte granularity, 32 MiB addressable)

Examples:
  FB_A (0x000000): COLOR_BASE = 0x0000
  FB_B (0x080000): COLOR_BASE = 0x0400
  Z    (0x100000): Z_BASE     = 0x0800
```

### FB_DISPLAY: FB_ADDR and LUT_ADDR

Uses the same 16-bit, 512-byte granularity encoding as COLOR_BASE and Z_BASE.

```
FB_ADDR  [47:32] = address >> 9
LUT_ADDR [31:16] = address >> 9
Effective address: value << 9

Examples:
  FB_A (0x000000): FB_ADDR = 0x0000
  FB_B (0x080000): FB_ADDR = 0x0400
```

### TEXn_CFG: BASE_ADDR

Same 16-bit, 512-byte granularity encoding as FB_DISPLAY.

```
Texture at 0x180000: BASE_ADDR = 0x0C00
```

### MEM_FILL: FILL_BASE

Same 512-byte granularity encoding.

```
FILL_BASE = address >> 9
```

---

## Host Memory Upload

To upload texture data from host:

1. **MEM_ADDR / MEM_DATA registers** (index 0x70 / 0x71):
   - Write MEM_ADDR with the target SDRAM dword address (22-bit, 8-byte dwords)
   - Write MEM_DATA to store 64 bits at that address; address auto-increments by 1
   - Read MEM_DATA to retrieve prefetched 64-bit dword; address auto-increments by 1
   - Transfer rate: ~6 MB/s (64-bit dwords over 62.5 MHz SPI)

2. **Pre-loaded SDRAM** (practical for development):
   - Load textures at power-on via test interface
   - SDRAM contents are lost on power loss (volatile memory)

---

## Alternative Memory Maps

### Single Buffer (Reduced Memory)

For simpler applications without double-buffering:

```
0x000000  Framebuffer (512 KB, 512×512)
0x080000  Z-Buffer    (512 KB, 512×512)
0x100000  Textures    (~30 MB available)
```

Saves 512 KB for larger texture storage.

### Triple Buffer

For lowest latency input response:

```
0x000000  Framebuffer A (512 KB)
0x080000  Framebuffer B (512 KB)
0x100000  Framebuffer C (512 KB)
0x180000  Z-Buffer      (512 KB)
0x200000  Textures      (~30 MB)
```

### Half-Resolution (256×240 with Line Doubling)

```
0x000000  Framebuffer A (256×256 = 128 KB)
0x020000  Framebuffer B (256×256 = 128 KB)
0x040000  Z-Buffer      (256×256 = 128 KB)
0x060000  Textures      (~31.6 MB)
```

Display controller uses `FB_DISPLAY.LINE_DOUBLE=1` (INT-010) to output each source row twice, filling 480 display lines from 240 source rows.
`FB_DISPLAY.FB_WIDTH_LOG2=8` configures the horizontal scaler source width to 256 pixels; the scaler stretches to 640 output pixels (2.5× horizontal scale).
`FB_CONFIG.WIDTH_LOG2=8`, `FB_CONFIG.HEIGHT_LOG2=8` configure the rasterizer stride and scissor for the 256×256 render surface.

---

## Constraints

See specification details above.

**SDRAM-Specific Constraints:**
- SDRAM contents are volatile and lost on power loss (unlike SRAM)
- Auto-refresh must be maintained continuously; failure to refresh within 64 ms will cause data loss
- The SDRAM controller must complete initialization before any GPU access is permitted
- Bank conflicts (accessing a different row in the same bank) incur PRECHARGE + ACTIVATE overhead
- The 90-degree phase-shifted SDRAM clock requires a PLL output; see INT-002 for PLL configuration
- All surface base addresses must be 512-byte aligned (matching the BASE_ADDR register granularity)
- Surface dimensions must be power-of-two per axis for the block-tiled address calculation

## Notes

Migrated from speckit contract: specs/001-spi-gpu/contracts/memory-map.md.
