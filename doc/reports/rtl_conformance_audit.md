# Technical Report: GPU RTL Conformance Audit & Modularity Review

Date: 2026-02-28
Status: Draft

## Background

Recurring fixed-point format mismatches during rasterizer implementation work prompted a review of the GPU RTL codebase.
This investigation examines conformance to the project's Verilog coding guidelines (londey-verilog-guidance skill + CLAUDE.md), identifies modules that are too large or tightly coupled for isolated testing, catalogs fixed-point format inconsistencies, and assesses what SystemVerilog can offer for compile-time type safety on fixed-point values.

## Scope

### Questions Investigated

1. How well do the `.sv` files conform to the coding guidelines?
2. Which modules are too large and how should they be broken up?
3. What fixed-point format inconsistencies exist, and is TI-style Q notation used consistently?
4. What can SystemVerilog offer for compile-time type safety on fixed-point formats?
5. Which modules lack testbenches?
6. How can improvements be organized into ~500-line phases?

### Exclusions

- Generated files: `spi/generated/gpu_regs_pkg.sv`, `spi/generated/gpu_regs.sv` (PeakRDL output)
- PLL vendor primitives: `pll_core.sv`, `pll_core_sim.sv`

## Investigation

### Files Examined

All 33 non-generated `.sv` files under `spi_gpu/src/` (9,618 total lines), 19 testbenches under `spi_gpu/tests/`, the londey-verilog-guidance skill (`.claude/skills/claude-skill-verilog/SKILL.md`), and CLAUDE.md coding guidelines.

## Findings

### F1. Module Size Violations

The guideline recommends keeping modules under ~500 lines.
Eight modules exceed this threshold:

| Module | Lines | Over by | Notes |
|---|---|---|---|
| `gpu_top.sv` | 1,148 | 2.3x | Top-level wiring — size is somewhat inherent |
| `pixel_pipeline.sv` | 1,003 | 2.0x | FSM + datapath + 7 sub-module instantiations |
| `register_file.sv` | 891 | 1.8x | Register decode + vertex state machine |
| `rasterizer.sv` | 884 | 1.8x | Setup + iteration + 13 attribute accumulators |
| `sdram_controller.sv` | 816 | 1.6x | Complex memory controller FSM |
| `texture_cache.sv` | 700 | 1.4x | Cache FSM + decompression + bank writes |
| `color_combiner.sv` | 648 | 1.3x | 4-stage pipeline with duplicated mux logic |
| `display_controller.sv` | 505 | 1.0x | Borderline, CDC + scanline buffering |

### F2. `always_ff` Guideline Violations

The guideline requires `always_ff` blocks to contain **only flat non-blocking assignments** (`reg <= next_reg`), with all conditional logic in companion `always_comb` blocks.
Exceptions are allowed for async reset synchronizers and memory inference patterns.

**Violation severity: widespread.**
The following modules have conditional logic (`if`/`case`) inside `always_ff` datapath blocks that should be refactored to `always_comb` next-state computation:

| Module | Lines | Severity | Pattern |
|---|---|---|---|
| `pixel_pipeline.sv` | 900–997 | High | `case(state)` with conditionals in datapath `always_ff` |
| `rasterizer.sv` | 669–879 | High | `case(state)` with conditionals in datapath `always_ff` |
| `texture_cache.sv` | 408–490 | High | `case(fill_state)` with conditionals in datapath `always_ff` |
| `sdram_controller.sv` | 451–789 | High | Extensive FSM in `always_ff` |
| `sram_controller.sv` | 212–356 | Medium | FSM in `always_ff` |
| `register_file.sv` | 318–384 | Medium | Register decode in `always_ff` |
| `color_combiner.sv` | 542–644 | Low | `else if (pipeline_enable)` gating — acceptable for stall logic |
| `sram_arbiter.sv` | 202–299 | Medium | Arbitration logic in `always_ff` |
| `display_controller.sv` | 318–386 | Medium | Scanline FSM in `always_ff` |
| `spi_slave.sv` | 48–115 | Low | CDC and bit-level SPI sampling |
| `dvi_output.sv` | 95–107 | Low | TMDS serializer counter |
| `timing_generator.sv` | 64–88 | Low | Pixel counter wraparound |
| `tmds_encoder.sv` | 135–143 | Low | DC balance tracking |
| `async_fifo.sv` | 82–164 | Low | FIFO pointer updates |
| `sync_fifo.sv` | 50–74 | Low | FIFO pointer updates |

**Compliant modules (state register only in `always_ff`):**
All texture decoders (bc1–bc4, rgb565, rgba8888, r8), `stipple.sv`, `early_z.sv`, `texel_promote.sv`, `fb_promote.sv`, `alpha_blend.sv`, `dither.sv`, `reset_sync.sv` (async reset exception), `command_fifo.sv`, `pll_core.sv`.

Note: the state register `always_ff` blocks (e.g., `pixel_pipeline.sv:720–727`, `rasterizer.sv:603–609`) correctly follow the guideline — only the separate datapath `always_ff` blocks violate it.

### F3. Multiple Statements Per Line

The guideline requires one statement per line.
`rasterizer.sv` extensively violates this:

- Lines 690–720: vertex latch (`x0 <= px0; y0 <= py0; z0 <= v0_z;`)
- Lines 756–786: derivative and accumulator latch
- Lines 860–873: row-advance accumulator updates (`c0r_row <= c0r_row + c0r_dy; c0r_acc <= c0r_row + c0r_dy;`)

No other modules exhibit this pattern.

### F4. Fixed-Point Format Inconsistencies

#### F4a. Documentation notation issues (not using TI-style Q notation)

| File | Line | Current | Should Be |
|---|---|---|---|
| `rasterizer.sv` | 37–38 | "12.4 fixed point" | "Q12.4" |
| `rasterizer.sv` | 181 | "8.16 signed fixed-point" | "Q8.16" |
| `rasterizer.sv` | 182 | "16.16 unsigned-origin signed fixed-point" | "UQ16.16 (stored in signed 32-bit container)" |
| `rasterizer.sv` | 183 | "Q4.28 signed fixed-point" | "Q4.28" (drop redundant "signed") |
| `rasterizer.sv` | 184 | "Q3.28 signed fixed-point" | "Q3.28" (drop redundant "signed") |
| `rasterizer.sv` | 307 | "8.16 format" | "Q8.16" |
| `register_file.sv` | 21 | "Q12.4 signed fixed" | "Q12.4" (drop redundant "signed fixed") |
| `register_file.sv` | 24 | "Q1.15 signed fixed" | "Q1.15" (drop redundant "signed fixed") |

#### F4b. Critical format mismatch at rasterizer→pixel_pipeline UV boundary

- **Rasterizer output** ([rasterizer.sv:78](spi_gpu/src/render/rasterizer.sv#L78)): `frag_uv0` documented as **Q4.12** `{U[31:16], V[15:0]}`
- **Pixel pipeline port** ([pixel_pipeline.sv:44](spi_gpu/src/render/pixel_pipeline.sv#L44)): `frag_u0` documented as **Q4.12**
- **Pixel pipeline internal usage** ([pixel_pipeline.sv:464–469](spi_gpu/src/render/pixel_pipeline.sv#L464-L469)): treats UV as **Q1.15** signed, extracting bits `[14:0]` as fractional and using `15 - dim_log2` for texel coordinate conversion

The port documentation says Q4.12, but the texture coordinate conversion logic interprets the value as Q1.15.
This is either:
- A **documentation bug** where the internal comment should say Q4.12 and the shift arithmetic adjusted, or
- A **logic bug** where the conversion math assumes a different format than what the rasterizer provides

This is the exact class of error that has been causing recurring issues.

#### F4c. Format inventory across module boundaries

| Boundary | Signal | Format | Consistency |
|---|---|---|---|
| register_file → rasterizer | `tri_x`, `tri_y` | Q12.4 | OK |
| register_file → rasterizer | `tri_q` | Q1.15 | OK |
| register_file → rasterizer | `inv_area` | UQ0.16 | OK |
| rasterizer → pixel_pipeline | `frag_color0/1` | Q4.12 RGBA | OK |
| rasterizer → pixel_pipeline | `frag_z` | 16-bit unsigned | OK |
| rasterizer → pixel_pipeline | `frag_uv0/1` | **Q4.12 (documented) vs Q1.15 (used)** | **MISMATCH** |
| rasterizer → pixel_pipeline | `frag_q` | Q3.12 | OK (unused) |
| pixel_pipeline → color_combiner | `cc_tex_color0/1` | Q4.12 RGBA | OK |
| pixel_pipeline → color_combiner | `cc_shade0/1` | Q4.12 RGBA | OK |
| color_combiner → pixel_pipeline | `cc_in_color` | Q4.12 RGBA | OK |
| pixel_pipeline → alpha_blend | `src_rgba` | Q4.12 RGBA | OK |
| fb_promote → alpha_blend | `dst_rgb` | Q4.12 RGB | OK |
| alpha_blend → dither | via `blend_result_rgb` | Q4.12 RGB | OK |
| dither → Q4.12→RGB565 | `dither_output` | Q4.12 RGB | OK |

### F5. Testbench Coverage Gaps

| Module | Testbench | Priority |
|---|---|---|
| **`pixel_pipeline`** | None | **Critical** — largest module, most complex interactions |
| **`stipple`** | None | Low — simple combinational, 47 lines |
| **`texel_promote`** | None | Medium — format conversion, error-prone |
| **`spi_slave`** | None | Medium — CDC boundary |
| **`dvi_output`** | None | Low — display output, vendor-adjacent |
| **`tmds_encoder`** | None | Low — display encoding |
| **`reset_sync`** | None | Low — standard pattern |
| **`gpu_top`** | Integration test only | N/A — tested via simulation harness |

### F6. Strongly Typed Fixed-Point in SystemVerilog

**Key finding: true compile-time type safety for same-width fixed-point formats is not achievable in SystemVerilog with Verilator.**

Approaches investigated:

| Approach | Type Safety | Verilator Support | Viability |
|---|---|---|---|
| `typedef struct packed` | None (same-width) | Yes | Documentation only |
| `typedef logic` aliases | None | Yes | Pure cosmetics |
| Package-shared typedefs | Organizational only | Yes | Recommended baseline |
| `fplib` (SV interfaces) | Real tracking | **No** (Verilator #1593) | Not viable |
| VHDL `fixed_pkg` | Compiler-enforced | N/A | Wrong language |
| **Naming conventions** | **Human-enforced** | **N/A** | **Best practical option** |

SystemVerilog uses structural typing for packed types — two `typedef struct packed` types with the same total bit width are freely assignable without warnings.
Verilator's `-Wall` catches `WIDTH` mismatches (different bit counts) but has no `PINTYPE` or typedef-identity checking.

**Recommended approach for pico-gs:**

1. **`fp_types_pkg.sv`** — Central package with typedefs for every format (`q4_12_t`, `q1_15_t`, `q12_4_t`, `uq0_16_t`, `q3_12_t`).
   Typedefs carry documentation value but not enforcement.
2. **Signal name suffixes** — Append `_q412`, `_q124`, `_uq016` to every signal carrying a fixed-point value.
   This makes format assumptions grep-able and reviewable.
3. **Named conversion functions** — Wrap format transitions in explicitly named functions (e.g., `promote_unorm8_to_q412`).
   Modules like `texel_promote.sv` and `fb_promote.sv` already do this implicitly — making it explicit makes boundaries auditable.
4. **Optional lint script** — Grep-based check that port connection suffixes match signal suffixes.

### F7. Other Guideline Observations

**Positive findings:**
- All files use `` `default_nettype none `` / `` `default_nettype wire `` bookends
- Named port connections used consistently across all instantiations
- FSM state/next-state separation is correctly applied for state registers
- Enum types used for FSM state encoding throughout
- Comments are generally good to excellent
- All modules have port documentation
- `begin`/`end` used on `if`/`else`/`case` bodies consistently

**Minor issues:**
- `early_z.sv`: Spec-ref comment appears before `` `default_nettype none `` (lines 1–2 before line 8)
- `dither.sv`: Declares `clk` and `rst_n` as inputs but immediately assigns them to unused wires — a purely combinational module with unnecessary clock ports

## Conclusions

### Answers to Scoping Questions

**Q1. Guideline conformance:** The `always_ff` flat-assignment rule is violated in **15 of 33 modules**.
Most violations follow the same pattern: FSM datapath logic with `case(state)` inside `always_ff` instead of computing `next_*` values in `always_comb`.
Other aspects of the guidelines (naming, `default_nettype`, begin/end, named ports) are well followed.

**Q2. Modules to break up:** `pixel_pipeline.sv` (1,003 lines) and `rasterizer.sv` (884 lines) are the primary candidates.
The pixel pipeline naturally decomposes into: pre-CC stages (stipple, early-Z, texture), post-CC stages (alpha blend, dither, Q4.12→RGB565), and the FSM/datapath controller.
The rasterizer naturally decomposes into: edge setup, derivative precomputation, attribute accumulation, and the iteration FSM.

**Q3. Fixed-point consistency:** One critical format mismatch found at the rasterizer→pixel_pipeline UV boundary (Q4.12 documented but Q1.15 logic used).
Several documentation instances don't use TI-style Q notation.
The `Q` prefix is sometimes accompanied by redundant "signed" qualifiers.

**Q4. Strongly typed units:** Not achievable at compile time in SystemVerilog with Verilator.
Best practical defense is naming conventions + a central types package + named conversion functions.

**Q5. Testbench gaps:** `pixel_pipeline` (the largest and most complex module) has no dedicated testbench.
This is the highest-priority gap.

## Recommendations

### Phased Improvement Plan

Each phase targets ~500 lines of changes or less.
Phases are ordered by risk reduction: fix the bugs and type safety issues first, then refactor for conformance and testability.

#### Phase 0: Fixed-Point Type Infrastructure (~200 lines)

Create `fp_types_pkg.sv` with:
- Typedefs for all fixed-point formats used in the pipeline
- Named conversion functions
- Q4.12 arithmetic constants (already duplicated across alpha_blend, color_combiner)

Fix the UV format mismatch documentation/logic at the rasterizer→pixel_pipeline boundary.
Update all fixed-point comments to use TI-style Q notation (sed-level changes across ~15 locations).

#### Phase 1: Rasterizer `always_ff` Refactor (~400–500 lines)

Extract the datapath `always_ff` (lines 669–879) into `always_comb` next-state computation.
This is the highest-value refactor: the rasterizer has the most attribute accumulators and the most complex fixed-point arithmetic.
Fix multi-statement lines throughout.
Does not change module boundaries — purely internal.

#### Phase 2: Pixel Pipeline Decomposition — Pre-CC Stages (~400 lines)

Extract the pre-combiner stages (stipple, early-Z, texture lookup/promote) and the FSM into a cleaner structure.
Move the tiled address computation into a small helper module or explicit `always_comb` with clear next-state signals.
The `always_ff` datapath refactor for the pixel pipeline FSM is the core of this phase.

#### Phase 3: Pixel Pipeline Decomposition — Post-CC Stages (~300 lines)

Extract the Q4.12→RGB565 conversion (currently inline at pixel_pipeline.sv:634–669) into a standalone module.
The alpha_blend→dither→Q4.12→RGB565 chain becomes a clean sub-pipeline.
Add `_q412` suffixes to the signals at each stage boundary.

#### Phase 4: Texture Cache `always_ff` Refactor (~350 lines)

Extract the fill FSM datapath into `always_comb` next-state computation.
The bank write logic (lines 583–620) is a memory inference pattern and can stay in `always_ff`.
The LRU update logic (lines 648–695) should move to `always_comb`.

#### Phase 5: Memory Controller `always_ff` Refactor (~400 lines)

Refactor `sdram_controller.sv` and `sram_controller.sv` to use the `always_comb` next-state pattern.
These are infrastructure modules with lower bug risk but should conform to the guideline for consistency.

#### Phase 6: Display & SPI `always_ff` Refactor (~300 lines)

Refactor `display_controller.sv`, `spi_slave.sv`, `dvi_output.sv`, `timing_generator.sv`, and `tmds_encoder.sv`.
These are lower-priority — the display pipeline works and has few format conversion issues.

#### Phase 7: Signal Naming Standardization (~300 lines)

Apply `_q412` / `_q124` / `_uq016` suffixes to fixed-point signals across the render pipeline.
This is a rename-only phase — no logic changes.
Focus on module boundary signals (ports) first, then internal signals.

#### Phase 8: Testbench for pixel_pipeline (~400 lines)

Write a dedicated testbench exercising:
- Fragment acceptance and FSM state transitions
- Stipple/range discard paths
- Z-read/write cycle
- CC emit/wait handshake
- Alpha blend path (FB read/write)
- Format consistency at each stage boundary

#### Phase 9: Missing Testbenches (~300 lines)

Add testbenches for `texel_promote`, `stipple`, and `spi_slave`.
These are small modules with well-defined interfaces.

### Notes on Phase Sizing

The ~500-line target refers to **changed lines** (additions + modifications), not file size.
The `always_ff` → `always_comb` refactors tend to be close to 1:1 in line count (moving logic between blocks rather than adding or removing it), so the module size stays roughly constant.
The decomposition phases (2, 3) may create new files but reduce the parent module proportionally.
