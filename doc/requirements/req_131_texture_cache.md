# REQ-131: Texture Cache

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the pixel pipeline samples textures during rendering, the system SHALL cache decompressed texel data to reduce external SRAM bandwidth and enable single-cycle bilinear texture filtering.

## Rationale

Texture sampling is memory-intensive. Without caching, every pixel requiring bilinear filtering would perform 4 SRAM reads (one per texel), plus decompression overhead for BC1 textures. This creates severe SRAM bandwidth bottlenecks that limit fill rate.

A per-sampler cache architecture solves this by:
1. **Reducing SRAM bandwidth:** Spatial locality means adjacent pixels often sample the same 4×4 block, achieving >85% cache hit rates
2. **Enabling single-cycle bilinear filtering:** All 4 texels for a 2×2 bilinear quad can be read in parallel from interleaved banks
3. **Amortizing decompression cost:** BC1 blocks are decompressed once per cache fill rather than per pixel
4. **Avoiding cross-sampler contention:** Independent caches for each of the 4 texture samplers eliminate stalls from multi-texture rendering

**Performance Impact (at 100 MHz `clk_core`):**
- **Cache hit:** 1 cycle / 10 ns for 4 bilinear texels (all 4 read in parallel from interleaved banks)
- **Cache miss:** ~8-18 cycles to fetch and decompress block from SRAM (BC1: ~8 cycles / 80 ns, RGBA4444: ~18 cycles / 180 ns)
- **Expected hit rate:** >85% for typical scenes (based on spatial locality of texture access)

Note: The texture cache and SRAM controller share the same 100 MHz clock domain, so cache fill operations are synchronous single-domain transactions with no CDC overhead.

**Resource Cost:**
- 16 EBR blocks total (4 per sampler × 4 samplers) = 288 Kbits
- ~800-1600 LUTs for cache tags, comparators, and control logic
- Acceptable within ECP5-25K budget (REQ-051)

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-032 (Texture Cache Architecture)
- INT-010 (GPU Register Map - TEXn_BASE, TEXn_FMT trigger invalidation)
- INT-014 (Texture Memory Layout - source texture block addressing)

## Verification Method

**Test:** Verify cache behavior meets the following acceptance criteria:

- [ ] Each sampler cache operates independently with no cross-sampler contention
- [ ] Cache correctly stores and retrieves 4×4 texel blocks in RGBA5652 format
- [ ] 4-way set associativity verified by accessing 4+ blocks mapping to the same set
- [ ] Any 2×2 bilinear quad reads exactly one texel per bank (single-cycle parallel access)
- [ ] Bilinear texels are read in 1 cycle on cache hit
- [ ] RGBA4444 texels correctly converted to RGBA5652 on cache fill
- [ ] BC1 blocks correctly decompressed to RGBA5652 on cache fill
- [ ] TEXn_BASE write invalidates sampler N's cache (next access is guaranteed miss)
- [ ] TEXn_FMT write invalidates sampler N's cache (next access is guaranteed miss)
- [ ] Invalidating sampler N does not affect other samplers
- [ ] Stale data never served after configuration change
- [ ] Cache miss latency within target: BC1 ~8 cycles, RGBA4444 ~18 cycles
- [ ] Pseudo-LRU replacement avoids thrashing for sequential access patterns
- [ ] XOR set indexing distributes adjacent blocks across different sets (no systematic aliasing)

## Notes

The cache stores texels in an intermediate format (RGBA5652: R5 G6 B5 A2) that matches framebuffer RGB565 precision and provides minimal alpha support for BC1 transparency. This 18-bit/texel format aligns with ECP5 EBR native width (1024×18).

Detailed cache architecture (line format, invalidation protocol, set indexing, interleaving) is specified in INT-032.

Implementation details (4-way set associative, pseudo-LRU, XOR indexing, EBR usage) are documented in UNIT-006.

See DD-010 in design_decisions.md for architectural rationale.
