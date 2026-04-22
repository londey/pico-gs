# UNIT-012: Z-Buffer Tile Cache

## Purpose

4-way set-associative write-back Z-buffer tile cache with per-tile uninitialized flag tracking.
Sits between UNIT-006 (Pixel Pipeline) and UNIT-007 (Memory Arbiter) port 2, absorbing most Z-buffer read/write traffic so that only cache misses and dirty evictions generate SDRAM accesses.
Owns the per-tile uninitialized flag EBR that enables lazy-fill on Z-buffer clear (REQ-005.08).
Reports tile minimum-Z feedback to UNIT-005.06 (Hi-Z Block Metadata) on eviction and on consecutive-write tile completion.

## Implements Requirements

- REQ-005.07 (Z-Buffer Operations) -- Z-buffer tile cache, lazy-fill on uninitialized tiles, uninit flag clear on first Z-write
- REQ-005.08 (Clear Framebuffer) -- uninit flag reset sweep (512 cycles) on Z-buffer clear, lazy-fill contract (uninitialized tiles supply 0xFFFF)
- REQ-011.02 (Resource Constraints) -- 1 DP16KD uninit flag block within the 39-block EBR budget; 8 DP16KD data BRAM blocks; 4 PDPW16KD tag BRAM blocks

## Interfaces

### Provides

None (internal pipeline component).

### Consumes

- INT-011 (SDRAM Memory Layout) -- Z-buffer 4x4 block-tiled addressing for SDRAM fill and eviction bursts

### Internal Interfaces

- **From UNIT-006 (Pixel Pipeline):** Receives Z-read requests (`rd_req`, `rd_tile_idx`, `rd_pixel_off`) and Z-write requests (`wr_req`, `wr_tile_idx`, `wr_pixel_off`, `wr_data`).
  Returns `rd_valid` + `rd_data` for reads; signals `wr_ready` for writes.
- **To UNIT-007 (Memory Arbiter) port 2:** Issues SDRAM burst reads (16-word tile fill) and burst writes (16-word dirty eviction) via `sdram_rd_req`/`sdram_wr_req` with 24-bit byte addresses.
- **To UNIT-005.06 (Hi-Z Block Metadata):** Reports tile minimum-Z feedback via `hiz_fb_valid`, `hiz_fb_tile_idx`, `hiz_fb_min_z_hi` (upper 8 bits of tile min Z).
  Feedback is generated on two occasions: (1) dirty line eviction (actual minimum computed during the 16-word writeback scan), and (2) consecutive-write tile completion (16 writes to the same tile without intervening accesses to other tiles).
- **From UNIT-003 (Register File):** Receives `fb_z_base` (Z-buffer base address, upper bits) and `fb_width_log2` (framebuffer width as log2) for tiled address calculation.
- **Control signals:** `invalidate` (clear all valid+dirty bits and trigger uninit sweep), `uninit_clear_req` (trigger 512-cycle uninit flag sweep only), `flush` (write-back all dirty lines to SDRAM), `flush_done` (completion pulse).

## Clock Domain

Runs at 100 MHz (`clk_core`), the same clock domain as UNIT-006 and UNIT-007.
No CDC logic required.

## Design Description

### Internal State

**Z-value data BRAM (8 DP16KD blocks):**
Stores 16-bit Z values for all cache lines.
Organization: `NUM_WAYS(4) x NUM_SETS(128) x PIXELS_PER_TILE(16)` = 8,192 entries x 16 bits = 131,072 bits = 8 DP16KD blocks (16,384 bits each).
Dual-port access: Port A for reads (hit pre-read, eviction scan, post-fill read), Port B for writes (fill, lazy-fill, write-update).

**Tag BRAM (4 x PDPW16KD, one per way):**
Each PDPW16KD stores 128 entries of 7-bit tags (one per set) using the 512x36 pseudo dual-port wide mode.
Only 128 of 512 entries are used; tag data occupies bits [6:0].
The 4 separate EBR blocks allow all 4 way tags to be read in parallel in a single cycle.
See `zbuf_tag_bram.sv` for the ECP5-specific primitive instantiation.

**Pseudo-LRU state (FFs):**
3-bit binary tree per set, stored in flip-flops (128 x 3 = 384 FFs).
Tree structure: bit 2 selects left (ways 0,1) vs right (ways 2,3); bit 1 selects way 0 vs 1; bit 0 selects way 2 vs 3.

**Valid/dirty bits (FFs):**
Per-way, per-set valid and dirty flags stored in flip-flops (128 x 4 x 2 = 1,024 FFs).
Broadcast-cleared on `invalidate`.

**Uninit flag EBR (1 DP16KD):**
16,384 entries x 1 bit, one flag per 4x4 tile.
Inferred as a DP16KD in 1x16384 mode (true dual-port, 1-bit data width).
Flag = 1: tile is uninitialized (lazy-fill with 0xFFFF on miss, no SDRAM read).
Flag = 0: tile has been written at least once (SDRAM fill on miss).
Port A (read): addressed by `idle_tile_idx` in S_IDLE; result valid in S_TAG_RD (1-cycle BRAM latency).
Port B (write): clear-sweep (write 1 to all 16,384 addresses) OR bit-clear (write 0 on S_WR_UPDATE).
These two write sources are mutually exclusive because the pipeline is flushed before any clear command fires.

**Last-tag cache (single-entry FF cache):**
Stores the set, tag, and way of the most recent access.
Enables a 2-cycle fast-path hit (S_IDLE -> S_RD_HIT) for consecutive accesses to the same tile, bypassing the 1-cycle tag EBR read latency.
With 4x4 rasterization order, approximately 94% of accesses hit the last-tag cache.

### Algorithm / Behavior

**Cache lookup (hit):**
1. In S_IDLE, check the last-tag FF cache for a fast-path hit.
   If hit: read BRAM data via Port A (2-cycle latency: S_IDLE -> S_RD_HIT for reads, S_IDLE -> S_WR_UPDATE for writes).
2. If last-tag misses: initiate tag EBR reads for all 4 ways and uninit flag read (slow path, 3-cycle: S_IDLE -> S_TAG_RD -> S_RD_HIT or next state).
3. In S_TAG_RD, compare all 4 way tags against the request tag.
   On hit: proceed to S_RD_HIT (read) or S_WR_UPDATE (write).

**Cache miss:**
1. Select a victim way: prefer invalid ways; otherwise use pseudo-LRU.
2. If victim is dirty: enter S_EVICT to write back 16 words to SDRAM via burst write.
   During eviction, compute the tile's minimum Z (running min across 16 words) for Hi-Z feedback.
   On eviction completion, pulse `hiz_fb_valid` with the evicted tile's index and min-Z upper 8 bits.
3. Check the uninit flag (read in S_TAG_RD):
   - If set (uninitialized tile): enter S_LAZYFILL, write 16 words of `0x0000` to BRAM via Port B (16 cycles, no SDRAM access).
   - If clear (initialized tile): enter S_FILL, issue SDRAM burst read of 16 words, write each received word to BRAM via Port B.
4. After fill completes: update tag EBR, set valid bit, clear dirty bit, update last-tag cache.
5. For reads: enter S_BRAM_RD (1 cycle for BRAM read latency), then output via `rd_valid`/`rd_data`.
   For writes: enter S_WR_UPDATE.

**Z-write update (S_WR_UPDATE):**
Write the Z value to BRAM via Port B, set the dirty bit.
Clear the uninit flag for the tile (write 0 to `uninit_flags_mem[req_tile_idx]`).
Update pseudo-LRU and last-tag cache.
Track consecutive writes to the same tile; after 16 consecutive writes, pulse `hiz_fb_valid` with the tile min-Z.

**Uninit flag reset sweep:**
Triggered by `invalidate` or `uninit_clear_req`.
Writes 1 to all 16,384 flag addresses over 16,384 clock cycles (164 us at 100 MHz).
During the sweep, `cache_ready` is deasserted and Z requests are not accepted.
On reset (`rst_n` low), the sweep runs automatically to initialize the flag memory.

**Flush:**
Scans all sets and ways (S_FLUSH_NEXT -> S_FLUSH_TAG -> S_FLUSH_WB) to find and write back every dirty line.
Pulses `flush_done` when complete.

### Tiled Address Calculation

Z-buffer SDRAM addresses use the same 4x4 block-tiled layout as the framebuffer (INT-011):

```
tile_idx   = (block_y << (fb_width_log2 - 2)) | block_x
byte_addr  = fb_z_base + tile_idx * 32 + pixel_off * 2
```

Both tile index decomposition (set/tag split) and SDRAM burst addressing use only shifts and masks.

### FSM States

| State | Encoding | Description |
|-------|----------|-------------|
| S_IDLE | 4'd0 | Idle, accepts new rd/wr requests |
| S_TAG_RD | 4'd8 | Wait 1 cycle for tag EBR and uninit flag read (slow path) |
| S_RD_HIT | 4'd1 | BRAM data ready, output rd_data + rd_valid |
| S_EVICT | 4'd2 | Write back dirty victim line (16-word burst to SDRAM) |
| S_FILL | 4'd3 | Read tile from SDRAM (16-word burst) |
| S_LAZYFILL | 4'd4 | Fill line with 0x0000 (16 cycles, no SDRAM) |
| S_WR_UPDATE | 4'd5 | Write single Z value via BRAM Port B |
| S_WR_FILL_WAIT | 4'd6 | Wait for fill before write |
| S_BRAM_RD | 4'd7 | Wait 1 cycle for BRAM read after fill/lazyfill |
| S_FLUSH_NEXT | 4'd9 | Scan for next dirty line during flush |
| S_FLUSH_TAG | 4'd10 | Wait for tag EBR read during flush |
| S_FLUSH_WB | 4'd11 | Write back dirty line during flush (16-word burst) |

## FPGA Resource Estimate

| Resource | Count | Description |
|----------|-------|-------------|
| DP16KD (data BRAM) | 8 | Z-value storage: 8,192 x 16-bit |
| PDPW16KD (tag BRAM) | 4 | Tag storage: 128 x 7-bit per way, 512x36 mode |
| DP16KD (uninit flags) | 1 | 16,384 x 1-bit uninitialized flags |
| **Total EBR** | **13** | 8 data + 4 tag + 1 uninit |
| Flip-flops | ~1,500 | Valid/dirty (1,024), LRU (384), FSM + control (~100) |
| LUTs | ~800-1,200 | Tag comparison, address generation, FSM, min-Z tracking |
| DSP slices | 0 | No multiply operations |
| Arbiter port | Port 2 | Exclusive ownership of UNIT-007 port 2 |

## Implementation

- `rtl/components/zbuf/src/zbuf_tile_cache.sv`: Main RTL module (FSM, data BRAM, uninit flag EBR, LRU, Hi-Z feedback)
- `rtl/components/zbuf/src/zbuf_tag_bram.sv`: Tag EBR helper module (PDPW16KD 512x36 wrapper, 128x7-bit tag storage)
- `rtl/components/zbuf/tests/tb_zbuf_uninit_flags.sv`: Verilator testbench for uninit flag behavior (reset sweep, lazy-fill, bit-clear, re-sweep)
- `twin/components/zbuf/src/lib.rs`: Digital twin crate root (`gs-zbuf`), re-exports `ZbufTileCache` and `UninittedFlagArray`
- `twin/components/zbuf/src/zbuf_cache.rs`: Digital twin Z-buffer tile cache (4-way set-associative, pseudo-LRU, lazy-fill, write-back)
- `twin/components/zbuf/src/uninit_flags.rs`: Digital twin per-tile uninitialized flag array
- `rtl/components/pixel-write/tests/tb_pixel_pipeline_uninit_flags.sv`: Verilator testbench for pixel pipeline uninit flag EBR behavior

## Verification

- **VER-011** (Depth-Tested Overlapping Triangles Golden Image Test) -- exercises Z-buffer read/write, uninitialized flag lazy-fill, and Hi-Z metadata update through the full pipeline
- `tb_zbuf_uninit_flags` (component-level Verilator testbench) -- verifies uninit flag EBR: reset sweep sets all flags, lazy-fill on miss with flag set, bit-clear on Z-write, re-sweep restores all flags

## Design Notes

**Arbiter port 2 ownership:** UNIT-012 exclusively owns UNIT-007 arbiter port 2 for all Z-buffer SDRAM traffic (fill reads and eviction writes).
UNIT-006 does not issue Z-buffer SDRAM requests directly; it delegates all Z-buffer access through UNIT-012.

**Hi-Z feedback channel:** The cache reports tile minimum-Z to UNIT-005.06 on two occasions:
(1) Dirty line eviction: the actual minimum across the 16 Z values is computed during the writeback scan (running-min register, no additional BRAM reads).
(2) Consecutive-write tile completion: when 16 writes to the same tile complete without intervening accesses to other tiles, the running minimum is reported.
The feedback uses the upper 8 bits of the 16-bit minimum (`min_z[15:8]`), matching the UNIT-005.06 metadata granularity.

**Lazy-fill value discrepancy:** The RTL fills uninitialized tiles with `0x0000` in the BRAM (S_LAZYFILL writes zeros), but returns `0xFFFF` as the effective Z value to the requesting pipeline stage on the read path.
The digital twin (`zbuf_cache.rs`) currently lazy-fills with `0x0000` and returns `0x0000`.
This discrepancy is pre-existing and documented here for future resolution; it does not affect golden image tests because Z-buffer clears precede rendering and the first Z-write to each tile initializes the actual value.

**Relationship to UNIT-006:** UNIT-006 issues Z-read and Z-write requests to UNIT-012 and receives responses.
UNIT-006 does not hold any Z-buffer state internally; UNIT-012 encapsulates the cache, uninit flags, and SDRAM burst protocol.

**Relationship to UNIT-005.06:** The Hi-Z feedback channel is a unidirectional path from UNIT-012 to UNIT-005.06.
UNIT-012 does not read Hi-Z metadata; it only writes updates when eviction or consecutive-write completion provides a computed tile minimum.
