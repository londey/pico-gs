# REQ-131: Texture Cache

## Type

Functional

## Priority

High

## Overview

The GPU shall include a per-sampler texture cache to reduce external SRAM bandwidth and enable single-cycle bilinear texture sampling.

## Functional Requirements

### FR-131-1: Per-Sampler Cache

**Description**: Each of the 4 texture samplers SHALL have an independent texture cache.

**Details**:
- 4 interleaved 1024x18-bit RAM banks per sampler (ECP5 EBR blocks in native configuration)
- 256 cache lines per sampler, each storing a decompressed 4x4 texel block
- 4-way set associative with 64 sets
- Total: 16 EBR blocks across all 4 samplers (288 Kbits)

**Acceptance Criteria**:
- Each sampler cache operates independently with no cross-sampler contention
- Cache correctly stores and retrieves 4x4 texel blocks
- 4-way associativity verified by accessing 4+ blocks mapping to the same set

### FR-131-2: Cache Line Format (RGBA5652)

**Description**: Each cache line SHALL store 16 decompressed texels in RGBA5652 format (18 bits per texel).

**Details**:
- R: 5 bits, G: 6 bits, B: 5 bits (RGB565-compatible)
- A: 2 bits (00=transparent, 01=33%, 10=67%, 11=opaque)
- Texels are decompressed from source format (RGBA4444 or BC1) on cache fill

**Conversion from source formats**:
- RGBA4444 to RGBA5652: R4→R5 (shift left 1, replicate MSB), G4→G6 (shift left 2, replicate MSBs), B4→B5 (shift left 1, replicate MSB), A4→A2 (shift right 2)
- BC1 to RGBA5652: RGB565 colors stored directly, A2 from BC1 1-bit alpha (0→00, 1→11)

**Acceptance Criteria**:
- RGBA4444 texels correctly converted to RGBA5652 on cache fill
- BC1 blocks correctly decompressed to RGBA5652 on cache fill
- RGB565 component matches framebuffer format precision

### FR-131-3: Bilinear Interleaving

**Description**: The 4 RAM banks SHALL be interleaved by texel position parity so that any 2x2 bilinear filter neighborhood reads exactly one texel from each bank.

**Details**:
- Bank 0: texels at (even_x, even_y) positions within 4x4 block
- Bank 1: texels at (odd_x, even_y) positions
- Bank 2: texels at (even_x, odd_y) positions
- Bank 3: texels at (odd_x, odd_y) positions

**Bank assignment within 4x4 block**:
```
Position:  (0,0) (1,0) (2,0) (3,0)
Bank:        0     1     0     1

Position:  (0,1) (1,1) (2,1) (3,1)
Bank:        2     3     2     3

Position:  (0,2) (1,2) (2,2) (3,2)
Bank:        0     1     0     1

Position:  (0,3) (1,3) (2,3) (3,3)
Bank:        2     3     2     3
```

**Acceptance Criteria**:
- Any 2x2 bilinear quad accesses exactly one texel per bank
- All 4 bilinear texels read in a single cycle on cache hit
- Bank conflicts never occur for bilinear sampling within a single block

### FR-131-4: XOR Set Indexing

**Description**: Cache set index SHALL be computed using XOR-folded addressing to distribute spatially adjacent blocks across different cache sets.

**Details**:
```
block_x = pixel_x / 4
block_y = pixel_y / 4
set = (block_x[5:0] ^ block_y[5:0])  // XOR of low 6 bits, giving 64 sets
```

**Rationale**: Linear indexing (`set = block_index % 64`) causes all blocks in a row to map to the same 64 sets. For a 256x256 texture (64 blocks per row), vertically adjacent blocks at (x, y) and (x, y+1) map to the same set, causing thrashing during bilinear filtering at block boundaries. XOR indexing distributes adjacent blocks across different sets.

**Acceptance Criteria**:
- Vertically adjacent blocks map to different cache sets
- Horizontally adjacent blocks map to different cache sets
- No systematic aliasing patterns for typical texture access

### FR-131-5: Cache Invalidation

**Description**: The cache for a sampler SHALL be fully invalidated when texture configuration changes.

**Details**:
- Writing TEXn_BASE invalidates sampler N's cache (texture base address changed)
- Writing TEXn_FMT invalidates sampler N's cache (format, dimensions, or mipmap count changed)
- Invalidation clears all valid bits for the affected sampler
- No explicit flush register required (implicit invalidation only)

**Acceptance Criteria**:
- After TEXn_BASE write, next texture access is a guaranteed cache miss
- After TEXn_FMT write, next texture access is a guaranteed cache miss
- Stale data never served after configuration change

### FR-131-6: Cache Miss Handling

**Description**: On cache miss, the pixel pipeline SHALL fetch and decompress the block from SRAM.

**Details**:
1. Stall the pixel pipeline (no output until fill completes)
2. Read the 4x4 block from SRAM:
   - BC1: 8 bytes (4 SRAM reads on 16-bit bus)
   - RGBA4444: 32 bytes (16 SRAM reads on 16-bit bus)
3. Decompress to RGBA5652 format (16 texels x 18 bits)
4. Write decompressed texels to the 4 interleaved banks
5. Select replacement way using pseudo-LRU policy
6. Resume pipeline with the requested texels

**Acceptance Criteria**:
- Cache miss correctly fetches and decompresses block
- Fill latency within target (see Performance Targets)
- Pseudo-LRU replacement avoids thrashing for sequential access patterns

## Performance Targets

| Metric | Target |
|--------|--------|
| Cache hit: bilinear sample latency | 1 cycle (all 4 texels in parallel) |
| Cache miss: fill latency (BC1) | ~8 cycles (4 SRAM reads + decompress) |
| Cache miss: fill latency (RGBA4444) | ~18 cycles (16 SRAM reads + convert) |
| Expected hit rate (typical scene) | >85% |
| BRAM usage (all 4 samplers) | 16 EBR blocks (288 Kbits) |
| LUT overhead per sampler | ~200-400 LUTs (tags, comparators, control) |

## Dependencies

- **INT-010**: GPU Register Map (TEXn_BASE, TEXn_FMT register writes trigger invalidation)
- **INT-014**: Texture Memory Layout (block addressing for cache fill)
- **UNIT-006**: Pixel Pipeline (cache integrated into sampling stage)
- **REQ-024**: Texture Sampling (cache-aware sampling pipeline)
- **REQ-130**: Texture Mipmapping (cache handles mip-level blocks with distinct addresses)

## Notes

- XOR set indexing is a hardware-only optimization; no physical texture memory layout change is required. The linear 4x4 block layout in SRAM (INT-014) remains unchanged.
- RGBA5652 preserves RGB565 precision (matching framebuffer format) with minimal alpha for BC1 punch-through support. After cache read, texel data is promoted from RGBA5652 to 10.8 fixed-point format for pipeline processing (see FR-024-6). The cache itself stores the compact RGBA5652 format to maximize capacity.
- RGBA4444 textures lose 2 bits of alpha precision in cache (4-bit to 2-bit); this is acceptable as the final framebuffer is RGB565 with no alpha channel stored.
- For bilinear filtering across block boundaries (e.g., texel at x=3 needs neighbor at x=4 in next block), both blocks must be resident in the cache. The 4-way associativity provides sufficient capacity for this case.
- See DD-010 in design_decisions.md for architectural rationale.
