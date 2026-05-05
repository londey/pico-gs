# UNIT-011.03: Index Cache

## Purpose

Per-sampler direct-mapped cache storing 8-bit palette indices at half the apparent texture resolution.
One DP16KD EBR per sampler provides single-cycle index access on cache hit.
On miss, issues an SDRAM burst read (8 × 16-bit words = 16 bytes per 4×4 index block) via arbiter port 3 and streams the burst directly into the EBR — one EBR write per arriving SDRAM word — then resumes the stalled fragment.
The cache asserts `fill_busy_o` for the duration of the burst; the parent texture sampler blocks all lookup issue while busy, so lookups and fills never overlap.
Tag and valid bit flop together on the cycle after the terminal SDRAM word lands, making the new line atomically visible to the next lookup.

## Implements Requirements

- REQ-003.08 (Texture Cache) — per-sampler index cache: 512-entry direct-mapped 8-bit index store

## Interfaces

### Provides

(none — internal to UNIT-011)

### Consumes

- INT-010 (GPU Register Map) — TEX0_CFG / TEX1_CFG base address and write-invalidate trigger

### Internal Interfaces

- Receives index-resolution cache read requests `(u_idx, v_idx)` from UNIT-011.01
- Returns one 8-bit index byte per request on hit (single cycle)
- On miss: issues SDRAM burst read via UNIT-007 port 3; streams the 8-word burst into the cache line; returns index to UNIT-011.06
- Asserts `fill_busy_o` for the duration of the fill; the parent texture sampler blocks all lookup issue while `fill_busy_o` is high, which serializes lookups behind any in-flight fill and propagates the stall to UNIT-006

## Design Description

### Cache Organization

```text
Per-Sampler Index Cache (2 samplers, independent):

  32 sets × 1 way × 16 indices/line = 512 index entries per sampler
  8-bit index per entry
  Cache line: 4×4 index block (16 bytes) covering an 8×8 apparent-texel area

  EBR primitive: DP16KD in 1024×18 mode
  Each EBR word stores 2 adjacent indices (low byte = even u, high byte = odd u),
  matching the 16-bit SDRAM word delivered each burst cycle.
  8 EBR words per cache line (one per SDRAM burst cycle).
  Single bank per sampler.
  Total: 1 EBR per sampler, 2 EBR for 2 samplers.
```

### Address Fields

**Set index (XOR folding):**

```text
block_x = u_idx >> 2        // 4×4 index block column
block_y = v_idx >> 2        // 4×4 index block row
set     = block_x[4:0] ^ block_y[4:0]    // XOR of low 5 bits → 32 sets
```

XOR indexing distributes spatially adjacent index blocks across different cache sets, preventing systematic aliasing for row-major access patterns.
The same XOR scheme is retained from the previous L1 cache design (see DD-037 and DD-038 for historical context).

**Within-line address:**

```text
line_offset = {v_idx[1:0], u_idx[1:0]}   // 4 bits → 16 index entries per line
word_offset = {v_idx[1:0], u_idx[1]}     // 3 bits → 8 EBR words per line
lane_select = u_idx[0]                   // selects low/high byte within the EBR word
```

**EBR address (lookup and fill):**

```text
ebr_addr[9:0] = {2'b00, set[4:0], word_offset[2:0]}  // 1024-deep EBR, only 256 words used
```

The upper two address bits are tied to zero; only the lower 256 words of the 1024-deep EBR are populated.

Each EBR word holds two adjacent indices in row-major order:
the byte for `u_idx[0] = 0` lives in `data[7:0]`, and the byte for `u_idx[0] = 1` lives in `data[15:8]`.
The two parity bits (`data[17:16]`) are unused.
This packing is the natural alignment of the 4×4 row-major INDEXED8_2X2 block (INT-014) with SDRAM's 16-bit word width — each SDRAM word delivers exactly one EBR word's worth of payload.

**Tag:**

Each set stores one tag entry: valid bit + `(tex_base[15:0], block_x, block_y)`.
A tag match on base address **and full block coordinates** constitutes a hit.

The tag must carry the *full* `(block_x, block_y)` because the XOR set index folds them onto the same set: distinct blocks like `(0,0)` and `(1,1)` share set 0, and any small texture (`block_x < 32`, `block_y < 32`) keeps the upper bits zero.
Storing only the upper bits would leave aliased blocks indistinguishable in the tag and a fill at one would silently satisfy a lookup at the other.

### Inputs

- Cache read request: `(u_idx, v_idx)` from UNIT-011.01
- TEX0_CFG / TEX1_CFG write strobe (cache invalidation trigger from UNIT-003)

### Outputs

- One 8-bit palette index `idx[7:0]` to UNIT-011.06 on hit
- `miss_o` strobe to the parent sampler's miss handler, which drives the SDRAM port 3 burst request
- `fill_busy_o` to the sampler — held high from `SDRAM_REQ` through the cycle the terminal write commits; the sampler propagates this as a stall to UNIT-006

### Replacement Policy

Direct-mapped (1 way per set); no replacement policy required.
A miss always overwrites the single resident line in the addressed set.

### Cache Invalidation

A TEX0_CFG write clears all 32 valid bits for sampler 0 in a single cycle.
A TEX1_CFG write clears all 32 valid bits for sampler 1 in a single cycle.
The next access after invalidation is guaranteed to miss and will trigger an SDRAM fill.
Stale indices are never served after a configuration change.

### Fill State Machine

On miss, the fill FSM sequences:

```text
IDLE → SDRAM_REQ → SDRAM_STREAM (8 words) → IDLE
```

- **SDRAM_REQ:** Assert port 3 request with burst address (from INT-014 block-tiled index layout) and length = 8 words (16 bytes). Raise `fill_busy_o` and hold it through the burst. The parent sampler asserts `fill_first_i` for one cycle here, alongside the `(u_idx, v_idx)` that triggered the miss; the cache combinationally derives the new tag from those coordinates and resets its internal 3-bit fill counter to zero. `fill_first_i` precedes the first `fill_word_valid_i` by at least one cycle (matching the SDRAM controller's request-to-first-word latency).
- **SDRAM_STREAM:** Each cycle that UNIT-007 returns a valid burst word, write it into the EBR at `{2'b00, set, word_idx}` where `word_idx` is generated by an internal 3-bit counter that increments on every `fill_word_valid_i`. The two indices packed in the SDRAM word are written as one 18-bit EBR word (parity bits zero). Tag and valid bit are *not* updated during the streaming cycles.
- **IDLE:** On the cycle following the terminal EBR write (signalled by `fill_word_last_i`), the cache flops the new tag into `tag_store[set]` and sets `valid_r[set]` in the same clock edge — making the line atomically visible. `fill_busy_o` drops on the same edge. The stalled fragment in UNIT-006 retries the lookup on the cycle after.

**Streaming correctness invariants:**

- **Concurrent commit.** `tag_store[set]` and `valid_r[set]` flop in the same clock edge after `fill_word_last_i`. There is no cycle in which the new tag is visible without the new valid bit, nor vice versa. This gives the bound assertion `tag_store[s]` and `valid_r[s]` always describe the same line at every clock boundary.
- **Sampler-side serialization.** The sampler (UNIT-011) blocks all lookup issue while `fill_busy_o` is high, so the cache observes no concurrent lookup–fill traffic on any set. The cache contains no per-set fill-collision gating.
- **Read port idle during fill.** Because no lookup is in flight while `fill_busy_o` is high, the DP16KD read port is unused during the streaming window; the write port carries the burst exclusively.

### EBR Notes

**Primitive:** DP16KD (ECP5 true dual-port EBR)
**Mode:** 1024×18 (18-bit word, 1024 deep — only 256 words used: 32 sets × 8 words/line)
**Per sampler:** 1 EBR
**REGMODE:** `NOREG` on the read port (single-cycle synchronous read; the parent assembly absorbs the read-data latency).

The 18-bit word width is chosen to match the SDRAM data width: each burst cycle delivers one 16-bit SDRAM word, which becomes one EBR write of two packed indices.
This collapses the previous two-stage `SDRAM_BURST → WRITE_LINE` design (which required 16 simultaneous write ports and could not be inferred onto a single DP16KD) into a one-write-per-cycle stream that maps directly onto the primitive.
The two parity lanes (`data[17:16]`) are tied off.

The true dual-port configuration is retained for two reasons:

1. The lookup-cycle read uses the read port; the streaming fill uses the write port. Although the sampler blocks lookups during a fill (so they never overlap), keeping the ports physically separate avoids any read-during-write hazard inside the EBR primitive and makes the DP16KD instantiation parameters straightforward.
2. Future support for back-to-back lookup-on-other-set during fill (if the sampler's blocking policy is later relaxed) can be enabled without changing the EBR primitive — only the sampler-side gating.

See REQ-011.02 for the complete EBR budget across the GPU.

## Implementation

- `rtl/components/texture/detail/l1-cache/src/texture_index_cache.sv`: Index cache arrays, tag storage, set indexing, streaming fill port (`fill_first_i`, `fill_word_valid_i`, `fill_word_data_i[15:0]`, `fill_word_last_i`, `fill_busy_o`), internal 3-bit fill counter, invalidation logic
- `twin/components/texture/detail/l1-cache/src/lib.rs`: Bit-accurate digital twin model — `IndexCache` struct, XOR-folded set index, line-offset decode, direct-mapped lookup/fill/invalidate

The authoritative algorithmic design is the `gs-tex-l1-cache` twin crate (`twin/components/texture/detail/l1-cache/`).
The twin remains transactional: `IndexCache::fill_line` accepts the complete 16-byte payload as one atomic call.
This is the bit-equivalent of the RTL streaming fill, because the RTL only asserts the valid bit on the terminal write — every external observer sees the line transition `invalid → fully populated` in a single observable event, exactly as the twin models it.
RTL tag-comparison and XOR set-indexing behavior must be bit-identical to the twin.

## Design Notes

**Capacity:** 512 index entries per sampler = 512 × 2×2 apparent texels = up to a 32×32-texel apparent working set per sampler (depending on access pattern and XOR distribution).

**XOR set indexing is a hardware optimization only:** The physical texture layout in SDRAM (INT-014) uses block-tiled order without XOR.
The XOR folding is applied entirely within the cache address computation.

**No L2 backstop:** Unlike the former two-level hierarchy, every index cache miss goes directly to SDRAM.
The miss penalty is one burst of 8 × 16-bit words ≈ 11 cycles at 100 MHz.
The simplified hierarchy reduces EBR usage from 8 EBR per sampler to 1 EBR per sampler.
