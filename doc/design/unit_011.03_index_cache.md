# UNIT-011.03: Index Cache

## Purpose

Per-sampler direct-mapped cache storing 8-bit palette indices at half the apparent texture resolution.
One DP16KD EBR per sampler provides single-cycle index access on cache hit.
On miss, issues an SDRAM burst read (8 words = 16 bytes per 4×4 index block) via arbiter port 3 to fill a cache line, then resumes the stalled fragment.

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
- On miss: issues SDRAM burst read via UNIT-007 port 3; fills 16-entry cache line; returns index to UNIT-011.06
- Stalls UNIT-006 fragment pipeline while fill is in progress

## Design Description

### Cache Organization

```text
Per-Sampler Index Cache (2 samplers, independent):

  32 sets × 1 way × 16 indices/line = 512 index entries per sampler
  8-bit index per entry
  Cache line: 4×4 index block (16 bytes) covering an 8×8 apparent-texel area

  EBR primitive: DP16KD in 2048×9 mode
  Single bank per sampler
  Total: 1 EBR per sampler, 2 EBR for 2 samplers
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
```

**EBR address:**

```text
ebr_addr[10:0] = {set[4:0], line_offset[3:0], ...}  // 9-bit word address within 2048-deep EBR
```

Each EBR word stores one 8-bit index (lower 8 bits of the 9-bit DP16KD data word; the ninth bit is unused).

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
- Cache miss signal to trigger SDRAM fill
- Pipeline stall signal to UNIT-006

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
IDLE → SDRAM_REQ → SDRAM_BURST (8 words) → WRITE_LINE → IDLE
```

- **SDRAM_REQ:** Assert port 3 request with burst address (from INT-014 block-tiled index layout) and length = 8 words (16 bytes)
- **SDRAM_BURST:** Receive 8 × 16-bit words from UNIT-007; accumulate 16 bytes = 16 index entries
- **WRITE_LINE:** Write 16 index entries into the EBR line; update tag and set valid bit
- **IDLE:** Remove pipeline stall; return `idx[7:0]` for the requested position

### EBR Notes

**Primitive:** DP16KD (ECP5 true dual-port EBR)
**Mode:** 2048×9 (9-bit word, 2048 deep)
**Per sampler:** 1 EBR
The true dual-port configuration allows simultaneous index read (for texel fetch) and index write (for cache fill) without arbitration, provided read and write addresses differ.
During fill, the read port is held idle.

See REQ-011.02 for the complete EBR budget across the GPU.

## Implementation

- `rtl/components/texture/detail/l1-cache/src/texture_index_cache.sv`: Index cache arrays, tag storage, set indexing, fill FSM, invalidation logic
- `twin/components/texture/detail/l1-cache/src/lib.rs`: Bit-accurate digital twin model — `IndexCache` struct, XOR-folded set index, line-offset decode, direct-mapped lookup/fill/invalidate

The authoritative algorithmic design is the `gs-tex-l1-cache` twin crate (`twin/components/texture/detail/l1-cache/`).
The RTL tag-comparison and XOR set-indexing behavior must be bit-identical to the twin.

## Design Notes

**Capacity:** 512 index entries per sampler = 512 × 2×2 apparent texels = up to a 32×32-texel apparent working set per sampler (depending on access pattern and XOR distribution).

**XOR set indexing is a hardware optimization only:** The physical texture layout in SDRAM (INT-014) uses block-tiled order without XOR.
The XOR folding is applied entirely within the cache address computation.

**No L2 backstop:** Unlike the former two-level hierarchy, every index cache miss goes directly to SDRAM.
The miss penalty is one burst of 8 × 16-bit words ≈ 11 cycles at 100 MHz.
The simplified hierarchy reduces EBR usage from 8 EBR per sampler to 1 EBR per sampler.
