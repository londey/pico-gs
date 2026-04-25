# UNIT-011: Texture Sampler

## Purpose

Two-sampler texture pipeline providing Q4.12 RGBA texel data to UNIT-006 (Pixel Pipeline).
Each sampler independently fetches 8-bit palette indices from a half-resolution index cache, looks up the RGBA color from a shared palette LUT, and delivers `TEX_COLOR0` and `TEX_COLOR1` to UNIT-010 (Color Combiner) via UNIT-006.
UNIT-011 is decomposed into three active subunits: UV coordinate processing (UNIT-011.01), half-resolution index cache (UNIT-011.03), and shared palette LUT (UNIT-011.06).

## Implements Requirements

- REQ-003 (Texture Samplers)
- REQ-003.01 (Textured Triangle) — index cache lookup and texel delivery via palette LUT
- REQ-003.02 (Multi-Texture Rendering) — two independent sampler instances
- REQ-003.05 (UV Wrapping Modes) — see UNIT-011.01
- REQ-003.06 (Texture Sampling) — INDEXED8_2X2 palette lookup; NEAREST point-sample
- REQ-003.08 (Texture Cache) — index cache in UNIT-011.03; palette LUT in UNIT-011.06

## Interfaces

### Provides

(none — cache-architecture details live in this document and its subunits UNIT-011.03 / UNIT-011.06)

### Consumes

- INT-010 (GPU Register Map) — TEX0_CFG and TEX1_CFG registers; PALETTE0 and PALETTE1 registers
- INT-011 (SDRAM Memory Layout) — SDRAM addressing used by index cache fill burst requests
- INT-014 (Texture Memory Layout) — 4×4 block-tiled index-array layout in SDRAM

### Internal Interfaces

- Receives fragment data (position, UV0/UV1 in Q4.12) from UNIT-005 (Rasterizer) via the UNIT-006 pipeline bus
- Issues SDRAM burst read requests to UNIT-007 (Memory Arbiter) via arbiter port 3
- Outputs Q4.12 TEX_COLOR0 and TEX_COLOR1 (RGBA, 16 bits per channel) to UNIT-006

## Clock Domain

UNIT-011 runs at 100 MHz (`clk_core`), the same clock domain as the SDRAM controller (UNIT-007) and the rest of the pixel pipeline (UNIT-006).
All SDRAM burst requests are synchronous single-domain transactions; no clock domain crossing logic is required.

## Design Description

### Subunit Decomposition

```text
Fragment Bus (UV) from UNIT-005 via UNIT-006
      │
      ▼
┌──────────────────────────┐
│ UNIT-011.01              │  UV Coordinate Processing
│ UV wrap/clamp/mirror     │  wrap mode → wrapped integer texel coords
│ + quadrant split         │  → quadrant[1:0] + half-res index address
└────────────┬─────────────┘
             │ index address (u_idx = u_wrapped>>1, v_idx = v_wrapped>>1)
             │ quadrant[1:0] = {v_wrapped[0], u_wrapped[0]}
             ▼
┌──────────────────────────┐
│ UNIT-011.03              │  Half-Resolution Index Cache
│ DP16KD 1×EBR per sampler │  direct-mapped, 32 sets × 16 indices/line
│ 8-bit index entries      │
└────────────┬─────────────┘ (miss → SDRAM burst fill via port 3)
             │ idx[7:0]
             ▼
┌──────────────────────────┐
│ UNIT-011.06              │  Palette LUT (shared, 2 slots)
│ 4 PDPW16KD EBR (shared)  │  addressed by {slot[0], idx[7:0], quadrant[1:0]}
│ SDRAM load FSM           │  → 36-bit UQ1.8 RGBA
└────────────┬─────────────┘
             │ UQ1.8 RGBA → texel_promote → Q4.12
             ▼
   Q4.12 TEX_COLOR0 / TEX_COLOR1 → UNIT-006
```

### Inputs

- Per-sampler UV coordinates (UV0, UV1) in Q4.12 signed fixed-point (16-bit: sign at [15], integer [14:12], fractional [11:0])
- TEX0_CFG and TEX1_CFG register values from UNIT-003 (base address, wrap mode, `PALETTE_IDX`, `WIDTH_LOG2`, `HEIGHT_LOG2`)
- PALETTE0 and PALETTE1 register values from UNIT-003 (palette slot base address; load trigger pulse)

### Outputs

- `TEX_COLOR0`: Q4.12 RGBA texel from sampler 0 (or Q4.12 white = 0x1000 if unit disabled)
- `TEX_COLOR1`: Q4.12 RGBA texel from sampler 1 (or Q4.12 white = 0x1000 if unit disabled)

### Fragment Latency

Best-case (index cache hit, palette ready): 4 cycles:

| Cycle | Stage                                                                |
| ----- | -------------------------------------------------------------------- |
| 0     | uv_wrap: apply wrap mode, extract quadrant, compute half-res address |
| 1     | index_tag_fetch: check index cache tag; read index on hit            |
| 2     | index_sample: present idx[7:0] to palette LUT                        |
| 3     | palette_lookup: read UQ1.8 RGBA; promote to Q4.12                    |

On index cache miss, the fragment pipeline stalls while a single SDRAM index-block burst fills the cache line.
There is no second-level compressed cache; every index miss goes directly to SDRAM.

### Miss Handling Protocol

```text
Fragment needs texel
  → UNIT-011.03 index cache lookup
    → hit:  idx[7:0] + quadrant[1:0] → UNIT-011.06 palette LUT → Q4.12 (4 cycles)
    → miss: stall UNIT-006 pipeline
            issue SDRAM burst read (8 words, 4×4 index block = 16 bytes) on arbiter port 3
            fill index cache line
            resume: idx[7:0] + quadrant[1:0] → UNIT-011.06 palette LUT → Q4.12
```

Palette loads are triggered by firmware writing `PALETTEn.LOAD_TRIGGER`; they are not triggered by fragment misses.
A palette slot marked not-ready (`slotN_ready = 0`) causes UNIT-006 to stall until the load FSM sets `slotN_ready`.
Index cache fills preempt pending palette loads on arbiter port 3 (in-flight fills take priority).

### Cache Invalidation Protocol

When firmware writes `TEX0_CFG` (register 0x10), all valid bits for sampler 0's index cache are cleared atomically.
When firmware writes `TEX1_CFG` (register 0x11), all valid bits for sampler 1's index cache are cleared atomically.
The two samplers are fully independent; invalidating one does not affect the other.
Palette slots are not invalidated by TEXn_CFG writes; palette contents persist until a new `PALETTEn.LOAD_TRIGGER` pulse overwrites the slot.
The first texture access after index cache invalidation is guaranteed to miss, triggering an SDRAM fill.

### Arbiter Port 3 Ownership

UNIT-011 owns arbiter port 3 on UNIT-007 for all texture SDRAM burst reads.
A 3-way local arbiter inside `texture_sampler.sv` multiplexes three request sources onto port 3:

1. Palette slot 0 load (SDRAM burst: 2048 words = 4096 bytes, multi-burst)
2. Palette slot 1 load (same)
3. Index cache fill (SDRAM burst: 8 words = 16 bytes per 4×4 index block)

Index cache fills have effective precedence over palette loads when an in-flight fill is in progress.
Port 3 is also used by `gpu_top.sv` for fire-and-forget `PERF_TIMESTAMP` writes at lowest priority.
See DD-026 for the port 3 sharing rationale.

## Implementation

- `rtl/components/texture/src/texture_sampler.sv`: Texture sampler assembly (UV dispatch, index cache + palette LUT integration, 3-way port-3 arbiter, stall logic)
- `rtl/components/texture/detail/uv-coord/src/texture_uv_coord.sv`: UV coordinate wrapping and quadrant extraction (UNIT-011.01)
- `rtl/components/texture/detail/l1-cache/src/texture_index_cache.sv`: Half-resolution index cache + fill FSM, instantiated twice for 2 samplers (UNIT-011.03)
- `rtl/components/texture/detail/palette-lut/src/texture_palette_lut.sv`: Shared 2-slot palette LUT + SDRAM load FSM (UNIT-011.06)
- `rtl/pkg/fp_types_pkg.sv`: Q4.12 type definitions and promotion functions (shared package)

The authoritative algorithmic design is the gs-texture twin crate (`twin/components/texture/`).
The RTL must produce bit-identical results to the twin at the Q4.12 texel output level.

## Verification

- VER-005 (Texture Palette and Index Cache Unit Testbench) — verifies UNIT-011.06 palette lookup and UNIT-011.03 fill behavior
- VER-012 (Textured Triangle Golden Image Test) — exercises full index cache + palette lookup path
- VER-014 (Textured Cube Golden Image Test) — exercises multi-face texture access patterns
- VER-016 (Perspective Road Golden Image Test) — exercises index cache fills under perspective foreshortening

## Design Notes

**Two-sampler symmetry:** Both samplers share identical hardware structure for UNIT-011.01 and UNIT-011.03.
Each sampler has its own index cache EBR, tag array, valid bits, and fill FSM.
UNIT-011.06 (palette LUT) is shared between both samplers; each sampler selects its palette slot via `TEXn_CFG.PALETTE_IDX`.

**gs-twin is the authoritative algorithmic reference:** Before modifying texture RTL, read `twin/components/texture/` to understand the expected bit-accurate behavior.
Any pixel-level mismatch between RTL and twin output is a real bug in the RTL.

**Format encoding:** `tex_format[3:0]` from TEXn_CFG selects the decode path.
Only `INDEXED8_2X2 = 4'h0` is valid; codes 4'h1–4'hF are reserved for future use (4-bit field width is retained for ABI stability, see `tex_format_e` in gpu_regs.rdl).

**EBR budget:** 1 EBR per sampler for the index cache (2 EBR total), plus 4 shared EBR for the palette LUT = 6 EBR total.
The ECP5-25K has 56 EBR blocks; the texture subsystem consumes 6 (11%).
See REQ-011.02 for the complete resource budget.

**Texture minimum size:** `WIDTH_LOG2 ≥ 1` and `HEIGHT_LOG2 ≥ 1` (2×2 apparent texels minimum), ensuring at least one 2×2 tile exists for quadrant extraction.
