# Framebuffer Tile Cache and SDRAM Burst Efficiency Analysis

**Date:** 2026-02-22 (revised)
**Scope:** Evaluate framebuffer/Z-buffer caching with 4x4 tile blocks, SDRAM burst efficiency gains, industry precedent, and rasterizer tiled-traversal feasibility.

---

## 1. Executive Summary

Memory bandwidth is the primary performance bottleneck in this GPU design.
The single-ported **16-bit** SDRAM bus at 100 MHz (200 MB/s peak) serves four consumers: display scanout, framebuffer writes, Z-buffer read/write, and texture fetch.

However, the **single largest source of wasted bandwidth** is not a lack of caching — it is the current pixel storage format.
Both the framebuffer (RGB565, 16-bit) and Z-buffer (16-bit depth) store their 16-bit values in the lower half of **32-bit words**, padding the upper 16 bits with zeros.
Since the SDRAM data bus is exactly 16 bits wide, every pixel access requires **two** 16-bit column operations — one for the actual data and one for useless padding.
This wastes **50% of all framebuffer and Z-buffer bandwidth**.

The display controller (`display_controller.sv`) confirms this: it reads bursts of 128 16-bit words to get 64 pixels, using a `burst_word_toggle` to discard every other word.

**Top recommendation: Switch to native 16-bit pixel addressing.**
Packing one RGB565 pixel or one 16-bit Z value per SDRAM column (instead of per 32-bit word) would:
- **Double** effective framebuffer/Z-buffer bandwidth (eliminate 50% waste)
- **Halve** memory footprint (1.2 MB → 600 KB per buffer, freeing ~1.8 MB)
- Require **zero EBR** — purely address calculation and data path changes
- Make burst access twice as efficient (N pixels = N SDRAM words, not 2N)

After fixing the storage format, burst coalescing and tile caching become secondary optimizations that build on a sound foundation.

---

## 2. The 32-Bit Padding Problem

### 2.1 Current Storage Format

Both the framebuffer and Z-buffer use 32-bit word addressing with 16-bit data:

```
Framebuffer word [31:0]:
  [31:16]  = 0x0000   (unused padding)
  [15:11]  = R5       (red, 5 bits)
  [10:5]   = G6       (green, 6 bits)
  [4:0]    = B5       (blue, 5 bits)

Z-buffer word [31:0]:
  [31:16]  = 0x0000   (unused padding)
  [15:0]   = depth    (16-bit unsigned)
```

Each 32-bit word occupies **two** consecutive 16-bit SDRAM columns.
A pixel read requires two column reads; a pixel write requires two column writes.
The second access in each pair transfers zeros.

### 2.2 Impact on Every Consumer

**Display scanout (Port 0):**
- Current: 128 16-bit SDRAM reads per 64-pixel burst (50% wasted)
- `display_controller.sv` line 171: `burst_word_toggle` discards every other word
- Effective bandwidth: 640 x 480 x 2 words x 2 bytes x 60 Hz = **73.7 MB/s** consumed for 36.9 MB/s of pixel data

**Rasterizer framebuffer write (Port 1):**
- Current: 2 SDRAM writes per pixel (low half = RGB565, high half = 0x0000)
- `sdram_controller.sv` single-word write: ACTIVATE + tRCD + WRITE(low) + WRITE(high) + tWR + PRECHARGE = ~10 cycles for 1 pixel

**Z-buffer read/write (Port 2):**
- Current: 2 SDRAM reads per Z-test, 2 SDRAM writes per Z-update
- 4 column operations per fragment that passes Z-test — only 2 carry useful data

**Summary of waste across all consumers:**

| Consumer | Useful data/pixel | SDRAM words/pixel | Waste |
|---|---|---|---|
| Display scanout | 1 x 16-bit | 2 x 16-bit | 50% |
| FB write | 1 x 16-bit | 2 x 16-bit | 50% |
| Z-buffer read | 1 x 16-bit | 2 x 16-bit | 50% |
| Z-buffer write | 1 x 16-bit | 2 x 16-bit | 50% |

### 2.3 Native 16-Bit Pixel Addressing

With native 16-bit addressing, each pixel occupies exactly one SDRAM column:

```
pixel_addr = FB_BASE + (y * 640 + x)    [16-bit word address]
z_addr     = Z_BASE  + (y * 640 + x)    [16-bit word address]
```

**Benefits:**

| Metric | Current (32-bit words) | Proposed (16-bit native) | Improvement |
|---|---|---|---|
| SDRAM ops per pixel read | 2 | 1 | **2x** |
| SDRAM ops per pixel write | 2 | 1 | **2x** |
| Framebuffer size (640x480) | 1,228,800 bytes | 614,400 bytes | **2x smaller** |
| Z-buffer size (640x480) | 1,228,800 bytes | 614,400 bytes | **2x smaller** |
| Display scanout bandwidth | 73.7 MB/s | 36.9 MB/s | **2x** |
| Total memory for double-buf + Z | 3,686,400 bytes | 1,843,200 bytes | **2x smaller** |
| Scanline row span | ~2.5 SDRAM rows | ~1.25 SDRAM rows | Fewer row changes |

**Scanline SDRAM row analysis (native 16-bit):**
- 640 pixels per scanline = 640 x 16-bit SDRAM words
- SDRAM row = 512 columns
- 640 / 512 = **1.25 rows** per scanline (only 1 row change, vs 2 with 32-bit words)
- Row changes during burst scanout drop from ~2 to ~1, saving 5 cycles per scanline

### 2.4 Required Changes

Switching to native 16-bit addressing touches several modules:

1. **Rasterizer (`rasterizer.sv`):** Change address calculation from `base + (y*640 + x) * 4` (32-bit byte address, 2 columns) to `base + (y*640 + x) * 2` (16-bit byte address, 1 column).
   Change fb_wdata from 32-bit `{16'h0, RGB565}` to 16-bit `RGB565`.
   Change zb_wdata from 32-bit `{16'h0, Z16}` to 16-bit `Z16`.
   Use burst_len=0 single-16-bit-word mode or shift to native 16-bit port interface.

2. **SDRAM controller:** Add a **16-bit single-word mode** (burst_len=0 reads/writes a single 16-bit column instead of assembling/splitting 32-bit words).
   The existing burst mode already operates on 16-bit words and needs no change.
   The single-word 32-bit path (two reads/writes with `single_phase`) can be retained for backward compatibility but bypassed for framebuffer/Z-buffer ports.

3. **Arbiter (`sram_arbiter.sv`):** Ports 1 and 2 (framebuffer, Z-buffer) switch from 32-bit single-word to 16-bit single-word or short burst.
   Port data paths narrow from 32-bit to 16-bit for these ports.
   Port 0 (display) already uses burst mode with 16-bit data; it just stops reading 2x the needed words.

4. **Display controller (`display_controller.sv`):** Remove `burst_word_toggle` filtering.
   `burst_len` becomes the actual pixel count (not 2x pixels).
   Address calculation changes from `base + (y*640 + x)` (word address, where each word=2 SDRAM cols) to `base + (y*640 + x)` (each entry = 1 SDRAM col).

5. **Memory map (`INT-011`):** Update base addresses and sizes.
   Total framebuffer memory drops from 3.7 MB to 1.8 MB.
   Texture region can start earlier, freeing more space.

6. **Host driver (`pico-gs-core`):** Update address calculations for pixel upload/download.

**Estimated effort:** Medium — the changes are mechanical (address math, data widths) but touch many files.
No new hardware resources required.

---

## 3. Per-Pixel Access Cost (Corrected)

All cycle counts below reflect the **16-bit SDRAM data bus**.
The "current" column uses the actual 32-bit-word access pattern.
The "native 16-bit" column shows costs after eliminating the padding.

### 3.1 Single-Pixel Access Cycles

**Read (single pixel, row miss):**

| Phase | Current (32-bit word) | Native 16-bit |
|-------|---|---|
| ACTIVATE | 1 | 1 |
| tRCD wait | 2 | 2 |
| READ (col 0) | 1 | 1 |
| CL wait | 2 | 2 |
| Latch low 16-bit | 1 | 1 (done) |
| READ (col 1, padding) | 1 | — |
| CL wait | 2 | — |
| Latch high 16-bit | 1 | — |
| PRECHARGE | 1 | 1 |
| tRP wait | 2 | 2 |
| **Total** | **~14** | **~10** |

**Write (single pixel, row miss):**

| Phase | Current (32-bit word) | Native 16-bit |
|-------|---|---|
| ACTIVATE | 1 | 1 |
| tRCD wait | 2 | 2 |
| WRITE (col 0, data) | 1 | 1 (done) |
| WRITE (col 1, padding) | 1 | — |
| tWR wait | 2 | 2 |
| PRECHARGE | 1 | 1 |
| tRP wait | 2 | 2 |
| **Total** | **~10** | **~9** |

**Read with row already open (same-row sequential):**

| Access | Current | Native 16-bit |
|--------|---------|---------------|
| READ + CL (per pixel) | 2 x (1+3) = 8 | 1 x (1+3) = 4 |

### 3.2 Fragment Pipeline Cycle Budget

For a visible fragment with Z-test enabled (Z-read, Z-test, FB-write, Z-write):

| Operation | Current (row miss) | Native 16-bit (row miss) | Native 16-bit (row hit) |
|---|---|---|---|
| Z-buffer read | ~14 | ~10 | ~4 |
| Z-test (combinational) | 0 | 0 | 0 |
| FB write | ~10 | ~9 | ~1 |
| Z-buffer write | ~10 | ~9 | ~1 |
| **Total** | **~34** | **~28** | **~6** |

With native 16-bit addressing and row-hit (sequential pixels in same SDRAM row), the cost drops to **~6 cycles per visible fragment** — a **5.7x improvement** over the current worst case.

### 3.3 Throughput Estimates

| Configuration | Cycles/fragment | Mpixels/sec (100 MHz) |
|---|---|---|
| Current, row miss (worst) | ~34 | 2.9 |
| Current, semi-sequential | ~20 | 5.0 |
| Native 16-bit, row miss | ~28 | 3.6 |
| Native 16-bit, row hit | ~6 | 16.7 |
| Native 16-bit + burst coalesce (30px span) | ~3.2 avg | 31.3 |

*Burst coalesce estimate: 30 pixels, Z-read burst (36 cyc) + FB-write burst (36 cyc) + Z-write burst (36 cyc) = 108 cyc / 30 pixels / ~1.1 arb overhead = ~3.2 cyc/pixel average.*

---

## 4. SDRAM Burst Efficiency Gains

### 4.1 Burst Access Timing

The SDRAM controller already supports sequential burst mode (burst_len > 0).
Within an active row, sequential 16-bit reads deliver 1 word/cycle after the initial CL pipeline fill.

**Sequential burst read (N x 16-bit words, same row):**
```
Total = ACTIVATE(1) + tRCD(2) + READ(1) + CL(3) + (N-1) pipelined = 6 + N cycles
Effective: N 16-bit words in (6 + N) cycles
```

**Sequential burst write (N x 16-bit words, same row):**
```
Total = ACTIVATE(1) + tRCD(2) + N x WRITE(1 each) + tWR(2) + PRECHARGE(1) + tRP(2) = 8 + N cycles
Effective: N 16-bit words in (8 + N) cycles
```

### 4.2 Efficiency Comparison Table

With native 16-bit addressing, each pixel = 1 SDRAM word:

| Access Pattern | Pixels | SDRAM words | Cycles | MB/s | Efficiency |
|---|---|---|---|---|---|
| Single pixel (current 32-bit) | 1 | 2 | ~14 | 14.3 | 7.1% |
| Single pixel (native 16-bit) | 1 | 1 | ~10 | 10.0 | 5.0% |
| 4-pixel burst (native) | 4 | 4 | ~10 | 80.0 | 40.0% |
| 8-pixel burst (native) | 8 | 8 | ~14 | 114.3 | 57.1% |
| 16-pixel burst (native) | 16 | 16 | ~22 | 145.5 | 72.7% |
| 32-pixel burst (native) | 32 | 32 | ~38 | 168.4 | 84.2% |
| 64-pixel burst (native) | 64 | 64 | ~70 | 182.9 | 91.4% |

*Throughput = pixels x 2 bytes / (cycles x 10 ns). Efficiency = throughput / 200 MB/s peak.*

Key insight: with native 16-bit, a **4-pixel burst already achieves 40% efficiency** (80 MB/s), vs 7.1% for the current single-pixel 32-bit access.

### 4.3 Projected Gains for Rasterization

**Scenario: Typical triangle, 30 pixels wide average, Z-test enabled, native 16-bit.**

Per-scanline span of 30 pixels with Z-read burst + FB-write burst + Z-write burst:

| Method | Z-read | FB-write | Z-write | Total/span | Mpix/sec |
|---|---|---|---|---|---|
| Current (32-bit single-word) | 30 x 14 = 420 | 30 x 10 = 300 | 30 x 10 = 300 | 1020 | 2.9 |
| Native 16-bit single-word | 30 x 10 = 300 | 30 x 9 = 270 | 30 x 9 = 270 | 840 | 3.6 |
| Native 16-bit + burst | 6+30 = 36 | 8+30 = 38 | 8+30 = 38 | 112 | 26.8 |
| **Speedup (burst vs current)** | | | | **9.1x** | |

With native 16-bit burst access, the rasterizer can sustain **~25-30 Mpixels/sec** for medium-sized triangles — enough for >1x overdraw at 640x480@60Hz (18.4 Mpixels/sec visible).

**Realistic sustained rate with arbitration overhead:**
Accounting for display preemption (~12.5% of bandwidth with native 16-bit), refresh (~1%), and arbiter switching:
- Current: ~5-8 Mpixels/sec sustained
- Native 16-bit + burst coalescing: **~20-28 Mpixels/sec** sustained
- Improvement: **~3-4x**

---

## 5. Framebuffer Tile Cache Design

### 5.1 Cache Architecture

A 4x4 tile cache would store small rectangular regions of the framebuffer and Z-buffer on-chip, absorbing read-modify-write patterns and writing back dirty tiles in bursts.

**Tile parameters (with native 16-bit pixels):**
- Tile size: 4x4 pixels = 16 pixels
- Color data per tile: 16 x 16-bit (RGB565) = 256 bits = 32 bytes
- Z-buffer data per tile: 16 x 16-bit = 256 bits = 32 bytes
- Combined per tile: 64 bytes (512 bits)

**Cache geometry options:**

| Config | Lines | Color | Z-buf | Tag | Total EBR | Hit rate (est.) |
|---|---|---|---|---|---|---|
| Direct-mapped, 16 tiles | 16 | 1 | 1 | <1 | 2-3 | 60-70% |
| 2-way, 16 sets (32 tiles) | 32 | 2 | 2 | <1 | 4-5 | 75-85% |
| 4-way, 16 sets (64 tiles) | 64 | 4 | 4 | 1 | 8-9 | 85-92% |
| 4-way, 32 sets (128 tiles) | 128 | 8 | 8 | 1 | 16-17 | 92-96% |

*EBR counts assume ECP5 DP16KD configured as 512x36 or 1024x18.*

### 5.2 EBR Budget Impact

**Current allocation (from REQ-011.02):**

| Component | EBR | Notes |
|---|---|---|
| Texture cache (2 samplers) | 32 | 16 per sampler |
| Dither matrix | 1 | 16x16 blue noise |
| Color grading LUT | 1 | 128-entry RGB |
| Scanline FIFO | 1 | 1024x16 display |
| **Total allocated** | **35** | **of 56 available** |
| **Free** | **21** | |

A combined color+Z framebuffer tile cache (4-way, 16 sets) would consume **8-9 EBR**, leaving only **12-13 EBR free**.
However, **caching only the Z-buffer** (the highest-value target due to its read-test-write pattern) requires only **4-5 EBR**, leaving **16-17 EBR free** — comfortable headroom.

A combined color+Z cache is not justified because framebuffer color writes for opaque geometry are fire-and-forget (no read needed), so a color cache only helps with alpha blending.
A simple write-combining buffer (1 EBR) captures most of the color write benefit.

**Verdict: A Z-only tile cache at 4-5 EBR is the sweet spot.**
It targets the highest-value access pattern (read-modify-write) at an affordable EBR cost.
A combined color+Z cache or larger geometry would only be worthwhile on ECP5-45K (108 EBR) or larger.

### 5.3 Tiled Memory Layout

A tile cache works best with a tiled (Morton/Z-order or block-linear) memory layout, where each 4x4 block occupies contiguous SDRAM addresses.

**Linear layout (current):**
```
Row 0: pixel(0,0) pixel(1,0) pixel(2,0) ... pixel(639,0)
Row 1: pixel(0,1) pixel(1,1) pixel(2,1) ... pixel(639,1)
```
A 4x4 tile spans 4 scanlines x 4 columns.
In linear layout, these 4 scanlines are 640 words apart — potentially in different SDRAM rows.
Loading/evicting a tile requires up to 4 separate row activations, defeating the burst advantage.

**Block-linear (tiled) layout:**
```
Tile(0,0): pixel(0,0) pixel(1,0) pixel(2,0) pixel(3,0)
           pixel(0,1) pixel(1,1) pixel(2,1) pixel(3,1)
           pixel(0,2) pixel(1,2) pixel(2,2) pixel(3,2)
           pixel(0,3) pixel(1,3) pixel(2,3) pixel(3,3)
Tile(1,0): pixel(4,0) pixel(5,0) ...
```
A 4x4 tile of RGB565 = 16 contiguous 16-bit SDRAM words (native addressing).
A burst read/write of one tile: ACTIVATE(1) + tRCD(2) + 16 words + tWR(2) + PRECHARGE(1) + tRP(2) = **24 cycles** for 16 pixels (1.5 cycles/pixel).

**Problem: Display scanout.**
The display controller reads pixels in scanline order (left to right, top to bottom).
With a tiled layout, scanline reads would no longer be contiguous — each 4-pixel group would jump to a different tile's memory region, requiring frequent row changes.
This would **severely degrade** display scanout performance (the highest-priority consumer).

**Mitigation options:**
1. **Detile on writeback:** Keep SDRAM in linear layout, cache internally in tile order.
   Preserves display scanout efficiency but tile load/evict requires 4 separate row-spanning accesses.
2. **Dual layout:** Separate linear display buffer and tiled render target; copy/detile at frame swap.
   Doubles framebuffer memory (still fits in 32 MB with native 16-bit: ~1.2 MB for tiled + linear).
3. **Accept linear layout:** Use tile cache with linear SDRAM layout.
   Benefit is limited to caching the read-modify-write pattern, not burst improvement for tile fill/evict.

**Assessment:** Option 3 (linear + tile cache) is simplest but loses most burst benefit.
Option 1 is moderate complexity.
Option 2 wastes memory and adds a copy step.
None is clearly superior for this hardware.

---

## 6. Industry Precedent: GPU Framebuffer Caches

### 6.1 Tile-Based Deferred Rendering (TBDR)

Modern mobile GPUs (ARM Mali, Imagination PowerVR, Qualcomm Adreno) use **tile-based deferred rendering (TBDR)**, the most extreme form of framebuffer caching.
The entire scene is binned into small tiles (typically 16x16 or 32x32 pixels) and each tile is rendered entirely in on-chip SRAM before being written back to external memory once.

**Key characteristics:**
- On-chip tile buffer holds color + depth + stencil for one tile
- External memory bandwidth for framebuffer reduced to **1 read + 1 write per tile** (or zero reads if the tile is fully covered)
- Requires a geometry binning pass (sort triangles into tiles)
- Significant silicon area and logic for the binning hardware

**Relevance to pico-gs:** TBDR is a full architectural paradigm, not a bolt-on cache.
Retrofitting it onto an immediate-mode renderer would be a fundamental redesign.
However, the **motivation** (reduce external memory bandwidth) is identical.

### 6.2 Immediate-Mode GPUs with Z/Color Caches

Desktop/console GPUs from the late 1990s and 2000s used **small on-chip caches** for Z-buffer and sometimes color buffer:

- **NVIDIA GeForce 256 / GeForce2** (1999-2000): On-chip Z-buffer cache, 4 KB.
  Reduced Z-buffer bandwidth by ~50% for typical scenes.
  Exploited spatial locality from the rasterizer's scanline traversal.

- **ATI Radeon 7200** (2000): HyperZ technology — hierarchical Z-buffer with on-chip cache and Z-buffer compression.
  Reduced Z bandwidth by 2-4x.

- **NVIDIA NV40 / GeForce 6800** (2004): Color compression and Z-buffer caching with 2:1 or 4:1 lossless compression.

- **PowerVR SGX** (2007+): Full TBDR with on-chip parameter buffer and tile color/depth stores.

**Relevance:** Z-buffer caching specifically has strong industry precedent.
The access pattern (read-compare-conditional write for the same pixel) has inherent temporal locality that caches exploit very well.
Color buffer caching has weaker precedent for immediate-mode renderers because writes are typically fire-and-forget (unless alpha blending requires a read-modify-write).

### 6.3 Applicability to pico-gs

| Technique | Industry use | Applicable? | Notes |
|---|---|---|---|
| Full TBDR | Mali, PowerVR, Adreno | No | Requires fundamental architecture change |
| Z-buffer cache | NVIDIA, ATI (1999+) | **Yes** | High reuse, read-test-write pattern |
| Color buffer cache | Desktop GPUs (2000+) | Marginal | Write-only for opaque; RMW for alpha blend |
| Z compression | ATI HyperZ, NVIDIA | Possible | Lossless compression reduces bandwidth |
| Burst coalescing | All modern GPUs | **Yes** | Collect adjacent accesses, issue as burst |
| Native bus-width storage | Universal | **Yes** | Never waste bus cycles on padding |

---

## 7. Rasterizer Tiled Traversal

### 7.1 Current Traversal Order

The rasterizer uses edge-walking in **row-major scanline order**:
```
for y = bbox_min_y to bbox_max_y:
    for x = bbox_min_x to bbox_max_x:
        if inside_triangle(x, y):
            emit_fragment(x, y)
```

This produces fragments in scanline order, which is optimal for the current linear framebuffer layout.

### 7.2 Tiled Traversal (4x4 Blocks)

To maximize tile cache hits, the rasterizer would visit all pixels within a 4x4 tile before moving to the next tile:
```
for tile_y = (bbox_min_y >> 2) to (bbox_max_y >> 2):
    for tile_x = (bbox_min_x >> 2) to (bbox_max_x >> 2):
        for y = tile_y*4 to tile_y*4+3:
            for x = tile_x*4 to tile_x*4+3:
                if inside_triangle(x, y):
                    emit_fragment(x, y)
```

### 7.3 Modification Complexity

**Required changes to `rasterizer.sv`:**

1. **Outer loop restructuring:** Add tile_x, tile_y counters for 4x4 tile iteration.
   The outer loop steps by 4 in both dimensions.
   Moderate complexity — 2 new 8-bit counters, new state transitions.

2. **Edge function management:** The current incremental edge stepping (add A for x+1, add B for y+1) still works within a 4x4 tile.
   At tile boundaries, edge values must jump:
   - Tile step in X: add 4*A to row-start edge values
   - Tile step in Y: add 4*B to tile-row-start edge values
   These require pre-computed 4*A and 4*B values (trivial shift-add of 11-bit values).
   The tile-row-start values need 3 extra 32-bit registers (e0_tile_row, e1_tile_row, e2_tile_row).

3. **State machine expansion:** Current FSM has 16 states.
   Tiled traversal adds ~4 new states: TILE_INIT, TILE_NEXT_X, TILE_NEXT_Y, TILE_ROW_NEXT.
   Moderate complexity.

4. **Bounding box alignment:** Align bounding box to 4x4 tile boundaries (round down min, round up max).
   Trivial — mask lower 2 bits.

**Estimated effort:** ~200-300 lines of SystemVerilog changes.
The edge function math is already correct; only the traversal control logic changes.
No additional multipliers needed.

**Risk:** Medium.
The tiled traversal produces fragments in a different order, which could expose latent bugs in the pixel pipeline if it assumes scanline order.
UNIT-006 (pixel pipeline) processes fragments independently, so ordering should not matter.

### 7.4 Tiled Traversal Without a Tile Cache

Even without a tile cache, tiled traversal can improve burst coalescing.
If the pixel pipeline collects all fragments for a 4x4 tile before issuing SDRAM accesses, it can:
- Issue one burst read for the Z-buffer tile (16 x 16-bit words with native addressing)
- Perform all 16 Z-tests locally
- Issue one burst write for passing color pixels
- Issue one burst write for passing Z updates

This requires only a **small register file** (16 x 16-bit Z values, 16 x 16-bit color values) that can be implemented in distributed RAM (LUTs), not EBR.
Total: 16 x 16 x 2 = 512 bits for Z + 512 bits for color = 1024 bits (~64 LUTs in distributed RAM).

---

## 8. Recommendations (Prioritized)

### 8.1 Priority 1: Native 16-Bit Pixel Addressing (Highest Impact, Zero EBR)

Eliminate the 32-bit word padding.
Store RGB565 and Z16 as single 16-bit SDRAM columns.

**Cost:** 0 EBR, ~200 LUTs of address logic changes across rasterizer, display controller, SDRAM controller, arbiter.
**Benefit:** **2x bandwidth** for all framebuffer and Z-buffer traffic. **2x memory savings.** Fewer SDRAM row changes per scanline.
**Complexity:** Medium — mechanical changes to address calculations and data paths in ~5 modules.
**Risk:** Low — no new hardware mechanisms, just tighter data packing.

### 8.2 Priority 2: Burst Coalescing for FB Color Writes (High Impact, Zero EBR)

Add a small coalescing buffer between rasterizer and SDRAM arbiter.
When the rasterizer emits a run of N adjacent pixels on the same scanline, collect them and issue a single burst write of N x 16-bit words rather than N individual single-word transactions.

**Cost:** 0 EBR, ~100-150 LUTs (small shift register or distributed RAM line buffer).
**Benefit:** FB write bandwidth reduced by ~3-5x for typical triangle widths.
**Complexity:** Low — the SDRAM controller already supports burst mode; the arbiter interface supports burst_len.

### 8.3 Priority 3: Z-Buffer Tile Cache (High Impact, 4-8 EBR)

The Z-buffer has the worst bandwidth profile of any consumer: every visible fragment requires a read-test-write cycle on the same pixel address.
Unlike the framebuffer (write-only for opaque geometry), the Z-buffer exhibits strong temporal locality — overlapping triangles repeatedly hit the same Z values.
This makes it the ideal candidate for on-chip caching, a technique proven by NVIDIA (GeForce 256, 1999) and ATI (HyperZ, Radeon 7200, 2000).

**Recommended geometry: 4-way set-associative, 16 sets, 4x4 tiles.**

Each cache line holds a 4x4 tile of 16-bit Z values (256 bits = 32 bytes).
Total data storage: 64 lines x 32 bytes = 2,048 bytes.
Tag storage: 64 entries x ~12 bits (tile address + valid + dirty) ≈ 96 bytes.

**EBR allocation:**

| Component | Size | EBR count | Configuration |
|---|---|---|---|
| Z data (4 ways) | 4 x 16 sets x 256 bits | 4 | 1024x18 or 512x36 per way |
| Tag + valid + dirty | 64 entries x ~18 bits | <1 | Shared with one data EBR or distributed RAM |
| **Total** | | **4** | |

With a compact implementation, the Z-cache fits in **4 EBR** (not 8 as conservatively estimated earlier), because each 4x4 tile of 16-bit Z values is only 256 bits — a single EBR in 256x36 configuration can hold 16 tiles per way.
A more conservative layout using 1024x18 EBR would use **4-5 EBR**.

**Updated EBR budget:**

| Component | EBR | Notes |
|---|---|---|
| Texture cache (2 samplers) | 32 | Unchanged |
| Dither matrix | 1 | Unchanged |
| Color grading LUT | 1 | Unchanged |
| Scanline FIFO | 1 | Unchanged |
| **Z-buffer tile cache** | **4-5** | **New** |
| **Total allocated** | **39-40** | **of 56 available** |
| **Free** | **16-17** | Comfortable headroom |

**Behavior:**
1. On fragment Z-test: look up the 4x4 tile containing (x, y) in the cache
2. **Hit:** Read Z value from on-chip EBR (1 cycle). Compare. If Z-write enabled, update the cached value and mark the line dirty. **Zero SDRAM traffic.**
3. **Miss:** Evict dirty line (burst write 16 x 16-bit words to SDRAM), then fill new line (burst read 16 x 16-bit words). ~44 cycles total for evict+fill, amortized over up to 16 subsequent hits.
4. **Writeback policy:** Write-back (dirty lines written to SDRAM only on eviction or explicit flush). Flush all dirty lines at frame end (before buffer swap).

**Expected hit rates:**
- Scanline-order rasterization (current): 75-85% (adjacent scanlines often share tile rows)
- Tiled rasterization (Priority 4): 90-95% (all 16 pixels in a tile processed before moving on)
- High-overdraw scenes (3-4x): 85-95% (same tiles hit repeatedly by overlapping triangles)

**Bandwidth reduction:**
With 85% hit rate, Z-buffer SDRAM traffic drops by ~85%.
Current Z-buffer budget is ~35 MB/s (17.5% of bus).
After cache: ~5 MB/s (2.5% of bus), freeing ~30 MB/s for framebuffer writes and texture fetch.

**Cost:** 4-5 EBR, ~300-400 LUTs.
**Benefit:** **5-7x Z-buffer bandwidth reduction.** Eliminates Z as a bandwidth bottleneck.
**Complexity:** Medium-High — cache controller FSM (similar to existing texture_cache.sv), tag management, dirty-line writeback.
The existing texture cache (`texture_cache.sv`) provides a proven reference design for the 4-way set-associative structure, XOR set indexing, and burst fill FSM.

### 8.4 Priority 4: Tiled Rasterizer Traversal (Moderate Impact, Zero EBR)

Modify rasterizer to emit fragments in 4x4 tile order instead of scanline order.
This maximizes Z-cache hit rates (all 16 pixels in a tile processed consecutively before eviction) and enables burst-sized FB write coalescing.

**Cost:** 0 EBR, ~200-250 LUTs.
**Benefit:** Increases Z-cache hit rate from ~80% to ~93%. Enables 16-word FB write bursts per tile.
Combined with Priorities 1-3: **~28-35 Mpixels/sec sustained**.
**Complexity:** Medium — rasterizer FSM changes, new traversal counters, 3 extra 32-bit edge registers.

### 8.5 Priority 5: Single-Tile FB Write Buffer (Low-Moderate Impact, 1 EBR)

Add a 4x4 tile buffer (1 EBR for color) that accumulates framebuffer color fragments and writes back as a 16-word burst on tile change.

**Cost:** 1 EBR (40 -> 41 of 56 budgeted), ~150 LUTs.
**Benefit:** Deferred burst writeback for color buffer, reducing write arbitration overhead.
**Note:** Most beneficial when combined with tiled rasterizer traversal (Priority 4).

### 8.6 Not Recommended

**Full tiled framebuffer layout:** Display scanout penalty outweighs rasterization benefit.
The display controller would need a de-tiling FIFO or scatter-gather reads, adding complexity and EBR.

**Color buffer cache:** For opaque geometry (the common case), FB writes are fire-and-forget with no read-modify-write.
A color cache only helps with alpha blending, which is a secondary use case.
The write buffer (Priority 5) captures most of the write-coalescing benefit at 1 EBR instead of 4-8.

**Full TBDR conversion:** Architectural scope far exceeds the benefit for this project scale.
Would require geometry binning, per-tile triangle lists, and multi-pass rendering — essentially a different GPU.

---

## 9. Quantitative Summary

| Approach | EBR | LUTs | BW improvement | Complexity | Priority |
|---|---|---|---|---|---|
| **Native 16-bit pixel addressing** | **0** | **~200** | **2x all FB/Z traffic** | **Medium** | **1** |
| **FB write burst coalescing** | **0** | **~150** | **3-5x FB writes** | **Low** | **2** |
| **Z-buffer tile cache (4-way, 16 sets)** | **4-5** | **~350** | **5-7x Z traffic** | **Med-High** | **3** |
| Tiled rasterizer traversal | 0 | ~200 | Z-cache 80%→93% hit | Medium | 4 |
| FB write buffer (1 tile) | 1 | ~150 | 1.5-2x FB writes | Medium | 5 |
| Color buffer cache | 4-8 | ~400 | Marginal (opaque) | High | Not recommended |
| Full tiled memory layout | 2-4 | ~300 | Tile burst fill/evict | Medium | Not recommended |
| Full TBDR | 16+ | ~2000+ | 10x+ | Very High | Not recommended |

**Cumulative EBR budget (Priorities 1-5 implemented):**

| Component | EBR |
|---|---|
| Texture cache (2 samplers) | 32 |
| Dither matrix | 1 |
| Color grading LUT | 1 |
| Scanline FIFO | 1 |
| Z-buffer tile cache | 4-5 |
| FB write buffer | 1 |
| **Total** | **40-41 of 56** |
| **Remaining** | **15-16** |

---

## 10. Conclusion

The single most impactful change is **eliminating the 32-bit word padding** that wastes half of all framebuffer and Z-buffer bandwidth.
Both RGB565 color and 16-bit depth are exactly the native width of the 16-bit SDRAM data bus.
Storing them as single 16-bit words instead of padded 32-bit words immediately doubles effective bandwidth, halves memory consumption, and reduces SDRAM row changes — with zero EBR cost.

The second priority is **burst coalescing for FB color writes** — collecting adjacent pixel writes and issuing them as SDRAM bursts rather than individual transactions.
This leverages the existing burst infrastructure at zero EBR cost.

The third priority — and the most important EBR investment — is a **Z-buffer tile cache**.
The Z-buffer's read-test-write access pattern has inherent temporal and spatial locality that a small 4-way set-associative cache exploits efficiently.
At 4-5 EBR (fitting comfortably within the 21 free blocks), a Z-cache reduces Z-buffer SDRAM traffic by **5-7x**, effectively eliminating Z as a bandwidth bottleneck.
This is a well-proven technique: NVIDIA shipped Z-buffer caches in the GeForce 256 (1999) and ATI's HyperZ (Radeon 7200, 2000) demonstrated 2-4x Z bandwidth reduction.
The existing `texture_cache.sv` provides a ready-made reference for the cache controller FSM, set-associative lookup, and burst fill/evict logic.

Together, these three priorities would improve rasterization throughput from the current ~5-8 Mpixels/sec to an estimated **~28-35 Mpixels/sec** — a **4-5x improvement** — using ~5 EBR and ~700 LUTs, leaving 15-16 EBR free for future features.

Tiled rasterizer traversal (Priority 4) further improves Z-cache hit rates from ~80% to ~93%, and a small FB write buffer (Priority 5, 1 EBR) completes the picture by coalescing color writes into tile-sized bursts.
