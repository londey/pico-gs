# Design Decisions

This document records significant design decisions using a lightweight Architecture Decision Record (ADR) format.

## Template

When adding a new decision, copy this template:

```markdown
## DD-NNN: <Title>

**Date:** YYYY-MM-DD  
**Status:** Proposed | Accepted | Superseded by DD-XXX

### Context

<What is the issue or question that needs a decision?>

### Decision

<What is the decision that was made?>

### Rationale

<Why was this decision made? What alternatives were considered?>

### Consequences

<What are the implications of this decision?>
```

---

## Decisions

<!-- Add decisions below, newest first -->

## DD-041: Widen FORMAT Field to 4 Bits and Renumber Texture Format Codes

**Date:** 2026-03-15
**Status:** Accepted

### Context

The `tex_format_e` enum in `registers/rdl/gpu_regs.rdl` and the `FORMAT` field in `TEXn_CFG` (INT-010) were 3 bits wide, encoding seven formats with codes 0–6 (BC1, BC2, BC3, BC4, RGB565, RGBA8888, R8).
Adding BC5 as an eighth format would exhaust the 3-bit field entirely, leaving no reserved codes for future expansion.

### Decision

Widen the `FORMAT` field from 3 bits to 4 bits and renumber all format codes.
The new assignments group the BC family together (codes 0–4) followed by uncompressed formats (codes 5–7), with codes 8–15 reserved:

| Code | Format   |
| ---- | -------- |
| 0    | BC1      |
| 1    | BC2      |
| 2    | BC3      |
| 3    | BC4      |
| 4    | BC5      |
| 5    | RGB565   |
| 6    | RGBA8888 |
| 7    | R8       |
| 8–15 | Reserved |

No backwards compatibility is required.

### Rationale

Widening to 4 bits retains 8 reserved codes for future formats (e.g., BC6H, BC7, ETC2) without another field-width change.
Renumbering to group BC formats contiguously simplifies decoder mux address decoding and makes the encoding self-documenting.
The alternative — assigning BC5 to the last remaining code (7) and keeping a 3-bit field — would exhaust the encoding space and force another incompatible widening at the next addition.

### Consequences

`registers/rdl/gpu_regs.rdl` gains `BC5` and the field widens from `FORMAT[6:4]` to `FORMAT[7:4]`.
`registers/src/lib.rs` and generated SystemVerilog are updated to match.
All RTL format comparisons in `pixel_pipeline.sv`, `texture_cache.sv`, and the format-select mux use the new 4-bit codes.
INT-010 and UNIT-011 (with subunits UNIT-011.04, UNIT-011.05) are updated with the new encoding table.
VER-012 and VER-014 register-write sequences use `FORMAT=RGB565` code 5 (was 4); golden images require re-approval.

---

## DD-040: Switchable 18/36-bit Texture Cache Mode Bit in TEXn_CFG

**Date:** 2026-03-14
**Status:** Superseded

### Context

The texture cache can store texels in either 18-bit RGBA5652 format or 36-bit UQ1.8 format (see DD-037, DD-038).
A hard switch between the two formats would require recompilation or a global register; neither is practical when the host application may need one sampler at 18-bit (low-bandwidth, e.g. for a small tileset) and the other at 36-bit (high-quality, e.g. for a BC-compressed normal map).

### Decision

A per-sampler CACHE_MODE bit is added to TEXn_CFG (TEXn_FMT register, INT-010).
When CACHE_MODE=0, the sampler uses 18-bit RGBA5652 storage and 18-bit EBR mode.
When CACHE_MODE=1, the sampler uses 36-bit UQ1.8 storage and 36-bit EBR mode (DD-037).
Writing TEXn_CFG invalidates the corresponding cache regardless of CACHE_MODE value.

### Rationale

A per-sampler bit is the minimal change that gives the host full flexibility without adding a global configuration register.
The CACHE_MODE bit is naturally co-located with the FORMAT and FILTER fields that already control how texels are decoded; an application configures format and cache precision together in a single register write.
The invalidation-on-write rule (already required for FORMAT and BASE changes) covers CACHE_MODE changes at no additional cost.

### Consequences

INT-010 (GPU Register Map) gains a CACHE_MODE field in TEXn_FMT.
UNIT-011 (with UNIT-011.03 L1 cache and UNIT-011.04 block decompressor) documents the mode-bit semantics and per-mode EBR layout.
UNIT-011 (Texture Sampler) must route the CACHE_MODE bit from UNIT-003 to the cache bank address and promotion logic.
REQ-003.08 FR-131-5 is updated to reflect mode-selectable rather than fixed cache format.

### Superseded Note

**Date:** 2026-03-15

DD-040 has been superseded.
The 18-bit RGBA5652 cache mode has been removed; the texture cache now operates exclusively in UQ1.8 mode (36-bit, PDPW16KD 512×36).
The CACHE_MODE bit in TEXn_FMT is reserved and has no effect.
The UQ1.8 format provides superior precision for all source formats except RGB565 (which sees no quality difference), and the simplified single-mode design eliminates the dual-path promotion logic and EBR configuration complexity.
The RSVD_7 field in TEXn_FMT (INT-010) is documented as reserved.

---

## DD-039: Shift+Add Reciprocal-Multiply Replaces Verilog Division in BC Decoders

**Date:** 2026-03-14
**Status:** Proposed

### Context

The BC1/BC2/BC3 color interpolation formulas contain integer divisions by 3 (for the 1/3 and 2/3 lerp points in the 4-color palette) and BC3/BC4 alpha interpolation contains divisions by 5 and 7.
Synthesising these with the Verilog `/` operator causes Yosys to infer combinational dividers that consume 2–4 MULT18X18D DSP slices per decoder, eating into the tight DSP budget (16 slices total, 12–14 already allocated — see REQ-011.02 FR-051-1).
The divisions are by small compile-time constants over narrow operands (8-bit numerators), so exact closed-form multiply-shift formulas exist.

### Decision

Replace all Verilog `/` in BC decoder RTL with explicit shift+add reciprocal-multiply formulas:

- Divide by 3: `x/3 ≈ (x * 171) >> 9` — exact for 8-bit unsigned x.
- Divide by 5: `x/5 ≈ (x * 205) >> 10` — exact for 8-bit unsigned x.
- Divide by 7: `x/7 ≈ (x * 147) >> 10` — exact for 7-bit unsigned x (alpha values 0–255 map to 0–127 after halving, or use `(x * 37) >> 8` for values up to 255 with correct truncation).

Each multiply uses a constant coefficient; Yosys maps these to LUT logic rather than MULT18X18D blocks, consuming 0 DSP slices.

### Rationale

The DSP budget is fully committed (12–14 of 16 slices for rasterizer and color combiner).
Inferring even 2 additional DSP slices per BC decoder would overrun the budget across the four decoders (BC1–BC4).
Shift+add formulas for division by small constants are standard RTL practice; they produce identical results to integer division for the restricted operand ranges here.
The formulas are verifiable by exhaustive simulation over all 8-bit inputs.

### Consequences

BC1, BC2, BC3, and BC4 decoder RTL use shift+add formulas instead of `/`.
UNIT-011.04 (Block Decompressor) resource estimate for BC1 and BC2/BC3 decoders drops from 2–4 DSP slices to 0 DSP slices per decoder.
REQ-011.02 FR-051-1 DSP allocation table is updated to reflect 0 DSPs for BC decoders.
VER-005 step 6–9 test vectors remain valid (the computed values are unchanged).

---

## DD-038: UQ1.8 (9 bits per channel, 36-bit RGBA) as High-Quality Cache Storage Format

**Date:** 2026-03-14
**Status:** Proposed

### Context

The existing RGBA5652 cache format (R5 G6 B5 A2, 18 bits per texel) was chosen to fit one texel per 18-bit EBR word (see DD-010).
When BC-compressed textures are decompressed, the endpoint colors are 5-bit (R,B) or 6-bit (G) per channel; RGBA5652 preserves this precision exactly.
For RGBA8888 source textures, truncation to RGBA5652 loses 3 bits per channel of color precision and 6 bits of alpha precision.
The promotion from RGBA5652 to Q4.12 for the color combiner introduces a further approximation step.

### Decision

When CACHE_MODE=1 (DD-040), the cache stores texels in **UQ1.8** format: 9 unsigned fractional bits per channel, 4 channels (R, G, B, A), 36 bits per texel.
The UQ1.8 value 0x000 represents 0.0 and 0x100 represents 1.0 (256/256).
Source formats are converted as follows:

- R5 → UQ1.8: `{R5, R5[4:0], 3'b0}` → 9-bit value spanning [0, 255/256].
  Alternatively: `{R5, 4'b0}` to produce a value with resolution 1/16, padded with zero; the preferred mapping is `{R5, R5[4:1], 3'b0}` (bit-replicated expansion for approximate span to 1.0).
- G6 → UQ1.8: `{G6, G6[5:3], 3'b0}` — 9-bit.
- B5 → UQ1.8: same as R5.
- A8 → UQ1.8: `A8[7:0]` → directly the top 8 bits plus zero-extend to 9; exact mapping is `{A8, 1'b0}` to 9 bits.
- For BC endpoint promotion, each 5-bit or 6-bit endpoint is promoted to 8-bit using bit-replication before interpolation, and the 8-bit interpolated result maps to UQ1.8[8:1] (shift left by 1 to produce a 9-bit value).

Promotion from UQ1.8 to Q4.12 is: `{3'b000, channel_9bit, 3'b000}` for a 15-bit value, or equivalently left-shift by 3 to align the UQ1.8 integer bit to Q4.12 bit 12.

### Rationale

UQ1.8 preserves 8 bits per channel (one bit more than the 5/6/5 RGBA5652 fields), improving color fidelity especially for RGBA8888 and BC3/BC4 textures.
The 36-bit word width maps exactly to PDPW16KD 512×36 mode (DD-037), keeping one texel per EBR word.
The UQ1.8 → Q4.12 promotion is a simple left-shift with zero-pad, cheaper than the per-channel biased expansions required for RGBA5652 promotion.

### Consequences

UNIT-011.04 gains the UQ1.8 format definition, conversion tables from each source format, and UQ1.8 → Q4.12 promotion formula.
UNIT-011.04 `texel_promote.sv` gains a mode input selecting RGBA5652 or UQ1.8 promotion path.
VER-005 gains test vectors for UQ1.8 promotion (step 4 extended).
Golden images (VER-012, VER-014) require re-approval if the cache defaults to CACHE_MODE=1 for RGB565 textures.

---

## DD-037: PDPW16KD in 512×36 Mode for 36-bit Texture Cache Banks

**Date:** 2026-03-14
**Status:** Proposed

### Context

The existing texture cache uses DP16KD EBR primitives in 1024×18 mode, storing one RGBA5652 texel (18 bits) per address.
Each physical EBR block in the ECP5 is a 16Kbit resource that can be configured as 1024×16 (DP16KD) or 512×32 (PDPW16KD pseudo-dual-port wide mode).
The 512×36 configuration of PDPW16KD uses one physical EBR for the 32-bit data path and a second EBR's parity bits for the additional 4 bits, yielding 36 effective data bits per address — sufficient for a 36-bit UQ1.8 texel (DD-038).
The 512×36 PDPW16KD halves the address depth relative to 1024×18 DP16KD.

### Decision

When CACHE_MODE=1, each of the 4 interleaved banks per sampler instantiates a PDPW16KD in 512×36 mode rather than a DP16KD in 1024×18 mode.
The bank holds 512 entries × 4 texels per cache line = 2048 cache lines per bank.
With 4 banks and 256 sets × 4 ways (as in RGBA5652 mode), the total per-sampler capacity in 36-bit mode is: 4 banks × 512 entries = 2048 entries per bank ÷ 4 ways = 512 sets → reduced from 256 sets in 18-bit mode, or equivalently the effective per-sampler texel count drops from 16,384 to 8,192 in 36-bit mode.
The EBR count per bank remains 1 physical EBR in 36-bit mode because PDPW16KD 512×36 uses the parity bits of a single EBR block for the extra 4 bits; the nominal EBR count stays 4 EBR per sampler.

**Note (pending verification):** The exact EBR consumption of PDPW16KD 512×36 mode must be confirmed with Yosys/nextpnr synthesis before this decision is finalized.
If PDPW16KD 512×36 consumes 2 physical EBR per bank (rather than 1), the per-sampler EBR count doubles to 8, making the 2-sampler total 32 EBR — within the 39 EBR budget but consuming more headroom.
See the impact analysis recommended next steps in the analysis folder for the resolution path.

### Rationale

PDPW16KD 512×36 is the narrowest ECP5 EBR primitive that provides a 36-bit data word, matching the UQ1.8 texel width.
Using the parity bits of a single EBR block for the extra 4 bits avoids the area penalty of a second full EBR block just for 4 additional bits.
The address depth reduction (512 vs 1024 entries per bank) is acceptable in 36-bit mode because RGBA8888 and BC textures gain sufficient quality benefit to justify the smaller working set.

### Consequences

UNIT-011.03 documents PDPW16KD 512×36 as the EBR primitive for 36-bit mode banks.
REQ-011.02 EBR budget note must be updated once PDPW16KD EBR consumption is confirmed by synthesis.
UNIT-011.03 (L1 Decompressed Cache) internal state note is updated to reflect the mode-dependent bank depth.
The cache fill FSM address counter width narrows from 10-bit to 9-bit in 36-bit mode.

---

## DD-036: Sequential Time-Multiplexed Derivative Computation

**Date:** 2026-03-07
**Status:** Accepted

### Context

After DD-035 widened `inv_area` from Q4.12 (16-bit) to UQ4.14 (18-bit), the combinational derivative precomputation in `raster_deriv.sv` caused Yosys to infer 28 MULT18X18D blocks (one per `raw_dx * inv_area` and `raw_dy * inv_area` multiplication across 14 attributes).
The ECP5-25K provides only 28 MULT18X18D total, so the combinational approach consumed the entire DSP budget on derivative computation alone, leaving none for edge setup, reciprocal interpolation, or perspective correction.

### Decision

Convert `raster_deriv.sv` from purely combinational to sequential time-multiplexed derivative computation using 2 shared MULT18X18D blocks (the same pair used for edge C-coefficient computation in UNIT-005.02 and edge evaluation in UNIT-005.03 Phase 1).

The 14 attributes are processed one per clock cycle over 14 cycles (DERIV_0 through DERIV_13).
Each cycle, a 4-bit attribute index counter selects one attribute's precomputed `raw_dx` and `raw_dy` terms from a combinational mux tree.
Multiplier 0 computes `raw_dx * inv_area` (dAttr/dx) and multiplier 1 computes `raw_dy * inv_area` (dAttr/dy) simultaneously.
The multiplier outputs are latched into the corresponding derivative register each cycle.

Total derivative precomputation time increases from 3 cycles (ITER_START/INIT_E1/INIT_E2) to 17 cycles (3 edge evaluation + 14 derivative scaling).
The setup-iteration overlap FIFO (DD-035) absorbs most of this increased latency for sustained workloads.

### Rationale

- Reduces derivative DSP usage from 28 inferred MULT18X18D to 0 additional (reuses the existing 2 shared multipliers).
- Total UNIT-005 DSP budget remains at 8 MULT18X18D (unchanged from DD-035).
- The 14-cycle derivative window adds latency only to per-triangle setup, not to the per-pixel inner loop; for triangles larger than ~16 pixels, the setup-iteration overlap FIFO hides this cost entirely.
- The alternative of 1 shared multiplier (28 cycles for derivatives) was rejected because it would double the derivative computation time with no DSP saving; 2 multipliers compute dx and dy in parallel.

### Consequences

- Per-triangle setup latency increases from 6 cycles (3 edge setup + 3 derivative) to 20 cycles (3 edge setup + 3 edge evaluation + 14 derivative scaling).
- Small triangles (fewer pixels than the setup latency) see reduced throughput; the overlap FIFO mitigates this for back-to-back triangle streams.
- The `raster_deriv.sv` module gains a clock, reset, enable, and attribute index interface; it is no longer purely combinational.
- The FSM state encoding in `rasterizer.sv` adds 14 new DERIV states (or a single DERIV state with a 4-bit counter).

---

## DD-035: Dedicated DP16KD Reciprocal Modules with Setup-Iteration Overlap FIFO

**Date:** 2026-03-06
**Status:** Accepted

### Context

The rasterizer used a single shared `raster_recip_lut.sv` module with duplicated 257-entry case-statement ROMs for both inv_area (once per triangle) and per-pixel 1/Q computation.
Sharing a single reciprocal module forced sequential setup-then-iterate execution: the next triangle's setup could not begin until the current triangle's iteration completed, because both paths contended for the same LUT.
The case-statement ROMs consumed significant FPGA logic resources (large mux trees) and limited both precision (Q3.12, 256 entries) and throughput.

### Decision

Replace the shared `raster_recip_lut.sv` with two dedicated DP16KD-backed reciprocal modules:

- `raster_recip_area.sv`: 1 DP16KD in 36×512 mode for inv_area.
  9-bit CLZ index from 22-bit signed magnitude; 36-bit entries pack UQ1.17 seed + UQ0.17 delta for single-read linear interpolation.
  Output: UQ4.14 (18-bit, 2 extra fractional bits vs Q4.12).
  Optional compile-time Newton-Raphson refinement (1 extra MULT18X18D, 2-3 cycles).
- `raster_recip_q.sv`: 1 DP16KD in 18×1024 mode for per-pixel 1/Q.
  10-bit CLZ index from unsigned Q/W; 1024 UQ1.17 entries.
  2-cycle latency (BRAM read + MULT18X18D interpolation).
  Output: UQ4.14 (18-bit unsigned).

A compile-time configurable depth (default 2) register-based FIFO (~730 bits × depth, ~1460 FFs at depth 2) sits between the triangle setup producer and the edge-walk iteration consumer, enabling setup of triangle N+1 to overlap with iteration of triangle N.

### Rationale

- Eliminates large case-statement mux trees, trading logic for 2 DP16KD hard blocks (budget 37 to 39 of 56, 70%).
- Doubles or quadruples LUT entry count (512/1024 vs 256), improving reciprocal accuracy.
- Widens output from 16-bit Q4.12 to 18-bit UQ4.14, providing 2 extra fractional bits.
- Decoupling setup and iteration paths enables producer-consumer pipelining, eliminating setup stalls for sequences of small triangles.
- DSP impact: +1 MULT18X18D (was 7, now 8; 9 with Newton-Raphson), within the ≤16 budget.
- Perspective correction pipeline grows from 2 to 3 cycles (BRAM read latency), but steady-state throughput remains 1 fragment/cycle.

### Consequences

- EBR budget increases from 37 to 39 (70% of 56 available).
- UNIT-005 DSP budget increases from 7 to 8 MULT18X18D (9 with optional Newton-Raphson).
- Perspective correction pipeline latency increases from 2 to 3 cycles; small triangles see marginally higher pipeline drain cost.
- The setup-iteration overlap FIFO adds ~1460 FFs at depth 2.
- The old `raster_recip_lut.sv` with its duplicated case-statement ROMs is removed entirely.

## DD-034: Yosys-Compatible SystemVerilog Subset for Synthesis

**Date:** 2026-03-01
**Status:** Accepted

### Context

The FPGA build uses Yosys with `read_verilog -sv` for ECP5 synthesis (see DD-002).
Yosys supports a subset of SystemVerilog — it handles `package`, `typedef`, `logic`, `always_ff`/`always_comb`, and struct types, but does not support several SystemVerilog-only constructs including the `return` statement in functions.
Meanwhile, Verilator is used for linting and simulation and accepts full SystemVerilog.
Code that passes Verilator `--lint-only -Wall` can still fail Yosys synthesis.

### Decision

All synthesizable RTL must stay within the Yosys-supported SystemVerilog subset.
Key restrictions include:
- **No `return` in functions** — assign to the function name instead (Verilog-2005 style).
- **No `interface`/`modport`** — use explicit port lists.
- **No `unique case`/`priority case`** — use plain `case` with `default`.
- **No multi-dimensional packed arrays in ports** — flatten to single vectors.

Verilator remains the lint and simulation reference.
Both tools must accept the same source files.

### Rationale

- Yosys is the only open-source synthesis tool targeting ECP5; there is no alternative in the project's open-source toolchain (Yosys + nextpnr + ecppack).
- Verilator's broader SystemVerilog support makes it the better lint/sim tool, but synthesis compatibility is the binding constraint.
- Restricting to the common subset avoids "works in simulation, fails in synthesis" bugs like the `return` statement issue encountered in `fp_types_pkg.sv`.

### Consequences

- RTL authors must verify synthesis with `make synth` (not just `verilator --lint-only`) when using SystemVerilog features.
- The Verilog style guide (SKILL.md) should document Yosys-incompatible constructs to avoid.
- Functions use Verilog-2005 function-name assignment instead of `return`.


## DD-033: Power-of-Two Restriction for Render Targets and Textures

**Date:** 2026-03-01
**Status:** Accepted

### Context

The GPU uses 4x4 block-tiled addressing for framebuffers, Z-buffers, and textures.
Address computation from (x, y) to SDRAM byte offset requires knowing the surface width.
Hardware multiply on the critical path would consume scarce DSP resources and add latency.

### Decision

All surface widths and heights must be powers of two (non-square permitted).
Tiled address calculation uses only shifts and masks — no multiply hardware.
See ARCHITECTURE.md "Surface Tiling" for the address formula.

### Rationale

- The ECP5-25K has limited DSP resources (28 MULT18X18D slices).
  Shift-and-mask addressing is zero-cost in LUTs and zero-latency.
- Non-power-of-two widths would require a multiply per pixel address on the critical path.
- Render targets can be bound directly as texture sources (same tiled format), so the restriction applies uniformly.

### Alternatives Considered

1. **Allow arbitrary widths with multiply-based addressing**: Rejected — consumes DSP resources on the critical path and adds latency to every pixel address computation.
2. **Allow only specific non-power-of-two sizes (e.g., 640)**: Rejected — still requires multiply or lookup hardware; complexity for marginal benefit since display scaling handles the mismatch.

### Consequences

- The host must choose power-of-two dimensions for all render targets.
- Display scaling (512→640 or 256→640) handles the mismatch between power-of-two framebuffer and 640x480 DVI output.
- MEM_FILL clears any surface with a single linear fill because all blocks in a power-of-two surface are contiguous.

### References

- ARCHITECTURE.md: Surface Tiling section
- UNIT-008 (Display Controller — display scaling)

---


## DD-032: Fixed-Point Precision Across GPU Pipeline Stages

**Date:** 2026-03-01
**Status:** Accepted

### Context

Different GPU pipeline stages require different fixed-point precision to balance accuracy, register width, and DSP utilization on the ECP5-25K's 28 MULT18X18D slices.
A uniform precision strategy ensures that format boundaries are well-defined and conversion logic is minimized.

### Decision

The following fixed-point formats are used across the GPU pipeline:

| Stage | Format | Width | Notes |
|-------|--------|-------|-------|
| Vertex screen coordinates | Q12.4 signed | 16-bit | Per component (x, y) |
| Fragment depth (Z) | Unsigned | 16-bit | Full range [0, 65535] |
| Interpolated attributes | Q4.12 signed | 16-bit | color0, color1, UV0, UV1, Q/W |
| Fragment pipeline processing | Q4.12 signed RGBA | 16-bit/channel | Internal to UNIT-006 |
| Texture cache internal | RGBA5652 | 18-bit | Matches EBR native 1024x18 config |
| Framebuffer storage | RGB565 | 16-bit | One SDRAM column per pixel |
| Z-buffer storage | Unsigned | 16-bit | One SDRAM column per value |
| Barycentric derivatives | Q4.12 | 16-bit | dAttr/dx, dAttr/dy; computed once per triangle |

All fixed-point values use TI-style Q notation as defined in CLAUDE.md.

### Rationale

- Q4.12 provides 3 integer bits of headroom above 1.0 for additive blending in the color combiner (A−B)×C+D, plus 12 fractional bits to reduce accumulated quantization error through chained stages.
- The 16-bit total fits within the ECP5 DSP's 18x18 multipliers with room for guard bits.
- RGB565 framebuffer matches SDRAM native 16-bit column width, enabling one pixel per memory access.
- See ARCHITECTURE.md "Per-fragment data lanes" for the complete stage-by-stage data width table.

### Alternatives Considered

1. **Floating-point pipeline**: Rejected — the ECP5-25K has no floating-point hardware; soft-float would consume excessive LUTs and be too slow for real-time operation.
2. **Wider fixed-point (e.g., Q8.24)**: Rejected — exceeds the 18-bit DSP multiplier width, doubles register count, and increases EBR consumption without meaningful visual improvement at 640x480 resolution.
3. **Uniform 8-bit integer (RGBA8)**: Rejected — visible banding in multi-stage blend chains due to cumulative quantization error (see DD-011).

### Consequences

- All format boundaries (UNORM8 input → Q4.12, Q4.12 → RGB565 output) require explicit promotion/demotion logic.
- Dithering (DD-012) is applied at the final Q4.12 → RGB565 conversion to mitigate banding.
- DD-011's "10.8 fixed-point" notation refers to the same Q4.12 format viewed as UQ2.8 (pre-headroom) in the original design; the project uses Q4.12 notation uniformly.

### References

- ARCHITECTURE.md: Per-fragment data lanes table
- DD-011 (10.8 Fixed-Point Fragment Processing — original rationale)
- DD-012 (Blue Noise Dithering — final conversion stage)

---


## DD-031: SystemRDL as Authoritative Register Definition Source

**Date:** 2026-03-01
**Status:** Accepted

### Context

The GPU register map is consumed by both SystemVerilog RTL and Rust firmware.
A single authoritative source prevents divergence between hardware and software register definitions.

### Decision

`registers/rdl/gpu_regs.rdl` (SystemRDL) is the single source of truth for the GPU register map.
PeakRDL generates the SystemVerilog package and register module into `rtl/components/registers/generated/`.
`registers/src/lib.rs` provides the hand-maintained Rust constants crate (`gpu-registers`, `no_std`), matching the RDL.
Register specifications (INT-010 through INT-014) live in `doc/interfaces/` alongside other interface specs, but are not managed by syskit.

Change process:
1. Edit `registers/rdl/gpu_regs.rdl` and update `registers/src/lib.rs` to match
2. Update the corresponding markdown spec in `doc/interfaces/`
3. Run `registers/scripts/generate.sh` to regenerate SV
4. Review generated diffs
5. Update consuming code (`driver.rs`, `register_file.sv`) if register semantics changed

### Rationale

- SystemRDL is machine-readable and supports automated code generation, eliminating manual transcription errors between hardware and software.
- Register specs live in `doc/interfaces/` for discoverability but are excluded from syskit workflows to avoid overhead during frequent register iterations.
- The generated SV is checked into the repository so builds do not depend on PeakRDL being installed.

### Alternatives Considered

1. **Hand-maintained SV constants (no codegen)**: Rejected — drift risk between SV and Rust register definitions; manual synchronization is error-prone.
2. **Syskit-managed register specifications**: Rejected — the syskit impact/propose/approve workflow adds overhead unsuited to the rapid iteration cycle of register development.
3. **Generate Rust constants from RDL too**: Deferred — the Rust crate is small enough to maintain by hand; PeakRDL Rust output quality is evolving.

### Consequences

- All register changes start with the RDL file.
- INT-010 through INT-014 in `doc/interfaces/` contain the full specifications but are excluded from syskit workflows.
- Code referencing register values must use the generated SV package or the `gpu-registers` Rust crate, not hardcoded constants.

### References

- `registers/rdl/gpu_regs.rdl` (SystemRDL source)
- `registers/scripts/generate.sh` (code generation script)
- `registers/src/lib.rs` (Rust constants crate)

---


## DD-030: Code Style Conformance with Skill Guides

**Date:** 2026-03-01
**Status:** Accepted

### Context

The project has three language-specific style guides maintained as Claude skill files.
The relationship between these guides and CLAUDE.md inline rules needs a clear authority hierarchy to prevent duplication and divergence.

### Decision

All code must conform to its respective skill guide:
- SystemVerilog: `.claude/skills/claude-skill-verilog/SKILL.md`
- Rust: `.claude/skills/claude-skill-rust/SKILL.md`
- C++: `.claude/skills/claude-skill-cpp/SKILL.md`

CLAUDE.md references these guides but does not reproduce their content ("reference, don't reproduce").
Project-specific overlays (e.g., `defmt` for embedded logging, `thiserror` for library error types, `no_std` enum patterns) are documented in CLAUDE.md as supplements to the skill guides, not replacements.

### Rationale

- Centralizing style authority in skill files prevents divergence between CLAUDE.md inline rules and the skill file content.
- Skill files are loaded on demand by the development tool, providing full context without bloating CLAUDE.md.
- Project-specific overlays in CLAUDE.md capture conventions that are unique to pico-gs and not applicable to general-purpose style guides.

### Alternatives Considered

1. **Inline all style rules in CLAUDE.md**: Rejected — CLAUDE.md has an effective line budget; embedding full style guides (300+ lines each) would exceed the budget and create maintenance duplication.
2. **No central style enforcement (rely on linters only)**: Rejected — linters catch syntax and formatting but not architectural patterns (e.g., FSM structure, error handling strategy, module organization).

### Consequences

- Any style rule change must be made in the skill file, not CLAUDE.md.
- CLAUDE.md's Code Style sections contain only project-specific additions that supplement the skill guides.
- New contributors and tools should read the skill file for full style requirements.

### References

- `.claude/skills/claude-skill-verilog/SKILL.md`
- `.claude/skills/claude-skill-rust/SKILL.md`
- `.claude/skills/claude-skill-cpp/SKILL.md`
- CLAUDE.md: Code Style sections (project-specific overlays)

---


## DD-029: UNIT-005 RTL Module Decomposition

**Date:** 2026-03-01
**Status:** Accepted

### Context

The rasterizer (UNIT-005) implements four functionally distinct datapaths totaling ~1700 lines, far exceeding the ~500-line module guideline.
A single-file approach harms readability and maintainability at this scale.

### Decision

Decompose the rasterizer RTL into a parent module and three sub-modules:

| File | Lines | Content |
|------|-------|---------|
| `rasterizer.sv` | ~1100 | FSM, shared multiplier, vertex latches, edge setup, sub-module instantiation |
| `raster_deriv.sv` | ~340 | Purely combinational derivative precomputation (UNIT-005.03) |
| `raster_attr_accum.sv` | ~685 | Attribute accumulators, derivative registers, output promotion (UNIT-005.03/005.04) |
| `raster_edge_walk.sv` | ~275 | Iteration position, edge functions, fragment emission (UNIT-005.05) |

Sub-modules receive decoded control signals (`latch_derivs`, `step_x`, `step_y`, `init_pos_e0`, etc.) rather than the FSM state enum, keeping them decoupled from the FSM encoding.
The parent module's external port list is unchanged; `gpu_top.sv` requires no modifications.

### Rationale

- The `~500-line guideline and one-statement-per-line rule are incompatible with a single-file design at this register count.
- The derivative computation is naturally a purely combinational block (~340 lines) with no state — extracting it as a leaf module is a clear win.
- The attribute accumulator block owns 52 registers with self-contained stepping logic — a clean sequential sub-module boundary.
- The iteration/edge-walk logic owns 17 registers and the fragment output handshake — another clean sequential boundary.
- The ~500-line guideline and one-statement-per-line formatting rule are incompatible with a single-file design at this register count.

### Consequences

- Three new RTL files in `rtl/components/rasterizer/`.
- Makefile `RTL_SOURCES`, `HARNESS_RTL_SOURCES`, `SIM_RTL_SOURCES`, `test-rasterizer`, and lint targets updated.
- Testbench `tb_rasterizer.sv` internal signal paths updated (e.g., `dut.c0r_dx` → `dut.u_attr_accum.c0r_dx`).
- `rasterizer.sv` removed from `LEAF_LINT_FILES`; composite lint entry added.

### References

- UNIT-005 (Rasterizer), UNIT-005.02–005.05 (sub-units)

---


## DD-026: Arbiter Port 3 Sharing — Texture Cache vs. PERF_TIMESTAMP Writes

**Date:** 2026-02-28
**Status:** Proposed

### Context

UNIT-007 (Memory Arbiter) port 3 is used for texture cache fill burst reads by UNIT-011 (Texture Sampler), dispatched via UNIT-006 (Pixel Pipeline).
UNIT-003 (Register File) also drives `ts_mem_wr` / `ts_mem_addr` / `ts_mem_data` outputs that `gpu_top.sv` must forward to port 3 as single-word SDRAM writes when a `PERF_TIMESTAMP` register write occurs.
Both sources compete for the same arbiter port, and no sharing mechanism was previously specified.

### Decision

Manage port 3 contention entirely within `gpu_top.sv` using a latch-and-serialize scheme:

1. A pending-write register in `gpu_top.sv` captures `ts_mem_wr` / `ts_mem_addr` / `ts_mem_data` from UNIT-003.
   If a new `ts_mem_wr` pulse arrives while a previous write is still pending, the new data overwrites the pending register (fire-and-forget; back-to-back timestamps may coalesce).
2. `gpu_top.sv` drives `port3_req` by OR-ing UNIT-011's texture fill request with the pending timestamp write request.
   UNIT-011's texture request is checked first; the timestamp write is only injected onto port 3 when UNIT-011 is not asserting a texture request.
3. No modifications to UNIT-007 (sram_arbiter.sv) are required.

### Rationale

The simplest correct solution that avoids arbiter redesign.
Texture fills are latency-sensitive (the pipeline stalls during a cache miss) while timestamp writes are fire-and-forget with no consumer waiting on the result.
Giving texture fills unconditional priority on port 3 preserves cache miss latency.
The coalescing behavior on back-to-back timestamp writes is acceptable: `PERF_TIMESTAMP` is a diagnostic facility, not a high-frequency counter; a missed timestamp write means a missed profiling sample, not a rendering error.

### Alternatives Considered

1. **Add port 4 to the arbiter for timestamp writes:** Rejected — adds arbiter complexity, additional port routing, and uses additional FPGA resources, all for a diagnostic path.
2. **Route timestamp writes through port 1 (framebuffer):** Rejected — contaminates the framebuffer port's traffic pattern and complicates UNIT-006's port 1 ownership.
3. **Use a priority mux at port 3 with explicit arbitration logic:** Rejected — equivalent complexity to the latch-and-serialize scheme but harder to reason about; the `gpu_top.sv` approach is localized and easier to verify.

### Consequences

- Port 3 sharing is a `gpu_top.sv` concern; UNIT-006, UNIT-007, and UNIT-003 are unaffected.
- `PERF_TIMESTAMP` writes may be delayed (but not lost, unless a second write arrives within the same interval) while a texture fill burst holds port 3.
- Back-to-back `PERF_TIMESTAMP` writes with no intervening idle cycle on port 3 will coalesce; firmware must space timestamps by at least one RGBA8888 cache fill (32 words, ~35 cycles at 100 MHz worst-case) for reliable capture.

### References

- UNIT-003 (Register File — ts_mem_wr / ts_mem_addr / ts_mem_data)
- UNIT-011 (Texture Sampler — texture cache fill, port 3 burst reads)
- UNIT-007 (Memory Arbiter — port 3 fixed-priority, max burst 32 words)

---


## DD-025: Rasterizer Fragment Output Interface — Valid/Ready Handshake to Pixel Pipeline

**Date:** 2026-02-28
**Status:** Proposed

### Context

Before this change, the rasterizer (UNIT-005) held ownership of SDRAM arbiter ports 1 (framebuffer write) and 2 (Z-buffer read/write) and performed direct SDRAM writes for each passing fragment.
This coupling prevented the pixel pipeline (UNIT-006) from being inserted between the rasterizer and SDRAM, blocking texture sampling, color combining, alpha blending, and dithering from being applied to each fragment.
The pixel pipeline stub existed but had no live connection to consume rasterizer output.

### Decision

Refactor the rasterizer to emit per-fragment data to UNIT-006 via a valid/ready handshake instead of performing direct SDRAM writes.
The fragment bus carries: (x, y) screen coordinates, interpolated Z (16-bit), interpolated color0 and color1 (Q4.12 RGBA), interpolated UV0 and UV1 (Q4.12 per component), and interpolated Q/W (Q3.12).
SDRAM arbiter ports 1 and 2 transfer to UNIT-006 ownership.
The rasterizer asserts `frag_valid` when a fragment is ready; it stalls (holds state) when UNIT-006 deasserts `frag_ready`.

### Rationale

The valid/ready handshake is the standard backpressure mechanism already used between UNIT-003 and UNIT-005.01 (`tri_valid` / `tri_ready`).
Using the same pattern keeps the design consistent and allows the pixel pipeline to stall the rasterizer when the texture cache or Z-buffer tile cache is servicing a miss.
Transferring port 1 and port 2 ownership to UNIT-006 allows it to control all framebuffer and Z-buffer accesses in coordination with texture cache fills, enabling early Z-test (check Z before issuing texture fetch) and correct write-back ordering.

### Alternatives Considered

1. **FIFO between rasterizer and pixel pipeline:** Increases EBR consumption and adds latency without improving throughput in steady state.
   The valid/ready handshake is sufficient because the rasterizer stalls cheaply (it just stops incrementing its edge accumulators).
2. **Keep rasterizer owning port 1 / port 2, add separate port for pixel pipeline:** Requires expanding the arbiter to 5 ports or merging framebuffer and Z-buffer traffic onto one port, both more complex than transferring ownership.

### Consequences

- UNIT-005 no longer accesses SDRAM directly; its implementation is simplified.
- UNIT-006 must accept backpressure from the arbiter and propagate it upstream to UNIT-005 via `frag_ready`.
- VER-001 testbench must be updated to drive `frag_ready` and observe the fragment output bus rather than observing SDRAM write transactions.
- VER-010 and VER-011 golden images may require re-approval if incremental interpolation (DD-024) changes interpolated pixel values.

### References

- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)
- UNIT-007 (Memory Arbiter — port 1 and port 2 ownership)
- DD-024 (Incremental Interpolation — prerequisite for this interface change)

---


## DD-024: Incremental Attribute Interpolation Replacing Per-Pixel Barycentric MAC

**Date:** 2026-02-28
**Status:** Proposed

### Context

The rasterizer previously computed per-pixel attribute values (color, Z, UV, Q) by multiplying 17-bit barycentric weights by per-vertex attribute values on every fragment inside the triangle.
This required 17×8 multiplies per color channel and 17×16 for Z, consuming approximately 17 MULT18X18D DSP blocks on the ECP5-25K (which has only 28).
Adding UV0, UV1, and Q/W interpolation for textured rendering would require an additional 3–4 DSP blocks, exhausting the available budget and leaving none for the color combiner (4–6 DSPs) or BC texture decoders (2–4 DSPs each).

### Decision

Replace per-pixel barycentric multiply-accumulate with precomputed attribute derivative increments.
Once per triangle (during the ITER_START / INIT_E1 / INIT_E2 window, 3 cycles shared with edge evaluation), compute `dAttr/dx` and `dAttr/dy` for each interpolated attribute (color0, color1, Z, UV0, UV1, Q/W) from the three vertex values and `inv_area`.
In the per-pixel inner loop, update each accumulated attribute value by adding `dAttr/dx` when stepping right in X and `dAttr/dy` when advancing to a new row.
No multiplies are required in the inner loop.

### Rationale

Edge functions are already stepped incrementally by adding the A and B coefficients; the same technique applies to any linearly varying attribute.
Attribute derivatives are computed using the same shared 11×11 multiplier pair already used for edge C coefficients, serialized over the same 3-cycle window — no additional DSP blocks are required for setup.
The per-pixel inner loop becomes pure addition, reducing DSP usage for interpolation from ~17 blocks to 3–4 (the shared setup pair plus any output-stage promotion).
This frees 13–14 DSP blocks, creating headroom for color combiner (UNIT-010, 4–6 DSPs), BC1/BC4 decoders (2–4 DSPs), and BC2/BC3 decoders (2–4 DSPs).

### Alternatives Considered

1. **Keep barycentric MAC, remove UV/Q interpolation:** Rejected — perspective-correct UV interpolation (REQ-003.06) requires Q/W per fragment; eliminating it would block all textured rendering with correct perspective.
2. **Use a wider FPGA (ECP5-45K or ECP5-85K):** Rejected — the ECP5-25K on the ICEpi Zero is fixed.
3. **Move interpolation to a follow-on pipeline stage using sequential DSP reuse:** Rejected — increases pipeline latency and complicates the rasterizer FSM without reducing total DSP count (the multiplies still happen; they are just deferred).

### Consequences

- The rasterizer inner loop (EDGE_TEST → INTERPOLATE → ITER_NEXT) no longer contains multiplies; the critical path is reduced to addition chains.
- UNIT-005 DSP usage drops from ~17 to 3–4 MULT18X18D blocks; the freed DSPs are allocated to UNIT-006 and UNIT-010.
- Incremental accumulation introduces small rounding drift across long scanlines; maximum drift is bounded by `scanline_length × (resolution of derivative representation)` and is negligible at 640-pixel width with 16-bit fractional attribute accumulators.
- VER-001 must verify derivative precomputation accuracy and incremental stepping fidelity rather than the former barycentric weight computation.

### References

- UNIT-005 (Rasterizer — algorithm and DSP budget)
- UNIT-011 (Texture Sampler — DSP headroom for texture decoders)
- UNIT-010 (Color Combiner — DSP budget)
- REQ-003.06 (Texture Sampling — perspective-correct UV)
- REQ-011.02 (Resource Constraints — DSP budget)

---


## DD-023: Standalone C++/Lua Verilator Simulator Instead of Rust SimTransport

**Date:** 2026-02-26
**Status:** Accepted

### Context

The Verilator interactive simulator needs to drive the GPU RTL model for live visual debugging.
A key question was whether this simulator should implement a Rust `SpiTransport` shim, allowing host application driver code to run against the Verilator model without modification.
The host application driver code has moved to the pico-racer repository; this repo retains only the GPU RTL and test harness.

### Decision

The Verilator interactive simulator is implemented as a standalone C++/Lua binary that drives the GPU RTL out-of-band via `SIM_DIRECT_CMD` injection ports, bypassing SPI serial framing entirely.
It does not implement a Rust `SpiTransport` shim.

### Rationale

A standalone C++ application is simpler to build, avoids Rust/C FFI complexity, and delivers the core use case (live visual debug with Lua scripting) immediately.
The `SIM_DIRECT_CMD` path presents the same logical 72-bit format (`{rw[0], addr[6:0], data[63:0]}`) to the FIFO write port that the SPI slave would present after deserializing a transaction, so the RTL behavior is exercised faithfully.
Since the host application code lives in pico-racer, there is no Rust workspace in this repo against which a `SimTransport` would be useful.

### Consequences

- The interactive simulator is a standalone C++/Lua binary in `integration/sim/`; it does not require a Rust workspace.
- The GPU RTL is tested via direct command injection at the INT-010 register-write level, matching what the physical SPI host produces.

## DD-022: SystemVerilog Style Guide Conformance

**Date:** 2026-02-16
**Status:** Accepted

### Context

All RTL files must conform to a consistent coding style for safety (`\`default_nettype none`), maintainability (separated FSMs), and lint hygiene (zero verilator warnings without pragmas).

### Decision

All SystemVerilog files in `rtl/components/*/` and `integration/` conform to the project style guide (`.claude/skills/claude-skill-verilog/SKILL.md`).
Key requirements enforced:
- `\`default_nettype none` in every file
- `always_ff` contains only flat `reg <= next_reg` assignments; all logic in companion `always_comb` blocks
- FSMs use separate state register, next-state `always_comb`, and datapath blocks
- Explicit bit widths on all literals; no `'0` shorthand
- No verilator lint pragmas; unused signals use named wire patterns
- All files pass `verilator --lint-only -Wall` with zero warnings

### Rationale

- `\`default_nettype none` catches undeclared nets at compile time, preventing subtle synthesis bugs.
- Separated FSMs make state transitions explicit and simplify formal verification.
- Zero-warning lint policy ensures verilator remains a useful regression gate.

### Alternatives Considered

1. **Incremental per-feature remediation**: Fix style issues only when modifying a file for other reasons.
   Rejected — leaves the codebase in an inconsistent state indefinitely.
2. **Automated formatting tool**: Use a SystemVerilog formatter.
   Rejected — no mature tool handles FSM restructuring or semantic changes (e.g., wire→logic, adding default cases).

### Consequences

- All new and modified RTL files must pass the style guide and lint checks before merging.
- Module interfaces and behavior are unchanged by style conformance; all changes are structural/stylistic.

### References

- `.claude/skills/claude-skill-verilog/SKILL.md` (authoritative style guide)

---


## DD-021: SDRAM Controller Architecture for W9825G6KH

**Date:** 2026-02-15
**Status:** Proposed
**Implementation:** RTL PENDING

### Context

The original GPU design used an async SRAM controller (sram_controller.sv) with a fictional SRAM part.
The target hardware, the ICEpi Zero board, actually has a Winbond W9825G6KH-6 synchronous DRAM (32 MB, 16-bit data bus) instead of async SRAM.
The FPGA package is CABGA256 (not CABGA381 as previously specified).
The async SRAM controller's FSM, pin constraints, and timing assumptions are all incorrect for the actual hardware.

### Decision

Replace the async SRAM controller with a synchronous DRAM controller for the W9825G6KH:

1. **SDRAM controller FSM**: An 8-state FSM (INIT, IDLE, ACTIVATE, READ, WRITE, PRECHARGE, REFRESH, DONE) handles the full SDRAM command protocol including initialization, auto-refresh, row activation, CAS latency management, and precharge timing.

2. **PLL configuration**: Add a 90-degree phase-shifted 100 MHz clock output from the PLL for the SDRAM chip clock (sdram_clk).
   The phase shift ensures data is valid and centered relative to the internal clock edge, compensating for PCB trace delays.

3. **Pin constraints**: Replace fictional SRAM pin assignments with real SDRAM pins from the ICEpi Zero board reference LPF file.
   Signals: sdram_a[12:0], sdram_dq[15:0], sdram_ba[1:0], sdram_dqm[1:0], sdram_csn, sdram_cke, sdram_clk, sdram_wen, sdram_casn, sdram_rasn.

4. **FPGA package**: Correct from CABGA381 to CABGA256 in the Makefile and synthesis scripts.

5. **Preserved arbiter interface**: The existing arbiter interface (req/we/addr/wdata/rdata/ack/ready/burst) is preserved.
   The SDRAM controller internally decomposes byte addresses into bank/row/column, manages row activation and precharge, and handles CAS latency.
   The arbiter and all upstream requestors are unchanged.

6. **Auto-refresh scheduling**: The SDRAM controller maintains a refresh timer and inserts AUTO REFRESH commands at the required rate (8192 refreshes per 64 ms = one every 781 cycles at 100 MHz).
   When refresh is due, mem_ready deasserts to block new arbiter grants.

### Rationale

- **Correct hardware target**: The ICEpi Zero board has SDRAM, not SRAM. The previous design was based on a fictional part.
- **Preserved interface**: By keeping the arbiter interface unchanged, all upstream modules (display controller, pixel pipeline, texture cache) require no modification.
- **PLL phase shift**: Industry-standard technique for SDRAM interfacing on FPGAs. The 90-degree shift provides optimal data sampling margin.
- **CAS latency 3**: The W9825G6KH-6 supports CL=2 or CL=3 at 100 MHz. CL=3 is selected for reliable timing with margin.

### Alternatives Considered

1. **Keep async SRAM design with a different board**: Rejected -- the ICEpi Zero is the target hardware.
2. **Use SDRAM burst mode (hardware auto-increment)**: Rejected -- controller-managed sequential access (issuing individual READ/WRITE commands to consecutive columns) provides more flexibility for preemption and row boundary handling. The SDRAM mode register is set to burst length 1.
3. **CAS latency 2**: Rejected -- CL=2 at 100 MHz leaves minimal timing margin. CL=3 provides a safer margin with only ~6 cycle overhead per access sequence (negligible for long sequential transfers).

### Consequences

**Hardware (RTL):**
- sram_controller.sv replaced by sdram_controller.sv with 8-state FSM
- gpu_top.sv updated to wire SDRAM signals instead of SRAM signals
- PLL configuration extended with 90-degree phase-shifted output for sdram_clk
- Pin constraints rewritten for ICEpi Zero board SDRAM pins
- Makefile updated for CABGA256 package
- SDRAM controller uses ~200-300 LUTs, ~100-150 FFs (larger than the ~150 LUT async SRAM controller, but includes initialization, refresh timer, and full command sequencing)
- One additional PLL output used (from 3 to 4 outputs)

**Firmware (Rust):**
- No changes required. SDRAM management is entirely internal to the FPGA.

**Performance:**
- Positive: Correct hardware interface means the design actually works on real hardware
- Neutral: Sequential access throughput is similar to async SRAM burst mode (1 word/cycle after initial overhead)
- Negative: Single random-access reads are slower (~12 cycles vs ~3 cycles) due to ACTIVATE + tRCD + CAS latency
- Negative: Auto-refresh consumes ~0.8% of bandwidth (negligible)
- Negative: SDRAM contents are volatile (lost on power loss), unlike SRAM

### References

- INT-011: SDRAM Memory Layout (timing specs, bandwidth budget)
- UNIT-007: Memory Arbiter (preserved interface)
- INT-002: DVI TMDS Output (PLL configuration update)
- REQ-011.01: Performance Targets (bandwidth recalculation)
- REQ-011.02: Resource Constraints (SDRAM controller resource estimate)
---


## DD-019: Pre-Populated Command FIFO Boot Screen

**Date:** 2026-02-14
**Status:** Proposed
**Implementation:** RTL PENDING

### Context

After FPGA power-on and PLL lock, the display controller begins scanning out framebuffer data from SRAM immediately.
Because SRAM contents are uninitialized, the display shows random noise until the host firmware completes its boot sequence (~100 ms) and sends the first frame of GPU commands over SPI.
There is no visual indication that the FPGA is operational during this period, making it difficult to distinguish a functioning but uninitialized GPU from a non-functional one.

The existing command FIFO (UNIT-002) uses a Lattice EBR FIFO macro (`async_fifo.sv`, WIDTH=72, DEPTH=16) which always resets empty on power-up, so there is no mechanism for the FPGA to execute GPU commands autonomously.

### Decision

Replace the Lattice EBR FIFO macro with a custom soft FIFO implementation backed by a regular memory array whose initial contents are baked into the FPGA bitstream.
On power-up, the FIFO starts non-empty with ~18 pre-populated register write commands that execute a self-test boot screen:

1. Write FB_DRAW to set the back buffer base address (Framebuffer A)
2. Set RENDER_MODE to flat shading (Gouraud disabled)
3. Write COLOR with black (0x000000FF diffuse) for screen clear
4. Submit 6 VERTEX writes (2 screen-covering triangles) to clear the framebuffer to black
5. Set RENDER_MODE to Gouraud shading enabled
6. Write COLOR with red, green, and blue vertex colors (3 COLOR + 3 VERTEX_KICK writes) to draw a centered RGB triangle
7. Write FB_DISPLAY to present Framebuffer A as the front buffer

The FIFO depth increases from 16 to 32 entries to accommodate the boot sequence (~18 commands) while retaining sufficient free space for SPI-sourced commands during normal operation.

Key implementation details:
- The soft FIFO uses gray-coded CDC pointers for the async clock domain crossing (SPI write clock to system read clock), identical to the original design
- The write pointer is initialized past the pre-populated entries (boot command count); the read pointer starts at zero
- CMD_EMPTY will not assert until all boot commands are consumed
- The memory array uses `initial` blocks or `$readmemh` for bitstream initialization, which standard synthesis tools (Yosys, Lattice Diamond) support for regular memory arrays but not for EBR FIFO macros

### Rationale

- **Visual self-test**: A colored triangle on screen immediately after PLL lock proves the FPGA bitstream is loaded, the rasterizer works, SRAM writes succeed, and the display controller scans out correctly -- all without any host involvement
- **Deterministic boot screen**: The boot sequence completes in ~0.18 us at 100 MHz (18 commands x 10 ns each), well before the host's first SPI transaction (~100 ms), so there is no race condition
- **Soft FIFO necessity**: Lattice EBR FIFO macros do not support memory initialization; a regular memory array with `initial`/`$readmemh` is the only way to pre-populate FIFO contents in the bitstream
- **FIFO depth 32**: 18 boot commands in a 16-deep FIFO would leave no room for SPI commands; 32 entries provide 14 free slots after boot, sufficient for the SPI write rate (~2.88 us per command vs ~20 ns per FIFO read)
- **No hardware cost increase**: 72-bit x 32-deep = 2,304 bits, well within distributed RAM budget; no additional EBR blocks consumed

### Alternatives Considered

1. **Host-driven boot screen**: Have the RP2350 send a boot screen immediately after GPU detection.
   Rejected -- adds ~100 ms delay before any visual output; does not prove FPGA is working independently of host.

2. **Dedicated boot ROM FSM**: A separate RTL state machine that generates register writes at reset.
   Rejected -- adds LUT/FF cost for a one-time operation; pre-populated FIFO achieves the same result with zero additional logic.

3. **Keep Lattice FIFO macro, add separate boot command generator**: Feed boot commands through a mux into the existing FIFO.
   Rejected -- more complex than replacing the FIFO; the mux and boot generator add logic; the soft FIFO is simpler and also enables future diagnostic command injection.

4. **Keep FIFO depth at 16, shorten boot sequence**: Use fewer commands (e.g., skip the screen clear).
   Rejected -- a 16-deep FIFO with 18 boot commands cannot work; even with a shorter sequence, minimal headroom increases the risk of overflow from early SPI traffic.

### Consequences

**Hardware (RTL):**
- UNIT-002: `async_fifo.sv` replaced with custom soft FIFO module; same gray-coded CDC interface; memory array initialized via `$readmemh` or `initial` block
- UNIT-002: FIFO depth increases from 16 to 32 (DEPTH parameter change)
- Resource impact: 72-bit x 32-deep = 2,304 bits distributed RAM (no EBR change); ~50 additional LUTs for wider gray-code pointers (5-bit vs 4-bit)
- INT-012: FIFO depth references updated from 16 to 32
- INT-013: CMD_EMPTY behavior note added for boot state

**Boot Screen Content:**
- Framebuffer A cleared to black via two flat-shaded screen-covering triangles
- Centered Gouraud-shaded triangle with red (top), green (bottom-left), blue (bottom-right) vertex colors
- Framebuffer A presented as the display source

**Firmware (Rust):**
- No firmware changes required; the boot screen is entirely autonomous
- Host `gpu_init` will observe CMD_EMPTY=1 (boot commands already drained) on first contact
- The host's initial FB_DRAW/FB_DISPLAY writes overwrite the boot screen's framebuffer configuration, which is the expected behavior

**Performance:**
- Positive: Immediate visual feedback on power-up (vs ~100 ms delay)
- Neutral: Boot command drain time (~0.18 us) is negligible
- Neutral: No steady-state performance impact (boot commands are consumed once)

### References

- UNIT-002: Command FIFO (primary implementation target)
- REQ-001.04: Command Buffer FIFO (functional requirement)
- INT-012: SPI Transaction Format (FIFO depth references)
- INT-013: GPIO Status Signals (CMD_EMPTY boot behavior)
- INT-010: GPU Register Map (registers used by boot sequence)
- states_and_modes.md: Boot Command Processing state

---


## DD-018: Early Z-Test, Depth Range Clipping, and Per-Material Color Write Enable

**Date:** 2026-02-13
**Status:** Proposed
**Implementation:** RTL PENDING, RUST PENDING

### Context

The pixel pipeline (UNIT-006) currently performs the Z-buffer test at Stage 5, after texture cache lookup, texture sampling, format promotion, multi-texture blending, and vertex color modulation.
When a fragment fails the Z-test, all texture fetches and blending computations for that fragment are wasted.
In scenes with high overdraw (multiple overlapping objects), this wastes significant SRAM bandwidth and pipeline cycles on fragments that will never be visible.

Additionally, there is no mechanism to discard fragments by depth range (analogous to X/Y scissor), and the COLOR_WRITE_EN flag is located in FB_CONTROL (0x43) rather than alongside other per-material render controls in RENDER_MODE (0x30).

### Decision

Three related changes to the pixel pipeline and register layout:

1. **Early Z-Test**: Move Z-buffer read and depth comparison from Stage 5 to Stage 0.
   If a fragment fails, skip all subsequent stages.
   Z-buffer write remains at Stage 6.
   Bypassed when Z_TEST_EN=0 or Z_COMPARE=ALWAYS.

2. **Depth Range Clipping (Z Scissor)**: Add Z_RANGE register at 0x31 with Z_RANGE_MIN [15:0] and Z_RANGE_MAX [31:16].
   Fragments outside [MIN, MAX] are discarded before any SRAM access.
   When MIN=0x0000 and MAX=0xFFFF, all fragments pass (disabled).

3. **Per-Material Color Write Enable**: Move COLOR_WRITE_EN from FB_CONTROL (0x43, bit 41) to RENDER_MODE (0x30, bit 4).
   Groups all per-material write controls in a single register.

### Rationale

**Early Z-Test:**
- Eliminates wasted texture fetches for occluded fragments
- In high-overdraw scenes (3-4x), ~60-75% of fragments fail the Z-test
- Bypass conditions checked combinationally at zero cost

**Depth Range Clipping:**
- Zero-cost rejection: register comparison only, no SRAM access
- Register address 0x31 freed (previously ALPHA_BLEND)
- Analogous to X/Y scissor, completing the 3D scissor volume

**Per-Material Color Write Enable:**
- Reduces register writes per material change
- Groups related controls: Z_TEST_EN (bit 2), Z_WRITE_EN (bit 3), COLOR_WRITE_EN (bit 4)

### Alternatives Considered

1. **Late Z-test only**: Rejected -- texture fetches for occluded fragments are the primary bandwidth waste.
2. **Hierarchical Z-buffer (Hi-Z)**: Rejected -- requires additional BRAM. Could be a future enhancement.
3. **Separate Z_RANGE_MIN and Z_RANGE_MAX registers**: Rejected -- both fit in a single 32-bit register.
4. **Keep COLOR_WRITE_EN in FB_CONTROL**: Rejected -- requires extra register write per material.

### Consequences

**Hardware (RTL):**
- UNIT-006: Pipeline reordered; new Stage 0 with Z-buffer read + compare + depth range check
- UNIT-003: New Z_RANGE register decode; COLOR_WRITE_EN routing from RENDER_MODE
- UNIT-007: Z-buffer read requests arrive before texture read requests

**Host Application (external):**
- pico-racer: `gpu_set_z_range()` and `gpu_set_render_mode()` updated for COLOR_WRITE_EN; code using FB_CONTROL[41] must move to RENDER_MODE[4]

**Performance:**
- Positive: Eliminates wasted texture bandwidth for occluded fragments
- Positive: Depth range clipping is free (register comparison only)
- Neutral: No additional BRAM consumption
- Neutral: Pipeline latency unchanged for passing fragments

### References

- INT-010, INT-011, UNIT-006, REQ-005.07

---


## DD-010: Per-Sampler Texture Cache Architecture

**Date:** 2026-02-10
**Status:** Accepted
**Implementation:** RTL PENDING

### Context

Bilinear texture sampling with 4 texture units requires up to 16 SRAM reads per pixel (4 texels x 4 units). At 200 MB/s peak SRAM bandwidth shared with display scanout, Z-buffer, and framebuffer writes, texture fetch bandwidth is the primary bottleneck for textured rendering. The 30 MB/s texture fetch budget (INT-011) is insufficient for multi-textured bilinear sampling.

### Decision

Add a 4-way set-associative texture cache per sampler (4 caches total):
- 4 x 1024 x 18-bit EBR banks per cache, interleaved by texel (x%2, y%2) for single-cycle bilinear reads
- Cache line = decompressed 4x4 RGBA5652 block (18 bits per texel)
- 64 sets with XOR-folded indexing (set = block_x ^ block_y) to prevent row aliasing
- Implicit invalidation on TEXn_BASE/TEXn_FMT register writes
- 16 EBR blocks total (288 Kbits, 33% of BRAM budget)

### Rationale

- **4-way associativity**: Handles block-boundary bilinear (2 ways for adjacent blocks), mip-level block (1 way), and one spare. 2-way would thrash at block boundaries; 8-way has diminishing returns with higher LUT cost for tag comparison
- **RGBA5652 (18-bit)**: Matches ECP5 EBR native 1024x18 configuration (zero wasted bits). RGB565 base is framebuffer-compatible. 2-bit alpha covers BC1 punch-through alpha
- **XOR set indexing**: Linear indexing maps every block row (e.g., 64 blocks for 256-wide texture) to the same 64 sets, causing vertically adjacent blocks to always alias. XOR is zero-cost in hardware (XOR gates on address bits) and eliminates this systematic aliasing. No impact on asset pipeline or physical memory layout
- **Per-sampler caches**: Avoids contention between texture units; each cache operates independently with its own tags and replacement policy

### Consequences

- +16 EBR blocks consumed (28.6% of ECP5-25k's 56 EBR). Leaves 37 EBR blocks free
- +~800-1600 LUTs total for tag storage, comparison, control logic, and fill FSMs across all 4 samplers
- Enables single-cycle bilinear texture sampling at >85% cache hit rate
- BC1 decompression cost amortized over cache line lifetime (16 texels per decompress)
- RGBA4444 alpha precision reduced from 4-bit to 2-bit in cache (acceptable: framebuffer has no alpha channel)
- Texture SRAM bandwidth reduced from ~30 MB/s to ~5-15 MB/s average, freeing ~15-25 MB/s for other consumers

---


## DD-011: 10.8 Fixed-Point Fragment Processing

**Date:** 2026-02-10
**Status:** Accepted
**Implementation:** RTL PENDING

### Context

8-bit integer fragment processing (RGBA8) causes visible banding artifacts in smooth gradients due to cumulative quantization errors across multiple blending stages (texture blend × vertex color × alpha blend). Each multiply reduces precision, and truncation compounds errors through the chain. The ECP5-25K FPGA has 28 DSP slices with native 18×18 multipliers.

### Decision

Use always-on 10.8 fixed-point format (18 bits per channel) for all internal fragment processing:
- 10 integer bits: 8 for the [0,255] input range + 2 bits overflow headroom for additive blending
- 8 fractional bits: preserve precision through multiply chains
- No configurable mode — always-on replaces RGBA8 math permanently

### Rationale

- **Matches hardware**: ECP5 DSP slices are 18×18 — wider inputs are free in silicon, no reason for a narrow mode
- **Overflow headroom**: 2 extra integer bits prevent clipping during additive texture blending (ADD, SUBTRACT modes)
- **Precision preservation**: 8 fractional bits retain sub-pixel accuracy through multiply chains (8×8→16-bit result retained)
- **Simplicity**: No configurable precision mode reduces hardware complexity and validation effort
- **Alternatives considered**: RGBA8 (insufficient for cumulative blending), 16-bit integer (doesn't match DSP width), floating-point (too expensive in FPGA LUTs)

### Consequences

- +6-12 DSP slices for 18×18 multipliers (texture blend, vertex color, alpha blend)
- +~1500-2500 LUTs for wider datapaths and saturation logic
- Eliminates visible banding in multi-stage blend chains
- Vertex color input (RGBA8888 UNORM8 register) promoted to 10.8 on entry: `value_10_8 = {2'b0, value_8, 8'b0}`
- See REQ-004.02 for full specification

---


## DD-012: Blue Noise Dithering for RGB565 Conversion

**Date:** 2026-02-10
**Status:** Accepted
**Implementation:** RTL PENDING

### Context

Converting 10.8 fixed-point fragment colors to RGB565 format discards fractional bits and reduces integer precision (10→5/6/5 bits), causing visible banding in smooth gradients. Dithering trades spatial resolution for color resolution, creating the perception of smoother gradients than the output format can represent.

### Decision

Use a 16×16 blue noise dither pattern stored in 1 EBR block:
- 256 entries × 18 bits (native ECP5 1024×18 configuration)
- 6 bits stored per component (R, G, B) packed into 18 bits per entry
- Channel-specific scaling: top 3 bits for R/B (losing 3 bits in 8→5), top 2 bits for G (losing 2 bits in 8→6)
- Pattern indexed by `{screen_y[3:0], screen_x[3:0]}`
- Baked into EBR at synthesis time (not runtime-configurable)
- Enabled by default; can be disabled via DITHER_MODE register (0x32)

### Rationale

- **Blue noise**: Minimizes low-frequency artifacts (less perceptible than Bayer or white noise). Pushes quantization error to high spatial frequencies
- **16×16 pattern**: Small enough for 1 EBR, large enough to avoid visible tiling at normal viewing distance
- **Channel-specific scaling**: Matches actual quantization step size per channel (R/B lose 3 bits, G loses 2 bits)
- **Alternatives considered**: Bayer ordered dither (visible cross-hatch pattern), white noise (uniform but more visible), error diffusion (sequential dependency, not pipelinable)

### Consequences

- +1 EBR block (total EBR: 17→18 of 56, 32.1%)
- +1 pipeline cycle latency (EBR read, fully pipelined — no throughput reduction)
- +~100-200 LUTs for dither scaling and addition
- Smooth gradients in RGB565 output even with large flat-shaded or textured surfaces
- See REQ-005.10 for full specification

---


## DD-013: Color Grading LUT at Display Scanout

**Date:** 2026-02-10
**Status:** Accepted
**Implementation:** SUPERSEDED BY DD-014 (uses SRAM-based upload instead of registers)

### Context

Post-processing effects like gamma correction, color temperature adjustment, and artistic color grading are traditionally applied by re-rendering or using compute shaders. For a fixed-function GPU without compute shaders, a hardware LUT provides real-time color transformation.

The LUT can be placed either at pixel write (in the render pipeline) or at display scanout (in the display controller). Placement at scanout means the LUT operates on the final framebuffer content, after all rendering is complete.

### Decision

Place 3× 1D color grading LUTs at display scanout in the display controller (UNIT-008):
- Red LUT: 32 entries × RGB888 (indexed by R5 of RGB565 pixel)
- Green LUT: 64 entries × RGB888 (indexed by G6 of RGB565 pixel)
- Blue LUT: 32 entries × RGB888 (indexed by B5 of RGB565 pixel)
- Outputs summed with saturation per channel: `final = clamp(R_LUT[R5] + G_LUT[G6] + B_LUT[B5])` at 8-bit (255)
- Double-buffered (write inactive bank, swap at vblank)
- 1 EBR block total (512×36 configuration), bypass when disabled
- Host upload via COLOR_GRADE_LUT_ADDR/DATA registers (0x45/0x46)

### Rationale

- **Scanout placement**: No overdraw waste (each pixel processed exactly once), alpha blending operates in linear space (correct), LUT can be changed without re-rendering
- **RGB565-native indices**: 32/64/32 entries with RGB888 output fit in 1 EBR (512×36 config) (vs 256 entries per channel = 3 EBR for 8-bit indices)
- **Cross-channel output**: Each LUT produces RGB output, enabling effects like color tinting (red input influences green output)
- **Double-buffering**: Prevents tearing during LUT updates
- **Alternatives considered**: Per-pixel LUT at render time (wastes work on overdraw), single per-channel LUT (no cross-channel effects), 3D LUT (too large for EBR)

### Consequences

- +1 EBR block (total EBR: 18 of 56, 32.1%)
- +2 cycles scanout latency (1 EBR read + 1 sum/saturate — fits within pixel period at 100MHz)
- +~230 LUTs for summation and saturation (8-bit adders)
- +~100 FFs for control FSM (upload, bank swap)
- Real-time gamma correction, color temperature, artistic grading with no render overhead
- See REQ-006.03 for full specification

---


## DD-014: SRAM-Based Color Grading LUT Auto-Load

**Date:** 2026-02-11
**Status:** Accepted
**Implementation:** RTL PENDING, RUST PENDING

### Context

The original color grading LUT design (DD-013) used register-based upload via COLOR_GRADE_CTRL/ADDR/DATA registers. To update all 128 LUT entries:
- Required 128+ register writes over SPI (2 writes per entry: address + data)
- Total: 256 SPI transactions ≈ 737 µs at 25 MHz SPI clock
- Separate operations for framebuffer switch and LUT update
- Race conditions possible between vsync wait and register writes

For typical game rendering that switches both framebuffer and color grading per frame, this represents significant SPI overhead and complexity.

### Decision

Replace register-based LUT upload with SRAM-based auto-load DMA:

**Register Changes:**
- **Remove** COLOR_GRADE_CTRL (0x44), COLOR_GRADE_LUT_ADDR (0x45), COLOR_GRADE_LUT_DATA (0x46)
- **Expand** FB_DISPLAY (0x41) to include: FB address (13b), LUT SRAM address (13b), enable flag (1b)
- **Add** FB_DISPLAY_SYNC (0x47): Blocking variant that waits for vsync before completing

**Upload Protocol:**
1. Firmware prepares 384-byte LUT in SRAM (via MEM_ADDR/MEM_DATA or bulk transfer)
2. Firmware writes FB_DISPLAY or FB_DISPLAY_SYNC with both FB and LUT addresses
3. At vsync: hardware DMAs 384 bytes from SRAM to inactive EBR bank (~1.92µs)
4. LUT banks swap atomically with framebuffer switch

**LUT SRAM Format:**
- 384 bytes sequential: Red[96B] + Green[192B] + Blue[96B]
- Each entry: 3 bytes (R, G, B) in RGB888 format
- 4KiB alignment required for base address

### Rationale

**Performance:**
- **1000× SPI traffic reduction**: 1 register write vs 128+ writes
- **Atomic updates**: Framebuffer and LUT switch in single operation
- **No race conditions**: Hardware-synchronized at vsync
- **SRAM bandwidth negligible**: 1.92µs of 1.43ms vblank (0.13%)

**Simplicity:**
- **Firmware**: One blocking call vs multi-step sequence (`wait_vsync() + multiple writes + swap`)
- **Synchronization**: Hardware handles vsync coordination
- **API**: `gpu_swap_buffers(fb, lut, enable, blocking)` – single function

**Flexibility:**
- **Pre-prepared LUTs**: Store multiple LUTs in SRAM, switch instantly
- **Conditional load**: LUT_ADDR=0 skips load, only switches framebuffer
- **Blocking/non-blocking**: Choose based on use case

**Tradeoffs:**
- Uses 4KiB SRAM per LUT (3712 bytes wasted per LUT due to alignment)
- Total: ~27.7MB free space can hold 16+ LUTs with minimal impact
- Adds LUT DMA controller (~180 LUTs, ~80 FFs to UNIT-008)

### Alternatives Considered

1. **Keep register-based upload, add DMA as optional path**
   - Rejected: Doubles complexity, confuses API, minimal benefit for debugging
   - SRAM-based is strictly superior in all use cases

2. **Use existing MEM_DATA sequential write without alignment requirement**
   - Rejected: Requires firmware to track LUT address state, error-prone
   - 4KiB alignment simplifies addressing, enables instant switching

3. **Pack multiple LUTs in single 4KiB block**
   - Rejected: Complex addressing, no benefit (SRAM is abundant)
   - Simple 1 LUT = 1 block is clearer

4. **Keep FB_DISPLAY address-only, add separate LUT_DISPLAY register**
   - Rejected: Requires two register writes, loses atomicity benefit
   - Combining in one register ensures single atomic operation

### Consequences

**Hardware:**
- +LUT DMA controller in UNIT-008 (~180 LUTs, ~80 FFs)
- +SPI CS hold mechanism in UNIT-003 for blocking writes (~20 LUTs, ~10 FFs)
- -Register decode logic for COLOR_GRADE_CTRL/ADDR/DATA (~50 LUTs saved)
- Net: +~150 LUTs, +~90 FFs

**Firmware:**
- Simplified API: `gpu_swap_buffers()` combines frame flip + LUT update
- Pre-upload LUTs to SRAM once (via `gpu_prepare_lut()`)
- Instant LUT switching (change LUT address only)
- Example use cases:
  - Identity LUT at 0x441000 (default)
  - Gamma 2.2 at 0x442000 (realistic lighting)
  - Warm tint at 0x443000 (sunset scenes)
  - Cool tint at 0x444000 (underwater scenes)

**Performance Impact:**
- **Positive**: 1000× reduction in SPI traffic for LUT updates
- **Positive**: Atomic framebuffer+LUT switch eliminates race conditions
- **Neutral**: SRAM bandwidth impact negligible (0.13% of vblank)
- **Neutral**: SRAM usage minimal (64KiB for 16 LUTs of 27.7MB free)

**Migration:**
- Firmware must be updated to use new `gpu_swap_buffers()` API
- LUT data must be pre-uploaded to SRAM instead of sent via registers
- Breaking change but vastly simpler end result

### References

- INT-010: GPU Register Map (FB_DISPLAY, FB_DISPLAY_SYNC)
- REQ-006.03: Color Grading LUT (updated upload protocol)
- INT-011: SRAM Memory Layout (recommended LUT region)
- UNIT-008: Display Controller (LUT DMA controller)
- UNIT-003: Register File (FB_DISPLAY_SYNC blocking logic)

---


## DD-001: PS2 Graphics Synthesizer Reference

**Date:** 2026-02-08
**Status:** Accepted

### Context

The project needed an architectural reference for a fixed-function 3D GPU targeting a small FPGA. The PS2 Graphics Synthesizer (GS) provides a well-documented model of a register-driven, triangle-based rasterizer with texture mapping — closely matching the capabilities achievable on an ECP5-25K.

### Decision

Use the PS2 GS architecture as the primary design reference: register-driven vertex submission, fixed-function triangle rasterization with Gouraud shading, hardware Z-buffering, and multi-texture support via independent texture units.

### Rationale

The PS2 GS is well-documented, uses a register-based command interface (suitable for SPI), and its feature set (textured triangles, alpha blending, Z-buffer) maps well to ECP5 resources. More complex GPU architectures (unified shaders, tile-based rendering) exceed the FPGA budget.

### Consequences

- Fixed-function pipeline limits flexibility but simplifies hardware and verification
- Register-driven interface maps naturally to SPI command transactions
- Feature scope bounded by PS2 GS capabilities (no programmable shaders, no tessellation)

---


## DD-002: ECP5 FPGA Resources

**Date:** 2026-02-08
**Status:** Accepted

### Context

The GPU must fit within a Lattice ECP5-25K FPGA. Resource budgets constrain every architectural decision.

### Decision

Target the ECP5-25K (LFE5U-25F) with the following resource budget: ~24K LUTs, 56 EBR blocks (1,008 Kbits BRAM), 28 DSP slices (18×18 multipliers), and 4 SERDES channels for DVI output.

### Rationale

The ECP5-25K is the smallest ECP5 variant with enough resources for a basic 3D pipeline, and has full open-source toolchain support (Yosys + nextpnr). Larger variants (45K, 85K) cost more and aren't needed for the target feature set.

### Consequences

- All hardware features must fit within 24K LUTs, 56 EBR, 28 DSP budget
- EBR blocks are the scarcest resource — texture cache, dither matrix, color LUT, and FIFOs compete for 56 blocks
- DSP slices enable hardware multiply for barycentric interpolation and fixed-point math
- SERDES provides DVI/HDMI output without external serializer chips

---


## DD-003: DVI/HDMI Output

**Date:** 2026-02-08
**Status:** Accepted

### Context

The GPU needs a video output standard compatible with common monitors. Options include VGA (analog), DVI (digital), and HDMI (digital + audio).

### Decision

Use DVI TMDS output at 640×480@60Hz over an HDMI-compatible connector, using the ECP5 SERDES for serialization.

### Rationale

DVI is electrically compatible with HDMI for video-only output. 640x480@60Hz uses a 25 MHz pixel clock (derived as a synchronous 4:1 divisor from the 100 MHz core clock; 0.7% deviation from the 25.175 MHz standard, acceptable for all common monitors). The ECP5 SERDES handles 10:1 serialization at 250 MHz (10x pixel clock). VGA was rejected due to requiring external DAC.

### Consequences

- Requires PLL configuration for 100 MHz core clock, 25 MHz pixel clock (4:1 divisor), and 250 MHz SERDES clock (10x pixel clock)
- HDMI monitors accept DVI signals natively (video-only, no audio)
- Resolution fixed at 640×480 to stay within SRAM bandwidth limits
- 4 SERDES channels used (R, G, B, clock)

---


---


---
