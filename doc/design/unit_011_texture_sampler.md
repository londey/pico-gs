# UNIT-011: Texture Sampler

## Purpose

Two-sampler texture pipeline providing decoded Q4.12 RGBA texel data to UNIT-006 (Pixel Pipeline).
Each sampler independently fetches, decompresses, caches, and filters texture data from SDRAM, delivering the final `TEX_COLOR0` and `TEX_COLOR1` outputs consumed by UNIT-010 (Color Combiner) via UNIT-006.
UNIT-011 is decomposed into five subunits covering UV coordinate processing, bilinear/trilinear filtering, L1 decompressed cache, block decompression, and L2 compressed cache.

## Implements Requirements

- REQ-003 (Texture Samplers)
- REQ-003.01 (Textured Triangle) — texture cache lookup and texel delivery
- REQ-003.02 (Multi-Texture Rendering) — two independent sampler instances
- REQ-003.03 (Compressed Textures) — see UNIT-011.04
- REQ-003.04 (Swizzle Patterns) — see UNIT-011.01
- REQ-003.05 (UV Wrapping Modes) — see UNIT-011.01
- REQ-003.06 (Texture Sampling) — filter portion in UNIT-011.02; decoder portion in UNIT-011.04
- REQ-003.07 (Texture Mipmapping) — see UNIT-011.02
- REQ-003.08 (Texture Cache) — L1 in UNIT-011.03; L2 in UNIT-011.05

## Interfaces

### Provides

(none — INT-032 is deprecated and its content is absorbed into the UNIT-011 subunit documents)

### Consumes

- INT-010 (GPU Register Map) — TEX0_CFG and TEX1_CFG registers
- INT-011 (SDRAM Memory Layout) — SDRAM addressing used by L2 fill burst requests
- INT-014 (Texture Memory Layout) — 4×4 block-tiled texture layout in SDRAM

### Internal Interfaces

- Receives fragment data (position UV0/UV1 in Q4.12, frag_lod UQ4.4) from UNIT-005 (Rasterizer) via the UNIT-006 pipeline bus
- Issues SDRAM burst read requests to UNIT-007 (Memory Arbiter) via arbiter port 3
- Outputs Q4.12 TEX_COLOR0 and TEX_COLOR1 (RGBA, 16 bits per channel) to UNIT-006

## Clock Domain

UNIT-011 runs at 100 MHz (`clk_core`), the same clock domain as the SDRAM controller (UNIT-007) and the rest of the pixel pipeline (UNIT-006).
All SDRAM burst requests are synchronous single-domain transactions; no clock domain crossing logic is required.

## Design Description

### Subunit Decomposition

```
Fragment Bus (UV, frag_lod) from UNIT-005 via UNIT-006
      │
      ▼
┌──────────────────┐
│ UNIT-011.01      │  UV Coordinate Processing
│ UV wrap/clamp/   │  wrap mode, swizzle, mip_level selection
│ mirror + swizzle │
└────────┬─────────┘
         │ wrapped texel coords + mip_level
         ▼
┌──────────────────┐
│ UNIT-011.02      │  Bilinear/Trilinear Filter
│ 2x2 quad fetch + │  sub-texel weights, trilinear LOD blend
│ weight compute   │
└────────┬─────────┘
         │ cache read request (4 texels)
         ▼
┌──────────────────┐
│ UNIT-011.03      │  L1 Decompressed Cache
│ PDPW16KD 512x36  │  4-way set-assoc, UQ1.8, pseudo-LRU
│ per-sampler EBR  │
└────────┬─────────┘ (miss)
         │                ┌────────────────────────┐
         └───────────────►│ UNIT-011.04             │
                          │ Block Decompressor       │
                          │ BC1–BC5, RGB565,         │
                          │ RGBA8888, R8             │
                          │ + texel_promote (Q4.12)  │
                          └────────────┬────────────┘
                                       │ (L2 miss)
                                       ▼
                          ┌────────────────────────┐
                          │ UNIT-011.05             │
                          │ L2 Compressed Cache     │
                          │ DP16KD 1024x16 banks    │
                          │ SDRAM burst fill        │
                          └────────────────────────┘
         │
         ▼
   Q4.12 TEX_COLOR0 / TEX_COLOR1 → UNIT-006
```

### Inputs

- Per-sampler UV coordinates (UV0, UV1) in Q4.12 signed fixed-point (16-bit: sign at [15], integer [14:12], fractional [11:0])
- Per-pixel level-of-detail `frag_lod` (UQ4.4, 8-bit: integer mip level in [7:4], trilinear blend weight in [3:0]) from UNIT-005
- TEX0_CFG and TEX1_CFG register values from UNIT-003 (base address, format, wrap mode, swizzle, mip bias, mip levels)

### Outputs

- `TEX_COLOR0`: Q4.12 RGBA texel from sampler 0 (or Q4.12 white = 0x1000 if unit disabled)
- `TEX_COLOR1`: Q4.12 RGBA texel from sampler 1 (or Q4.12 white = 0x1000 if unit disabled)

### Miss Handling Protocol

On L1 cache miss, UNIT-011 stalls the fragment pipeline and falls through to L2 before SDRAM:

```text
Fragment needs texel → UNIT-011.03 L1 lookup
  → L1 hit:  return 4 texels from 4 interleaved banks (single cycle bilinear quad)
  → L1 miss: UNIT-011.05 L2 lookup
    → L2 hit:  decompress 4×4 block (UNIT-011.04) → fill L1 → return
    → L2 miss: SDRAM burst read (arbiter port 3) → fill L2 → decompress → fill L1 → return
```

The cache fill FSM in `texture_cache.sv` implements:
`IDLE → FETCH → DECOMPRESS → WRITE_BANKS → IDLE`

While the FSM is in any state other than IDLE, UNIT-006 holds its fragment pipeline stalled (no new pixels are accepted and no SDRAM writes are issued on ports 1 or 2 for the affected sampler).

### Cache Invalidation Protocol

When firmware writes `TEX0_CFG` (register 0x10), all valid bits for sampler 0's L1 and L2 caches are cleared atomically.
When firmware writes `TEX1_CFG` (register 0x11), all valid bits for sampler 1's L1 and L2 caches are cleared atomically.
The two samplers are fully independent; invalidating one does not affect the other.
The first texture access after invalidation is guaranteed to miss both L1 and L2, triggering an SDRAM fill.
No explicit flush register is required.

### Arbiter Port 3 Ownership

UNIT-011 owns arbiter port 3 on UNIT-007 for all texture SDRAM burst reads.
Burst lengths are format-dependent: 4 words (BC1, BC4), 8 words (BC2, BC3, BC5, R8), 16 words (RGB565), 32 words (RGBA8888).
Port 3 is also used by `gpu_top.sv` for fire-and-forget `PERF_TIMESTAMP` writes at lowest priority; texture bursts have effective precedence because the arbiter serves port 3 in arrival order and texture bursts hold the port for up to 32 words.
See DD-026 for the port 3 sharing rationale and latch-and-serialize scheme.

## Implementation

- `components/texture/rtl/src/texture_sampler.sv`: Texture sampler assembly (wrap modes, bilinear address generation, blending)
- `components/texture/detail/uv-coord/rtl/src/texture_uv_coord.sv`: UV coordinate wrapping and bilinear tap computation (UNIT-011.01)
- `components/texture/detail/bilinear-filter/rtl/src/texture_bilinear.sv`: Bilinear weight computation and blending (UNIT-011.02)
- `components/texture/detail/l1-cache/rtl/src/texture_cache_l1.sv`: L1 decompressed cache + fill FSM, instantiated twice for 2 samplers (UNIT-011.03)
- `components/texture/detail/l2-cache/rtl/src/texture_l2_cache.sv`: L2 compressed block cache (UNIT-011.05)
- `components/texture/detail/block-decoder/rtl/src/texture_bc1.sv`: BC1 block decoder (UNIT-011.04)
- `components/texture/detail/block-decoder/rtl/src/texture_bc2.sv`: BC2 block decoder (UNIT-011.04)
- `components/texture/detail/block-decoder/rtl/src/texture_bc3.sv`: BC3 block decoder (UNIT-011.04)
- `components/texture/detail/block-decoder/rtl/src/texture_bc4.sv`: BC4 single-channel decoder (UNIT-011.04)
- `components/texture/detail/block-decoder/rtl/src/texture_rgb565.sv`: RGB565 uncompressed decoder (UNIT-011.04)
- `components/texture/detail/block-decoder/rtl/src/texture_rgba8888.sv`: RGBA8888 uncompressed decoder (UNIT-011.04)
- `components/texture/detail/block-decoder/rtl/src/texture_r8.sv`: R8 single-channel decoder (UNIT-011.04)
- `components/texture/detail/block-decoder/rtl/src/texel_promote.sv`: UQ1.8 → Q4.12 texel promotion (UNIT-011.04)
- `shared/fp_types_pkg.sv`: Q4.12 type definitions and promotion functions (shared package)

The authoritative algorithmic design is the gs-texture twin crate (`components/texture/twin/`).
The RTL must produce bit-identical results to the twin at the Q4.12 texel output level.

## Verification

- VER-005 (Texture Decoder Unit Testbench) — verifies UNIT-011.04 decoder output
- VER-012 (Textured Triangle Golden Image Test) — exercises full cache + decode + sample path
- VER-014 (Textured Cube Golden Image Test) — exercises multi-face texture access patterns
- VER-016 (Perspective Road Golden Image Test) — exercises RGB565 decoder and cache fills

## Design Notes

**Two-sampler symmetry:** Both samplers share identical hardware structure.
Each sampler is an independent instance of `texture_cache.sv` with its own L1 EBR banks, L2 EBR banks, tag arrays, valid bits, and fill FSM.
Inter-sampler contention does not occur.

**gs-twin is the authoritative algorithmic reference:** Before modifying texture RTL, read `components/texture/twin/` to understand the expected bit-accurate behavior.
Any pixel-level mismatch between RTL and twin output is a real bug in the RTL.

**Format encoding:** `tex_format[3:0]` from TEXn_CFG selects the decode path.
BC1=0, BC2=1, BC3=2, BC4=3, BC5=4, RGB565=5, RGBA8888=6, R8=7.
Codes 8–15 are reserved.
See DD-041.

**EBR budget:** 8 EBR per sampler (4 L1 + 4 L2), 16 EBR total for 2 samplers.
The ECP5-25K has 56 EBR blocks; the texture cache consumes 16 (29%).
See REQ-011.02 for the complete resource budget.
