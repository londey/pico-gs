# UNIT-005.06: Hi-Z Block Metadata

## Purpose

Per-tile metadata store that enables two Z-buffer optimizations: fast clear (bulk-invalidating metadata in 512 cycles instead of filling SDRAM in ~266,000 cycles) and hierarchical Z (Hi-Z) tile rejection (rejecting entire 4x4 tiles in the rasterizer before any fragments are emitted).
Sub-unit of UNIT-005 (Rasterizer).

The store uses 8 DP16KD blocks in 36x512 mode, holding 16,384 metadata entries (one per 4x4 tile in a 512x512 surface).
Each 9-bit entry contains a 1-bit valid flag and an 8-bit truncated minimum Z (`min_z = tile_min_Z[15:8]`).
Entries are packed 4 per 36-bit word.

## Implements Requirements

- REQ-005.07 (Z-Buffer Operations) -- Hi-Z metadata maintenance on Z-write and tile-level pre-rejection
- REQ-005.08 (Clear Framebuffer) -- fast-clear mechanism that bulk-invalidates Hi-Z metadata instead of filling SDRAM
- REQ-011.02 (Resource Constraints) -- 8 DP16KD blocks within the 39-block EBR budget

## Interfaces

### Provides

None

### Consumes

None

### Internal Interfaces

- **Read port (Port A):** Consumed by UNIT-005.05 (Iteration FSM, HIZ_TEST state).
  The rasterizer supplies a 14-bit tile index; the store returns the 9-bit metadata entry (`valid`, `min_z[7:0]`) with 1-cycle read latency.
  The read is launched speculatively during TILE_TEST so the result is available with zero additional latency on the critical path.
- **Write port (Port B):** Consumed by UNIT-006 (Pixel Pipeline, Z-write side-effect).
  On each Z-buffer write where `Z_WRITE_EN=1` and the fragment passes the depth test, the pixel pipeline issues an update: if the written depth `new_z[15:8]` is less than the stored `min_z` (or `valid=0`), the entry is updated with `valid=1` and `min_z = new_z[15:8]`.
  Port B is also used for the fast-clear sweep.
- **Fast-clear trigger:** Initiated when a Z-buffer MEM_FILL command is detected (REQ-005.08).
  The clear signal stalls the rendering pipeline while the 512-cycle sweep runs.

## Design Description

### Metadata Layout

Each metadata entry is 9 bits:

```
Bit 8:    valid   -- 1 = tile has been written; 0 = tile is cleared (invalid)
Bits 7:0: min_z   -- Z[15:8] of the minimum Z value written to this tile (truncated floor)
```

Four entries are packed per 36-bit DP16KD word:

```
Bits 35:27  ->  entry 3: { valid, min_z[7:0] }
Bits 26:18  ->  entry 2: { valid, min_z[7:0] }
Bits 17:9   ->  entry 1: { valid, min_z[7:0] }
Bits  8:0   ->  entry 0: { valid, min_z[7:0] }
```

This packing uses all 36 bits available in DATA_WIDTH=36 mode (32 data + 4 parity), recovering the parity bits that narrower modes waste.

### Addressing

The 14-bit tile index is split into three fields:

```
tile_index[13:11]  ->  3 bits: block select (1 of 8 DP16KDs)
tile_index[10:2]   ->  9 bits: word address within the selected DP16KD (0..511)
tile_index[1:0]    ->  2 bits: slot select within the 36-bit word (0..3)
```

The tile index is computed from tile coordinates as: `tile_index = (tile_row << tile_cols_log2) | tile_col`, where `tile_cols_log2 = FB_CONFIG.WIDTH_LOG2 - 2`.

All 8 DP16KDs share the same address bus.
Block selection is handled by routing the read/write enable to the selected block based on `tile_index[13:11]`.
Slot selection is handled externally: the full 36-bit word is read/written, and a 2-bit mux extracts or inserts the relevant 9-bit field.

### Capacity

| Parameter | Value |
|-----------|-------|
| Surface size | 512 x 512 pixels (maximum) |
| Tile size | 4 x 4 pixels |
| Total tiles | 128 x 128 = 16,384 |
| Entries per DP16KD | 512 words x 4 entries/word = 2,048 |
| DP16KD blocks required | 16,384 / 2,048 = 8 |
| DP16KD mode | DATA_WIDTH=36 (36 x 512) |

### Fast Clear

When a Z-buffer clear is issued (MEM_FILL with fill value 0xFFFF targeting the Z-buffer region, per REQ-005.08), the fast-clear mechanism bulk-invalidates all metadata entries:

1. A 9-bit counter iterates addresses 0 through 511.
2. At each address, Port B writes a full 36-bit zero word (`valid=0` in all 4 slots) to all 8 DP16KDs in parallel.
3. Total: **512 cycles = 5.12 us** at 100 MHz.
4. The rendering pipeline is stalled during the clear sweep.

This replaces the ~266,000-cycle SDRAM MEM_FILL for the Z-buffer, a ~520x improvement (REQ-005.08).

### Lazy Fill

After a fast clear, tiles with `valid=0` are handled by the lazy-fill protocol:

- **HIZ_TEST (UNIT-005.05):** A cleared tile (`valid=0`) unconditionally passes the Hi-Z test -- the tile is never rejected.
  The `valid=0` (cleared) status is forwarded with emitted fragments so downstream consumers know the tile has not been initialized.
- **Z-cache (UNIT-006):** On first access to a cleared tile, the Z-cache fills the cache line with the far-plane depth value (0xFFFF) instead of reading SDRAM.
  The cache line starts clean (not dirty) since SDRAM is conceptually already at the clear value.
- **First Z-write (UNIT-006):** When `Z_WRITE_EN=1` and a fragment passes the depth test in a cleared tile, the metadata is initialized with `valid=1` and `min_z = new_z[15:8]`.

This contract ensures that any tile not yet written after a clear behaves as if its Z-buffer contents are 0xFFFF (far plane), preserving functional correctness (REQ-005.08).

### Read Port (Hi-Z Query)

The read port is used by UNIT-005.05 (Iteration FSM) during the HIZ_TEST state:

1. The rasterizer supplies the 14-bit tile index.
2. The DP16KD read is launched speculatively during TILE_TEST (the tile address is known as soon as tile coordinates are established).
3. By the time the tile corner test completes (1 cycle), the 36-bit word is available from the selected DP16KD.
4. A 2-bit mux extracts the 9-bit entry for `tile_index[1:0]`.
5. The result `{valid, min_z[7:0]}` is used for the Hi-Z rejection decision.

**Rejection condition (UNIT-005.05):** If `valid=1` and `fragment_Z[15:8] > min_z`, reject the entire tile.
The comparison is conservative: because `min_z` stores the truncated floor of the tile minimum Z, the stored value never exceeds the true minimum, so no visible fragment is incorrectly rejected.
See `doc/reports/zbuffer_dp16k_block_metadata.md` for the formal conservativeness proof.

**Port A** is read-only during normal operation and idle during fast clear.

### Write Port (Metadata Update)

The write port is used by UNIT-006 (Pixel Pipeline) to maintain metadata on Z-buffer writes:

1. When `Z_WRITE_EN=1` and a fragment passes the depth test, the pixel pipeline issues an update with the tile index and the written Z value.
2. Port B performs a read-modify-write of the 36-bit word:
   - Cycle N: Read the 36-bit word at the target address.
   - Cycle N+1: Extract the target 9-bit slot; if `new_z[15:8] < stored_min_z` or `valid=0`, replace the slot with `{1'b1, new_z[15:8]}`; write the modified 36-bit word back.
3. The read-modify-write takes 2 cycles per update.

**Port B** handles both metadata updates (normal operation) and fast-clear sweeps.
During fast clear, Port B writes full 36-bit zero words without the read phase.

### DP16KD Port Allocation

| Port | User | Mode | When |
|------|------|------|------|
| Port A | Rasterizer (UNIT-005.05) | Read-only | Normal operation (Hi-Z queries) |
| Port B | Pixel pipeline (UNIT-006) | Read-modify-write | Normal operation (min_z updates) |
| Port B | Clear FSM | Write-only | Fast-clear sweep (512 cycles) |

DP16KD is true dual-port: Port A and Port B can independently access the same block.
This gives a clean separation: the rasterizer only reads and the pixel pipeline only writes.
Metadata staleness (pixel pipeline writes not yet visible to the rasterizer for the same tile) is safe because stale `min_z` is always conservative (lower than or equal to actual), never causing false rejections.

## Implementation

- `components/rasterizer/rtl/raster_hiz_meta.sv`: Hi-Z block metadata store -- 8 DP16KD instantiations in 36x512 mode, address decode, slot mux, fast-clear FSM, read port (Port A) for rasterizer Hi-Z queries, write port (Port B) for pixel pipeline min_z updates.
- `shared/gs-twin-core/src/hiz.rs`: Digital twin — `HizMetadata` struct (new/invalidate_all/read/update) modeling the 16,384-entry metadata store; shared by rasterizer (read) and pixel-write (update).
- `components/pixel-write/rtl/pixel_pipeline.sv`: RTL — drives Hi-Z metadata write port (hiz_wr_en, hiz_wr_tile_index, hiz_wr_new_z_hi) on Z-buffer write cycles.
- `components/pixel-write/twin/src/lib.rs`: Digital twin — Hi-Z metadata update on Z-write (write port consumer).
- `integration/gs-twin/src/lib.rs`: Digital twin orchestrator — wires `HizMetadata` through the rasterizer (Hi-Z rejection) and pixel-write (metadata update) call sites; invalidates metadata on Z-buffer MEM_FILL.
- `components/rasterizer/rtl/rasterizer.sv`: RTL — instantiates `raster_hiz_meta`, wires read port to `raster_edge_walk` and exposes Hi-Z write/clear ports to `gpu_top`.
- `integration/gpu_top.sv`: RTL — routes Hi-Z write signals from `pixel_pipeline` to `rasterizer`; detects Z-buffer MEM_FILL to generate `hiz_clear_req`; stalls command FIFO during `hiz_clear_busy`.

## Verification

Covered by UNIT-005 verification (VER-001, VER-011).

Key verification points for this sub-unit:

- **Fast-clear completeness:** After the 512-cycle metadata invalidation pass, confirm all `valid` bits read as 0 for all 16,384 entries.
- **Lazy-fill on cleared tile:** When `valid=0`, confirm the Hi-Z test passes unconditionally (tile is not rejected) and the cleared status is forwarded to downstream consumers.
- **First-write initialization:** On the first Z-write to a cleared tile, confirm the metadata is set to `valid=1` with `min_z = new_z[15:8]`.
- **Conditional min update:** When `valid=1` and `new_z[15:8] < stored_min_z`, confirm `min_z` is updated.
  When `new_z[15:8] >= stored_min_z`, confirm `min_z` is unchanged.
- **Hi-Z rejection:** For a tile with `valid=1` and `fragment_Z[15:8] > stored_min_z`, confirm the tile is rejected (no fragments emitted).
- **Hi-Z conservatism:** For a tile where `fragment_Z[15:8] == stored_min_z`, confirm the tile is not rejected.
- **Hi-Z bypass:** When `Z_TEST_EN=0`, confirm the Hi-Z metadata is not consulted and all tiles proceed to edge testing.
- **Read-modify-write correctness:** Confirm that updating one 9-bit slot within a 36-bit word does not corrupt the other three slots.
- **Addressing correctness:** For tile indices spanning all 8 DP16KD blocks and all 4 slots per word, confirm correct block selection, word addressing, and slot extraction.

## Design Notes

**EBR budget impact:** The 8 DP16KD blocks increase total EBR usage from 28-29 to 36-37 of 56 available (64-66% utilization), remaining within the 39-block budget (REQ-011.02).
See `doc/reports/zbuffer_dp16k_block_metadata.md` for the full sizing and addressing analysis.

**Conservative truncation:** The 8-bit `min_z` stores the floor of `tile_min_Z / 256`.
A stored value of N represents a real tile minimum Z in [256*N, 256*N+255].
False accepts (missed rejections) occur only when the incoming Z and stored min_z fall in the same 256-value bucket -- these tiles proceed to per-fragment testing as usual with no correctness impact.

**min_z monotonicity:** The `min_z` field can only decrease over the lifetime of a tile (between clears).
It is never recomputed from the actual tile contents; it tracks the running minimum of all Z-writes.
This guarantees the stored value is always less than or equal to the true tile minimum, preserving the conservative invariant.

**No multipliers:** The metadata store requires no DSP resources.
All operations are reads, writes, comparisons, and bitfield extraction.
