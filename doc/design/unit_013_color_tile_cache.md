# UNIT-013: Color-Buffer Tile Cache

## Purpose

4-way set-associative write-back color-buffer tile cache with per-tile uninitialized flag tracking.
Sits between UNIT-006 (Pixel Pipeline) and UNIT-007 (Memory Arbiter) port 1, absorbing most framebuffer read/write traffic so that only cache misses and dirty evictions generate SDRAM accesses.
Owns the per-tile uninitialized flag EBR that enables lazy-fill-with-zeros on framebuffer invalidate (REQ-005.08).
Serves both framebuffer writes and alpha-blend destination-color reads (DST_COLOR), eliminating the per-pixel SDRAM round-trip for blended fragments.

## Implements Requirements

- REQ-005.01 (Framebuffer Management) -- color-buffer tile cache absorbs per-pixel SDRAM traffic; burst fill and eviction access the tiled framebuffer layout
- REQ-005.03 (Alpha Blending) -- DST_COLOR reads served from the cache; read-modify-write coherency guaranteed within a single tile because reads and writes share the same cache state
- REQ-005.06 (Framebuffer RGB565 Format) -- cache stores and retrieves native RGB565 values; `fb_promote.sv` (UNIT-006) promotes read data to Q4.12 fixed-point after cache hit
- REQ-005.08 (Clear Framebuffer) -- uninit flag reset (16,384 cycles) resets all per-tile flags so that first-touch writes lazy-fill with zeros without reading SDRAM; this is the color-side analogue of the UNIT-012 Z-buffer fast-clear
- REQ-005.09 (Double-Buffered Rendering) -- driver issues `FB_CACHE_CTRL.FLUSH_TRIGGER` (0x45) before `FB_DISPLAY` swap to guarantee all dirty cached tiles are written back to SDRAM before scan-out begins reading the newly presented buffer
- REQ-011.02 (Resource Constraints) -- 2 DP16KD data blocks + 1 DP16KD uninit flags block + 1–4 PDPW16KD tag blocks within the EBR budget; ~250 LUT4, 0 DSP

## Interfaces

### Provides

None (internal pipeline component).

### Consumes

- INT-011 (SDRAM Memory Layout) -- color framebuffer 4×4 block-tiled addressing for SDRAM fill and eviction bursts

### Internal Interfaces

- **From UNIT-006 (Pixel Pipeline):** Receives color read requests (`rd_req`, `rd_tile_idx`, `rd_pixel_off`) for alpha-blend DST_COLOR and color write requests (`wr_req`, `wr_tile_idx`, `wr_pixel_off`, `wr_data`).
  Returns `rd_valid` + `rd_data` for reads; signals `wr_ready` for writes.
- **To UNIT-007 (Memory Arbiter) port 1:** Issues SDRAM burst reads (16-word tile fill) and burst writes (16-word dirty eviction) via `sdram_rd_req`/`sdram_wr_req` with 24-bit byte addresses.
- **From UNIT-003 (Register File):** Receives `fb_color_base` (color buffer base address, upper bits), `fb_width_log2` (framebuffer width as log2), `fb_cache_flush_trigger` (one-cycle pulse), and `fb_cache_invalidate_trigger` (one-cycle pulse) for tiled address calculation and cache management.
- **To UNIT-003 (Register File):** Asserts `flush_done` (one-cycle pulse) when all dirty lines have been written back to SDRAM; asserts `invalidate_done` (one-cycle pulse) when the uninit flag sweep completes.
  Both signals unblock the SPI command stream at the register file after blocking writes to `FB_CACHE_CTRL` (INT-010, 0x45).
- **Control signals:** `flush` (write-back all dirty lines to SDRAM without invalidating), `invalidate` (drop all valid+dirty bits and trigger uninit sweep, no writeback), `flush_done` (completion pulse for flush), `invalidate_done` (completion pulse for invalidate).

## Clock Domain

Runs at 100 MHz (`clk_core`), the same clock domain as UNIT-006 and UNIT-007.
No CDC logic required.

## Design Description

### Internal State

**Color-value data BRAM (2 × DP16KD):**
Stores 16-bit RGB565 values for all cache lines.
Organization: `NUM_WAYS(4) × NUM_SETS(32) × PIXELS_PER_TILE(16)` = 2,048 entries × 16 bits = 32,768 bits = 2 DP16KD blocks (16,384 bits each).
Dual-port access: Port A for reads (hit pre-read, eviction scan, post-fill read), Port B for writes (fill, lazy-fill, write-update).

**Tag BRAM (4 × PDPW16KD, one per way):**
Each PDPW16KD stores 32 entries of 9-bit tags (one per set) using the 512×36 pseudo dual-port wide mode.
Only 32 of 512 entries are used; tag data occupies bits [8:0].
The 4 separate EBR blocks allow all 4 way tags to be read in parallel in a single cycle.
Tag width is 9 bits: `tile_idx[13:5]` (bits 13 down to 5 of the 14-bit tile index, where bits [4:0] address the set).

**Pseudo-LRU state (FFs):**
3-bit binary tree per set, stored in flip-flops (32 × 3 = 96 FFs).
Tree structure: bit 2 selects left (ways 0,1) vs right (ways 2,3); bit 1 selects way 0 vs 1; bit 0 selects way 2 vs 3.

**Valid/dirty bits (FFs):**
Per-way, per-set valid and dirty flags stored in flip-flops (32 × 4 × 2 = 256 FFs).
Broadcast-cleared on `invalidate`.

**Uninit flag EBR (1 × DP16KD):**
16,384 entries × 1 bit, one flag per 4×4 tile covering the full 512×512 framebuffer surface.
Inferred as a DP16KD in 1×16384 mode (true dual-port, 1-bit data width).
Flag = 1: tile is uninitialized (lazy-fill with 0x0000 on miss, no SDRAM read).
Flag = 0: tile has been written at least once (SDRAM fill on miss).
Port A (read): addressed by `idle_tile_idx` in S_IDLE; result valid in S_TAG_RD (1-cycle BRAM latency).
Port B (write): clear-sweep (write 1 to all 16,384 addresses during `invalidate`) OR bit-clear (write 0 on S_WR_UPDATE when the first write to a tile clears its uninit flag).
These two write sources are mutually exclusive: the pipeline is flushed before any invalidate fires.

**Last-tag cache (single-entry FF cache):**
Stores the set, tag, and way of the most recent access.
Enables a 2-cycle fast-path hit (S_IDLE → S_RD_HIT) for consecutive accesses to the same tile, bypassing the 1-cycle tag EBR read latency.
With 4×4 rasterization order, approximately 94% of accesses hit the last-tag cache.

### Algorithm / Behavior

**Cache lookup (hit):**
1. In S_IDLE, check the last-tag FF cache for a fast-path hit.
   If hit: read BRAM data via Port A (2-cycle latency: S_IDLE → S_RD_HIT for reads, S_IDLE → S_WR_UPDATE for writes).
2. If last-tag misses: initiate tag EBR reads for all 4 ways and uninit flag read (slow path, 3-cycle: S_IDLE → S_TAG_RD → S_RD_HIT or next state).
3. In S_TAG_RD, compare all 4 way tags against the request tag.
   On hit: proceed to S_RD_HIT (read) or S_WR_UPDATE (write).

**Cache miss:**
1. Select a victim way: prefer invalid ways; otherwise use pseudo-LRU.
2. If victim is dirty: enter S_EVICT to write back 16 words to SDRAM via burst write.
3. Check the uninit flag (read in S_TAG_RD):
   - If set (uninitialized tile): enter S_LAZYFILL, write 16 words of `0x0000` to BRAM via Port B (16 cycles, no SDRAM access).
   - If clear (initialized tile): enter S_FILL, issue SDRAM burst read of 16 words, write each received word to BRAM via Port B.
4. After fill completes: update tag EBR, set valid bit, clear dirty bit, update last-tag cache.
5. For reads: enter S_BRAM_RD (1 cycle for BRAM read latency), then output via `rd_valid`/`rd_data`.
   For writes: enter S_WR_UPDATE.

**Color write update (S_WR_UPDATE):**
Write the RGB565 value to BRAM via Port B, set the dirty bit.
Clear the uninit flag for the tile (write 0 to `uninit_flags_mem[req_tile_idx]`).
Update pseudo-LRU and last-tag cache.

**Uninit flag reset sweep:**
Triggered by `invalidate`.
Writes 1 to all 16,384 flag addresses over 16,384 clock cycles (163.84 µs at 100 MHz).
During the sweep, `cache_ready` is deasserted and pixel-pipeline requests are not accepted.
At sweep completion, asserts `invalidate_done` for one cycle to unblock the SPI command stream.
On reset (`rst_n` low), the sweep runs automatically to initialize the flag memory.

**Flush:**
Scans all sets and ways (S_FLUSH_NEXT → S_FLUSH_TAG → S_FLUSH_WB) to find and write back every dirty line to SDRAM.
Dirty bits are cleared; valid bits are retained (lines remain usable after flush).
Pulses `flush_done` when complete to unblock the SPI command stream.

### Tiled Address Calculation

Color-buffer SDRAM addresses use the same 4×4 block-tiled layout as the Z-buffer (INT-011):

```
tile_idx   = (block_y << (fb_width_log2 - 2)) | block_x
byte_addr  = fb_color_base + tile_idx * 32 + pixel_off * 2
```

Both tile index decomposition (set/tag split) and SDRAM burst addressing use only shifts and masks.

The set index occupies `tile_idx[4:0]` (5 bits, 32 sets).
The tag occupies `tile_idx[13:5]` (9 bits).

### FSM States

| State | Encoding | Description |
|-------|----------|-------------|
| S_IDLE | 4'd0 | Idle, accepts new rd/wr requests |
| S_TAG_RD | 4'd8 | Wait 1 cycle for tag EBR and uninit flag read (slow path) |
| S_RD_HIT | 4'd1 | BRAM data ready, output rd_data + rd_valid |
| S_EVICT | 4'd2 | Write back dirty victim line (16-word burst to SDRAM) |
| S_FILL | 4'd3 | Read tile from SDRAM (16-word burst) |
| S_LAZYFILL | 4'd4 | Fill line with 0x0000 (16 cycles, no SDRAM) |
| S_WR_UPDATE | 4'd5 | Write single RGB565 value via BRAM Port B |
| S_WR_FILL_WAIT | 4'd6 | Wait for fill before write |
| S_BRAM_RD | 4'd7 | Wait 1 cycle for BRAM read after fill/lazyfill |
| S_FLUSH_NEXT | 4'd9 | Scan for next dirty line during flush |
| S_FLUSH_TAG | 4'd10 | Wait for tag EBR read during flush |
| S_FLUSH_WB | 4'd11 | Write back dirty line during flush (16-word burst) |

## FPGA Resource Estimate

| Resource | Count | Description |
|----------|-------|-------------|
| DP16KD (data BRAM) | 2 | RGB565 storage: 2,048 × 16-bit (4 ways × 32 sets × 16 pixels) |
| PDPW16KD (tag BRAM) | 4 | Tag storage: 32 × 9-bit per way, 512×36 mode |
| DP16KD (uninit flags) | 1 | 16,384 × 1-bit uninitialized flags |
| **Total EBR** | **7** | 2 data + 4 tag + 1 uninit |
| Flip-flops | ~400 | Valid/dirty (256), LRU (96), FSM + control (~48) |
| LUTs | ~200–300 | Tag comparison, address generation, FSM |
| DSP slices | 0 | No multiply operations |
| Arbiter port | Port 1 | Exclusive ownership of UNIT-007 port 1 |

## Implementation

- `rtl/components/pixel-write/src/color_tile_cache.sv`: Main RTL module (FSM, data BRAM, uninit flag EBR, LRU)
- `rtl/components/pixel-write/src/color_tile_tag_bram.sv`: Tag EBR helper module (PDPW16KD 512×36 wrapper, 32×9-bit tag storage)
- `rtl/components/pixel-write/tests/tb_color_tile_cache.sv`: Verilator testbench for cache behavior
- `twin/components/pixel-write/src/color_cache.rs`: Digital twin color-buffer tile cache (4-way set-associative, pseudo-LRU, lazy-fill, write-back)

## Verification

- **VER-024** (Alpha Blend Modes Golden Image Test) -- exercises DST_COLOR reads through the cache and verifies color-buffer write-back coherency
- `tb_color_tile_cache` (component-level Verilator testbench) -- verifies:
  - Post-reset uninit flag sweep (all 16,384 flags read as 1)
  - First-write-to-tile lazy-fills with zeros (no SDRAM read observed on miss when uninit flag set)
  - Flush write-back: dirty tile burst-written to SDRAM, line stays valid, dirty bit cleared
  - Invalidate: tags drop, uninit flags reset to all-ones, no writeback issued
  - Read-after-write hit: cached pixel returned without SDRAM access
  - Conflict-miss eviction: dirty victim written back, new line filled, last-tag cache updated

## Design Notes

**Arbiter port 1 ownership:** UNIT-013 exclusively owns UNIT-007 arbiter port 1 for all color-buffer SDRAM traffic (fill reads and eviction writes).
UNIT-006 does not issue color-buffer SDRAM requests directly; it delegates all framebuffer access through UNIT-013.

**Relationship to UNIT-006:** UNIT-006 issues color read and color write requests to UNIT-013 and receives responses.
UNIT-006 does not hold any framebuffer tile state internally; UNIT-013 encapsulates the cache, uninit flags, and SDRAM burst protocol.
`fb_promote.sv` remains inside UNIT-006 as the post-cache RGB565→Q4.12 promotion stage; it operates on data returned by UNIT-013 `rd_data`.

**Relationship to UNIT-012:** UNIT-013 mirrors the architecture of UNIT-012 (Z-Buffer Tile Cache) with dimensions scaled down to match color-buffer locality (32 sets vs 128 sets for Z-buffer, 2 data EBR blocks vs 8).
The Hi-Z min-Z feedback path present in UNIT-012 is omitted — it is not relevant to color data.
`invalidate_done` is an additional completion pulse not present in UNIT-012's invalidate path; it is needed because `FB_CACHE_CTRL.INVALIDATE_TRIGGER` writes block the SPI command stream until acknowledged.

**Software flush protocol:** Driver software must issue `FB_CACHE_CTRL.FLUSH_TRIGGER` (INT-010, 0x45) and wait for completion before writing `FB_DISPLAY` or `FB_DISPLAY_SYNC` to swap framebuffers.
The FLUSH operation writes back all dirty cached lines to SDRAM and clears their dirty bits; lines remain valid and continue to absorb post-flush traffic.
Driver software issues `FB_CACHE_CTRL.INVALIDATE_TRIGGER` after retargeting `FB_CONFIG.COLOR_BASE` to a new framebuffer address; INVALIDATE drops all valid and dirty bits and resets the uninit flag array so that subsequent first-touch writes to the new render target lazy-fill with zeros rather than reading stale SDRAM data.

**Lazy-fill value:** Uninitialized tiles fill with `0x0000`, which corresponds to black (RGB565 = 0b00000_000000_00000).
This differs from UNIT-012 where uninitialized Z tiles fill with `0xFFFF` (far plane).
`0x0000` is the natural "no pixel written" sentinel for a color buffer.

**DST_COLOR coherency for alpha blending:** Read-modify-write coherency for alpha-blended fragments is guaranteed within a single cache line because both the DST_COLOR read and the subsequent color write address the same tile index.
The cache services the read hit, advances to S_WR_UPDATE, and writes the blended result back to the same BRAM location in the same cache slot.
No cross-tile ordering hazard exists when the rasterizer walks triangles in 4×4 tile order (self-overlapping blended primitives within a tile are processed strictly in rasterization order by the single-issue pixel pipeline).
