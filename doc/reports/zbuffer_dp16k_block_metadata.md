# Technical Report: Z-Buffer DP16KD Block Metadata

Date: 2026-03-24
Status: Draft

## Background

The pico-gs GPU clears its 512x512 Z-buffer before each frame using the generic MEM_FILL command, which writes 262,144 individual 16-bit words to SDRAM.
This consumes 512 KB of SDRAM bandwidth and takes approximately 2.6 ms per clear at 100 MHz --- a significant fraction of the 16.7 ms frame budget at 60 Hz.

This report investigates using ECP5 DP16KD block RAM to store per-tile metadata (valid bit and truncated minimum Z) that enables two optimizations:

1. **Fast clear** --- bulk-invalidate metadata instead of filling SDRAM, reducing clear time by ~520x.
2. **Hierarchical Z (Hi-Z) rejection** --- reject entire 4x4 tiles at the rasterizer block level before emitting any fragments, saving all downstream pipeline work.

## Scope

**Questions investigated:**

1. What is the current Z-clear cost and how much can block metadata reduce it?
2. How many DP16KD blocks are needed and what is the impact on EBR budget?
3. What bit field layout optimizes the valid/min_z trade-off?
4. Is truncated min_z comparison provably conservative (no false rejections)?
5. How does the metadata integrate with the existing Z-cache and pipeline?

**Out of scope:** Cycle-accurate pipeline scheduling, full RTL implementation, detailed timing closure analysis.

## Investigation

### Sources Examined

- [ARCHITECTURE.md](../../ARCHITECTURE.md) --- EBR budget table (line 325), SDRAM specs (line 266), Z-cache design (line 299)
- [gpu_regs.rdl](../../components/registers/rdl/gpu_regs.rdl) --- MEM_FILL register definition
- [int_010_gpu_register_map.md](../interfaces/int_010_gpu_register_map.md) --- Register map, Z format (line 319)
- [int_011_sram_memory_layout.md](../interfaces/int_011_sram_memory_layout.md) --- Tiled addressing, Z-buffer layout (line 219)
- [early_z.sv](../../components/early-z/rtl/early_z.sv) --- Combinational Z compare + depth range clip
- [components/early-z/twin/src/lib.rs](../../components/early-z/twin/src/lib.rs) --- Authoritative Z-test algorithm
- [components/memory/twin/src/lib.rs](../../components/memory/twin/src/lib.rs) --- Memory model, tiled addressing, MEM_FILL
- [integration/gs-twin/src/lib.rs](../../integration/gs-twin/src/lib.rs) --- Pipeline orchestrator, deferred Z write
- [doc/verification/test_strategy.md](../verification/test_strategy.md) --- Reverse-Z convention (line 29)
- [raster_edge_walk.sv](../../components/rasterizer/rtl/raster_edge_walk.sv) --- Two-level tile/fragment FSM
- [rasterize.rs](../../components/rasterizer/twin/src/rasterize.rs) --- Twin rasterizer with tile-row / tile-pixel hierarchy
- [.claude/skills/ecp5-sv-yosys-verilator/references/ecp5_bram_guide.md](../../.claude/skills/ecp5-sv-yosys-verilator/references/ecp5_bram_guide.md) --- DP16KD width modes

## Findings

### 1. Current Z-Clear Cost

The GPU uses MEM_FILL (register 0x44) to clear the Z-buffer.
MEM_FILL writes a constant 16-bit value to a contiguous SDRAM region:

| Parameter | Value |
|-----------|-------|
| Surface size | 512 x 512 = 262,144 pixels |
| Words written | 262,144 (one u16 per pixel) |
| Bytes written | 524,288 (512 KB) |
| SDRAM clock | 100 MHz, 16-bit bus (W9825G6KH-6) |
| Peak bandwidth | 200 MB/s |

**Cycle estimate:**
SDRAM rows for this device are 256 words (512 bytes) wide.
Sequential fill traverses 1,024 rows.
Per row: tRCD (2 cycles) + 256 data cycles + tRP (2 cycles) = 260 cycles.
Total: 1,024 x 260 = **~266,000 cycles = ~2.66 ms** at 100 MHz.

This is **16% of a 60 Hz frame** (16.7 ms).
During the fill, the SDRAM bus is monopolized, starving display scanout and texture fetches.
In practice, arbitration with display refreshes extends this further.

A double-buffered renderer must clear both color and Z each frame, so the combined MEM_FILL cost is ~5.3 ms (32% of frame budget) before any triangles are drawn.

### 2. DP16KD Sizing

**Block geometry:**

| Parameter | Value |
|-----------|-------|
| Surface | 512 x 512 pixels |
| Tile size | 4 x 4 pixels (matches Z-cache and FB tiling) |
| Tiles per surface | 128 x 128 = 16,384 |

**DP16KD in DATA_WIDTH=36 mode (512 x 36):**
Each DP16KD contains 18,432 bits (18Kbit).
In DATA_WIDTH=36 mode (9-bit address), each block provides 512 addresses x 36 bits = 18,432 usable bits, including the parity bits that narrower modes cannot access.

Each 36-bit word stores **4 packed entries** of 9 bits each (1 valid + 8-bit min_z).
This gives 512 x 4 = 2,048 entries per DP16KD.

**Total:** 16,384 tiles / 2,048 entries per block = **8 DP16KD blocks**.

**Addressing:** The 14-bit tile index is split into three fields:

```
tile_index[13:11]  →  3 bits: select 1 of 8 DP16KDs
tile_index[10:2]   →  9 bits: word address within DP16KD (0..511)
tile_index[1:0]    →  2 bits: select 9-bit slot within 36-bit word
```

The slot selection is handled externally: all 8 DP16KDs read/write full 36-bit words, and a 2-bit mux extracts or inserts the relevant 9-bit field.
This trades narrow per-entry addressing for wider words that recover the parity bits.

### 3. Bit Field Layout

Each metadata entry is 9 bits, packed 4 per 36-bit DP16KD word:

```
Bit 8:    valid    --- 1 = block has been written; 0 = block is cleared
Bits 7:0: min_z    --- Z[15:8] of the farthest surface in this block
```

- min_z is the top 8 bits of the minimum 16-bit Z in the tile (truncated, not rounded).
- 8-bit resolution corresponds to 256 Z-value buckets, each spanning 256 Z values.
- Truncation direction (floor) is critical for conservative correctness (see Section 5).

The 36-bit word layout for 4 consecutive tiles:

```
Bits 35:27  →  entry 3: { valid, min_z[7:0] }
Bits 26:18  →  entry 2: { valid, min_z[7:0] }
Bits 17:9   →  entry 1: { valid, min_z[7:0] }
Bits  8:0   →  entry 0: { valid, min_z[7:0] }
```

This packing uses all 36 bits (32 data + 4 parity) available in DATA_WIDTH=36 mode, recovering the parity bits that narrower modes waste.
The result is 9-bit entries (1 valid + 8-bit min_z) for only 8 EBR --- better precision than a naive 16384x1 approach would achieve at the same EBR cost.

#### Alternatives considered for the valid bit

A sentinel value (e.g. 0x1FF with min_z clamped to 0x0FE) could eliminate the dedicated valid bit, yielding 511 Z buckets in 9 bits.
However, the 8+1 packing is simpler to reason about and implement, and 256 buckets provides ample rejection granularity --- a fragment must be within 256 Z-values of the block minimum to cause a false accept.

### 4. Fast Clear Mechanism

**Principle:** Instead of writing 262,144 words to SDRAM, write the `valid` bit to 0 for all 16,384 metadata entries.
On first access to a cleared block, the Z-cache fills from the known clear value rather than reading SDRAM.

**Clear procedure:**

1. Iterate word addresses 0 through 511, writing a full 36-bit zero word (`valid=0` in all 4 slots) to each DP16KD.
   All 8 DP16KDs share the same address bus and clear in parallel.
2. Record the clear value (e.g. 0x0000 for reverse-Z far plane) in a register.
3. Total: **512 cycles = 5.12 us** at 100 MHz.

**Speedup:** 2,660 us / 5.12 us = **~520x faster** than SDRAM MEM_FILL.
Bandwidth saved: 512 KB of SDRAM writes eliminated per clear.

**Lazy fill on first access:**
When the Z-cache encounters a miss on a block whose `valid=0`:

- Skip the SDRAM burst read.
- Fill the cache line with the stored clear value (all 16 entries = clear_z).
- Mark the metadata `valid=1` and set `min_z = clear_z >> 8`.
- The cache line starts clean (not dirty) since SDRAM is conceptually already at the clear value.

**Write-back consistency:**
When a dirty cache line is evicted, the SDRAM is updated with the actual Z values.
Subsequent cache fills for that (now-valid) block read from SDRAM as normal.
The SDRAM is lazily populated as blocks are first touched --- untouched blocks are never written.

### 5. Hi-Z Rejection

#### Concept

The rasterizer already implements a two-level hierarchical walk (confirmed in `raster_edge_walk.sv` and `rasterize.rs`):

1. **Block level (EW_TILE_TEST):** Test 4x4 tile corners against edge functions; reject entire tile in 1 cycle if no corner is inside.
2. **Fragment level (EW_EDGE_TEST → EW_EMIT):** Iterate 16 pixels within accepted tiles, testing each against edges, then running 3-cycle perspective correction before emitting.

Hi-Z rejection inserts a new test **between these two levels**.
After a tile passes the edge corner test, the rasterizer reads the Hi-Z metadata for that tile and compares the triangle's maximum Z across the tile against the stored min_z.
If the entire tile is provably farther than every previously-written surface, the rasterizer skips the 16-fragment iteration entirely --- no fragments are emitted, and no downstream pipeline work occurs (no texture fetches, no Z-cache reads, no color combine, no framebuffer writes).

```
Tile corner test (existing) ──pass──> Hi-Z metadata read (new, 1 cycle)
                                          │
                              reject ─────┤───── advance to next tile
                                          │
                              accept ─────┘───── iterate 16 fragments (existing)
```

#### Z Convention

This project uses **reverse-Z** (confirmed in `test_strategy.md`, `transforms.py`, all verification scripts):

| Value | Meaning |
|-------|---------|
| 0x0000 | Far plane (cleared background) |
| 0xFFFF | Near plane (closest to camera) |
| Compare function | GEQUAL (fragment_z >= stored_z passes) |

Nearer fragments have **higher** Z values and overwrite farther (lower Z) fragments.

#### What min_z Represents

`min_z` per block is the **minimum** Z value (farthest surface) among all pixels in the 4x4 tile.
With GEQUAL, a fragment passes if `fragment_z >= stored_z`.
If we can prove that even the **nearest** (highest Z) fragment the triangle would produce in this tile is still less than min_z, then all 16 fragments would fail the per-pixel test.
The entire tile can be skipped.

#### Block-Level Z Range Computation

At the tile level, the rasterizer has:
- `Z_origin` --- interpolated Z at the tile's top-left corner (`attr_tcol[ATTR_Z]`, 32-bit with sub-pixel precision, upper 16 bits = u16 Z value)
- `dZ/dx`, `dZ/dy` --- Z derivatives (available from triangle setup)

The Z at each of the 4 tile corners:
```
Z_00 = Z_origin
Z_30 = Z_origin + 3 * dZ/dx
Z_03 = Z_origin + 3 * dZ/dy
Z_33 = Z_origin + 3 * dZ/dx + 3 * dZ/dy
```

The **maximum Z** across the tile (nearest fragment with reverse-Z) is:
```
tile_max_z = max(Z_00, Z_30, Z_03, Z_33)
```

This is conservative: the true maximum over the continuous 4x4 region is bounded by the maximum of the 4 corners for a planar Z function (which it is --- Z is linearly interpolated).

**Cost:** 3 additions (Z_30, Z_03, Z_33 from Z_origin + derivatives) and a 4-way max.
The `3 * dZ/dx` and `3 * dZ/dy` terms can be precomputed once per triangle during setup as `dZ3_dx = dZ/dx + dZ/dx + dZ/dx` (two additions, no multiplier).

#### Truncation Math and Conservative Correctness Proof

Let `tile_max_z` be the 16-bit maximum Z of the triangle across this tile, `stored_min` be the 16-bit minimum Z in the block.

Truncation to 8 bits:
- `tile_max_trunc = tile_max_z >> 8` (integer in 0..255)
- `min_trunc = stored_min >> 8` (integer in 0..255)

**Claim:** If `tile_max_trunc < min_trunc`, then `tile_max_z < stored_min`, and therefore every fragment Z in the tile is less than every stored Z in the block.

**Proof:**

1. `tile_max_z` lies in the interval `[tile_max_trunc * 256, tile_max_trunc * 256 + 255]`.
   Therefore `tile_max_z <= tile_max_trunc * 256 + 255`.

2. `stored_min` lies in `[min_trunc * 256, min_trunc * 256 + 255]`.
   Therefore `stored_min >= min_trunc * 256`.

3. Since `tile_max_trunc < min_trunc`, we have `tile_max_trunc + 1 <= min_trunc` (integers).
   Therefore `(tile_max_trunc + 1) * 256 <= min_trunc * 256`.

4. Combining: `tile_max_z <= tile_max_trunc * 256 + 255 = (tile_max_trunc + 1) * 256 - 1 < (tile_max_trunc + 1) * 256 <= min_trunc * 256 <= stored_min`.

5. Therefore `tile_max_z < stored_min`.
   Since `tile_max_z >= fragment_z` for all fragments in the tile, and `stored_min <= stored_z` for all pixels in the block, every fragment fails GEQUAL against every stored Z.

6. Rejection is correct.
   **QED --- no false rejections.**

**False accepts** (missed rejections) occur when `tile_max_trunc == min_trunc` but `tile_max_z < stored_min`.
This happens when both values fall in the same 256-value bucket.
These tiles proceed to per-fragment iteration and per-pixel Z testing as usual --- correctness is preserved, only an optimization opportunity is missed.

#### Compare Function Compatibility

| Compare | Hi-Z with min_z? | Notes |
|---------|-------------------|-------|
| GEQUAL | Yes | Primary use case. Proven above. |
| GREATER | Yes | Same proof: tile_max < min implies no fragment is > any stored z. |
| LESS | No | Would need max_z to prove tile_min > all stored z. |
| LEQUAL | No | Would need max_z. |
| EQUAL | No | Requires both min and max (range check). |
| NOTEQUAL | No | Cannot reject unless all stored z are known. |
| ALWAYS | No | Never rejects by definition. |
| NEVER | Trivial | Always rejects; Hi-Z not needed. |

Since this project exclusively uses GEQUAL (reverse-Z), min_z is the correct choice.
If LESS/LEQUAL support is ever needed, a second metadata field (max_z) could be added.

### 6. Integration with Rasterizer and Z-Cache

#### Rasterizer Integration

The edge walker FSM (`raster_edge_walk.sv`) currently transitions:

```
EW_TILE_TEST ──pass──> EW_EDGE_TEST ──inside──> EW_BRAM_READ ──> EW_PERSP_1 ──> EW_PERSP_2 ──> EW_EMIT
```

With Hi-Z, a new state is inserted:

```
EW_TILE_TEST ──pass──> EW_HIZ_TEST (new) ──accept──> EW_EDGE_TEST ──> ...
                                          │
                                reject ───┘──> EW_TILE_NEXT (advance tile)
```

**EW_HIZ_TEST** (1 cycle):
- Address the Hi-Z metadata RAM with the tile index (`tile_col | tile_row << 7`, 14 bits).
- The DP16KD read was initiated during EW_TILE_TEST (address available as soon as tile coordinates are known), so the result is ready by the time EW_HIZ_TEST executes --- **zero additional latency** on the critical path.
- The 36-bit word is read from the selected DP16KD; a 2-bit mux extracts the 9-bit entry for this tile.
- Compare `tile_max_z_trunc` (precomputed from corner Z values) against `min_z[7:0]` from metadata.
- If `valid && tile_max_trunc < min_trunc`: reject tile, advance to next tile.
- Otherwise: proceed to EW_EDGE_TEST as normal.
- The `valid` bit (inverted: `cleared` flag) is forwarded with emitted fragments so the Z-cache can skip SDRAM reads for cleared blocks and fill from the stored clear value instead (lazy fill).

**Impact per rejected tile:** Saves up to 16 * (1 edge test + 3 perspective cycles + 1 emit) = **80 cycles** of rasterizer work, plus all downstream pixel pipeline work (early-Z cache access, texture fetch, color combine, framebuffer write) for every fragment that would have been emitted.

#### Z-Cache Integration (Update Path)

The Hi-Z metadata is **read** in the rasterizer but **written** from the pixel pipeline's Z-write stage.
The min_z metadata must be updated when:

1. **Z-buffer write:** After a fragment passes all tests and writes its Z value, update the block's min_z if the new value is less than the stored min_z.
   - Read metadata, compare, conditionally write --- 1 read + 1 conditional write per fragment.
   - Can be pipelined with the Z-cache write.

2. **Cache line eviction:** When a dirty cache line is evicted, the 16 Z values are written to SDRAM.
   - Optionally recompute min_z from the 16 values for maximum precision.
   - Or maintain min_z incrementally (may drift conservative but never incorrect).

3. **Fast clear:** Bulk-write valid=0 (see Section 4).

#### DP16KD Port Allocation

The metadata RAM is read by the rasterizer and written by the pixel pipeline --- two independent pipeline stages.
DP16KD is true dual-port: port A and port B can independently read or write.

- **Port A (read-only):** Rasterizer Hi-Z queries.
  Reads the 36-bit word; a mux extracts the target 9-bit entry.
- **Port B (write-only):** Pixel pipeline min_z updates and fast clear.
  Updates require a read-modify-write of the full 36-bit word (read on cycle N, modify the target 9-bit slot, write back on cycle N+1).
  During fast clear, Port B writes full 36-bit zero words (all 4 slots cleared), iterating 512 addresses.

This gives a clean separation: the rasterizer only reads (Port A) and the pixel pipeline only writes (Port B).
During fast clear, the pipeline is stalled and Port A is idle; Port B handles the clear sweep.

#### Pipeline Timing

The metadata RAM read (DP16KD, `REGMODE="NOREG"`) has 1-cycle latency.
The tile address is known at the start of EW_TILE_TEST, so the metadata read can be **launched speculatively** during the tile corner test.
By the time the corner test completes (1 cycle), the metadata is already available --- the Hi-Z compare is effectively free on the critical path.

If the tile fails the corner test, the speculative metadata read is simply discarded.

### 7. EBR Budget Impact

From ARCHITECTURE.md (line 337):

| | Current | With Hi-Z metadata |
|---|---|---|
| Total EBR used | 28--29 | 36--37 |
| EBR available (ECP5-25K) | 56 | 56 |
| Utilization | 50--52% | 64--66% |
| Remaining headroom | 27--28 | 19--20 |

The +8 EBR cost is significant but leaves 19--20 blocks of headroom (34--36%).
This is well within the ECP5-25K budget and leaves room for future additions.

By using DATA_WIDTH=36 mode and packing 4 x 9-bit entries per word, each DP16KD's parity bits are recovered --- achieving 9-bit entries (1 valid + 8-bit min_z) at the same 8 EBR cost that a naive 16384x1 approach would spend on only 8-bit entries.

### 8. Digital Twin Modeling

The gs-twin currently models Z-buffer operations as direct SDRAM reads/writes through `GpuMemory` ([components/memory/twin/src/lib.rs](../../components/memory/twin/src/lib.rs)).
The rasterizer twin (`rasterize.rs`) walks tiles in `scan_tile_row()`, then iterates pixels within accepted tiles via `init_tile_pixels()`.
There is no cache model --- the twin is transaction-level, not cycle-accurate.

**Required changes to model Hi-Z metadata:**

1. **New state in `GpuMemory`:** A `[u8; 16384]` array storing per-block metadata (valid + min_z), plus a `z_clear_value: u16` register.

2. **New `z_fast_clear` method:** Set all valid bits to 0 and store the clear value.
   This replaces the 262,144-word `fill()` call for Z-buffer clears.

3. **New `hiz_test_tile` method on `GpuMemory`:** Given a tile index and tile_max_z (u16), return `(reject: bool, cleared: bool)`.
   Implements: `reject = valid && (tile_max_z >> 8) < min_z`; `cleared = !valid`.
   The `cleared` flag is passed downstream so the Z-cache can lazy-fill without re-reading metadata.

4. **Modified rasterizer twin (`rasterize.rs`):** In `scan_tile_row()`, after the tile passes the edge corner test, compute tile_max_z from the 4 corner Z values and call `hiz_test_tile()`.
   If rejected, skip `init_tile_pixels()` for that tile entirely.
   This is the primary integration point --- the rasterizer decides whether to emit fragments for a tile.

5. **Modified `write_tiled` for Z-buffer:** After writing the Z value, update the block's min_z if the new value is lower than the stored truncated minimum.
   Set `valid=1`.

6. **Modified `read_tiled` for Z-buffer:** If `valid=0`, return `z_clear_value` instead of reading SDRAM (modeling lazy fill).

7. **Golden image tests:** Output images must be bit-identical before and after Hi-Z.
   Any pixel difference indicates a bug in the Hi-Z logic (false rejection).

### 9. RTL Implementation Sketch

#### New Module: `hiz_metadata.sv`

```
module hiz_metadata (
    input  logic        clk,
    input  logic        rst_n,

    // Fast clear interface
    input  logic        clear_start,      // Pulse to begin fast clear
    output logic        clear_busy,       // High during clear sweep
    input  logic [15:0] clear_value,      // Z value for cleared blocks

    // Query interface (rasterizer block level, port A read)
    input  logic [13:0] query_addr,       // Tile index (tile_col | tile_row << 7)
    input  logic [15:0] query_tile_max_z, // max Z of triangle across this tile
    output logic        query_reject,     // 1 = entire tile rejected
    output logic        query_valid,      // 1 = tile has been written

    // Update interface (pixel pipeline Z-write stage, port B)
    input  logic        update_en,
    input  logic [13:0] update_addr,
    input  logic [15:0] update_z,         // New Z value written to tile
    input  logic        update_valid      // Set valid on first write
);
```

**DP16KD instantiation:** 8 instances in DATA_WIDTH=36 mode (512 x 36), each storing 2,048 entries packed as 4 x 9-bit slots per 36-bit word.
The upper 3 bits of the tile index (`tile_index[13:11]`) select which DP16KD to address; the middle 9 bits (`tile_index[10:2]`) form the word address; the low 2 bits (`tile_index[1:0]`) select the 9-bit slot within the 36-bit word via an external mux.

**Clear FSM:** A 9-bit counter iterates 0..511, writing 36'b0 to all words via Port B.
All 8 DP16KDs share the same address bus and clear in parallel.
At 1 address per cycle, completes in **512 cycles**.
During clear, the pipeline is stalled (same as current MEM_FILL behavior, just much faster).

**Port A (query, read-only):** Reads the 36-bit word at `query_addr[10:2]` from the selected DP16KD (`query_addr[13:11]`).
A 2-bit mux extracts the 9-bit entry for `query_addr[1:0]`.
Outputs `query_reject = valid && (tile_max_z[15:8] < min_z[7:0])` and `query_cleared = !valid`.
1-cycle read latency; the read is launched speculatively during EW_TILE_TEST so the result is ready with zero added latency.

**Port B (update + clear, write-only):** During normal operation, reads the 36-bit word (Port B read), replaces the target 9-bit slot if `update_z[15:8] < current_min_z[7:0]` and sets `valid=1`, then writes the modified word back.
Read-modify-write requires 2 cycles (read on cycle N, write on cycle N+1).
During fast clear, Port B writes full 36-bit zero words without the read phase.

#### Rasterizer Changes (`raster_edge_walk.sv`)

Minimal FSM modification:

1. **Triangle setup:** Precompute `dZ3_dx = 3 * dZ/dx` and `dZ3_dy = 3 * dZ/dy` (two additions each, no multiplier).

2. **EW_TILE_TEST:** Speculatively issue metadata read for the current tile address.
   Compute 4 corner Z values and 4-way max (`tile_max_z`).

3. **New state EW_HIZ_TEST** (or combined into tile test if metadata read completes in time):
   Compare `tile_max_z[15:8]` against metadata `min_z[7:0]`.
   If rejected: transition to next tile (EW_TILE_NEXT).
   If accepted or metadata invalid or Hi-Z disabled: transition to EW_EDGE_TEST.
   Forward the `cleared` flag (inverted valid bit) with emitted fragments for Z-cache lazy fill.

4. **Fragment bus:** No changes.
   `frag_tile_start` / `frag_tile_end` signals are simply never asserted for rejected tiles.

### 10. Verification Strategy

1. **Digital twin golden tests:** Implement Hi-Z in the twin, run all existing golden image tests (`cargo test -p gs-twin`).
   Bit-identical output confirms no false rejections.

2. **Unit test: conservative correctness:** Exhaustive test of all 256 x 256 (8-bit) truncated value pairs confirming that `frag_trunc < min_trunc` implies `frag_full < min_full` for all possible full-precision values within each bucket.

3. **Unit test: clear-then-draw:** Clear metadata, draw a single triangle, verify that:
   - First access to each block returns the clear value.
   - After write, valid=1 and min_z reflects the written Z.
   - Subsequent reads return the actual stored Z (not the clear value).

4. **Unit test: min_z tracking:** Draw multiple overlapping triangles with varying Z.
   Verify min_z is always <= the true minimum Z in each block (conservative invariant).

5. **Integration test: Hi-Z rejection count:** Instrument the twin to count Hi-Z rejections.
   Render a depth-sorted scene and verify the rejection rate is non-trivial (validates the optimization is actually effective).

6. **RTL vs twin comparison:** Run the same test vectors through both Verilator and the twin, compare pass/fail decisions per fragment.

### 11. Risks and Alternatives

#### Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Read-modify-write hazard on metadata update | Medium | Port B handles all writes; 2-cycle RMW (read 36-bit word, modify target 9-bit slot, write back) with 1-cycle bubble |
| Cross-pipeline signaling (rasterizer reads, pixel pipeline writes) | Medium | DP16KD dual-port eliminates structural hazards; metadata staleness (pixel pipeline writes not yet visible to rasterizer) is safe because stale min_z is conservative (lower than actual), never causing false rejections |
| Clear FSM stalls pipeline for ~5 us | Low | 512 cycles at 100 MHz; pipeline stall during clear is negligible (same as current MEM_FILL behavior, just ~520x faster) |
| min_z drift (never recomputed from actual block contents) | Low | min_z can only decrease (become more conservative), never causing false rejections; recompute on eviction if tighter bounds desired |
| Corner Z computation adds rasterizer logic | Low | Only 3 additions + 4-way max; dZ3_dx/dZ3_dy precomputed once per triangle; no multipliers needed |
| Compare function change mid-frame | Low | Hi-Z only activates for GEQUAL/GREATER; other functions bypass Hi-Z and proceed to fragment iteration |
| Non-power-of-two surfaces | N/A | Not supported; all surfaces are power-of-two (width_log2, height_log2 in FB_CONFIG) |

#### Alternatives Considered

1. **SDRAM-backed metadata (no EBR cost):** Store metadata in SDRAM instead of DP16KD.
   Rejected: adds SDRAM traffic to every fragment, defeating the purpose.
   The whole point is that metadata reads are on-chip with 1-cycle latency.

2. **Distributed RAM instead of DP16KD:** 16,384 bits of metadata could fit in LUT-based distributed RAM (~128 LUTs for the valid bits alone).
   Rejected: distributed RAM is asynchronous and harder to pipeline; DP16KD is synchronous, dual-ported, and does not consume LUTs.

3. **Larger tiles (8x8 instead of 4x4):** Would reduce metadata entries to 4,096 (only 2 EBR in 4096x1 mode).
   Rejected: 8x8 tiles misalign with the existing 4x4 cache line size and tiled memory layout.
   Larger tiles also reduce Hi-Z effectiveness (more diverse Z values per tile = weaker rejection).

4. **Store max_z instead of (or in addition to) min_z:** Would enable Hi-Z for LESS/LEQUAL compare functions.
   Not needed: project uses exclusively GEQUAL.
   Could be added later if standard-Z support is required (+8 more EBR).

5. **No truncation (full 16-bit min_z):** Would require 17 EBR (16 for min_z + 1 for valid), consuming 30% of remaining headroom.
   Rejected: truncation loses very little rejection effectiveness and saves 8--9 EBR.

6. **DP16KD in 16384x1 mode (8 EBR parallel):** 8 DP16KDs each providing 1 bit, addressed by the same 14-bit address.
   Provides 8 bits per entry (1 valid + 7-bit min_z) but wastes the parity bits (only 16,384 of 18,432 bits used per block).
   Fast clear requires iterating all 16,384 addresses (164 us) instead of 512 addresses (5 us).
   Rejected: DATA_WIDTH=36 mode recovers the parity bits for 9-bit entries at the same 8 EBR cost, with 32x faster clear.

7. **9-bit sentinel value instead of dedicated valid bit:** Reserve one 9-bit value (e.g. 0x1FF with min_z clamped to 0x1FE) to encode "cleared", yielding 511 Z buckets in 9 bits without a separate valid bit.
   Viable but adds clamping logic and is harder to reason about correctness.
   Rejected in favor of the simpler 8+1 packing (1 valid + 8-bit min_z = 9 bits), which provides 256 buckets --- sufficient for the rejection granularity needed.

## Conclusions

1. **The current Z-clear costs ~2.66 ms** (16% of frame budget), consuming 512 KB of SDRAM bandwidth.
   With block metadata fast-clear, this drops to **~5.12 us** (<0.1% of frame budget) --- a **~520x improvement**.

2. **8 DP16KD blocks** in DATA_WIDTH=36 mode provide 9 bits of metadata per 4x4 tile (1 valid + 8-bit truncated min_z) for the full 512x512 surface, packed 4 entries per 36-bit word.
   This recovers the parity bits that narrower modes waste, achieving 9-bit entries at 8 EBR cost.
   EBR usage rises from 28--29 to 36--37 of 56 available (64--66% utilization), leaving comfortable headroom.

3. **Hi-Z rejection with truncated min_z is provably conservative** --- the truncation-floor property ensures that `tile_max_trunc < min_trunc` implies `tile_max_z < stored_min` for all possible full-precision values.
   No false rejections can occur.

4. **Block-level rejection in the rasterizer is the right placement.**
   The existing two-level tile/fragment hierarchy in the edge walker provides a natural insertion point between EW_TILE_TEST and EW_EDGE_TEST.
   A rejected tile saves up to 80 rasterizer cycles (16 fragments x 5 cycles each) **plus** all downstream pixel pipeline work per fragment (Z-cache, texture fetch, color combine, framebuffer write).
   This is far more impactful than per-fragment rejection in the pixel pipeline, which would only save the Z-cache lookup.

5. **The metadata read is effectively free on the critical path.**
   The tile address is known at the start of EW_TILE_TEST; launching the DP16KD read speculatively during the corner test means the result is ready by the time the corner test completes.

6. **The port split is clean:** Port A is read-only for Hi-Z queries (rasterizer), Port B is write-only for updates and clear (pixel pipeline).
   The Hi-Z step reads the `valid` bit and forwards a `cleared` flag downstream, so the Z-cache can lazy-fill without re-reading metadata.

7. **Digital twin changes are straightforward:** A per-block metadata array in `GpuMemory`, a Hi-Z gate in the rasterizer's `scan_tile_row()` before `init_tile_pixels()`, lazy-fill on cleared blocks, and min_z updates on Z writes.
   Golden images remain bit-identical since Hi-Z only rejects tiles whose fragments would all fail the per-pixel test anyway.

## Recommendations

- Implement Hi-Z metadata in the digital twin first (rasterizer + memory model), confirm golden image stability, then proceed to RTL.
- Use `/syskit-impact` to analyze specification changes needed across UNIT-005 (rasterizer), UNIT-006 (pixel pipeline / Z-write update path), REQ-005.07 (Z-buffer operations), REQ-005.08 (clear framebuffer), and INT-011 (memory layout).
- Consider whether the clear FSM should be triggered by a new dedicated register or by detecting a Z-buffer-targeted MEM_FILL and intercepting it.
- Benchmark Hi-Z rejection rates on the existing golden test scenes (especially VER-011 depth-tested triangles and VER-014 textured cube) to quantify the savings before committing to RTL.
