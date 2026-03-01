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
PeakRDL generates the SystemVerilog package and register module into `spi_gpu/src/spi/generated/`.
`registers/src/lib.rs` provides the hand-maintained Rust constants crate (`gpu-registers`, `no_std`), matching the RDL.
Register specifications (INT-010 through INT-014) live in `registers/doc/`, outside syskit management.

Change process:
1. Edit `registers/rdl/gpu_regs.rdl` and update `registers/src/lib.rs` to match
2. Update the corresponding markdown spec in `registers/doc/`
3. Run `registers/scripts/generate.sh` to regenerate SV
4. Review generated diffs
5. Update consuming code (`driver.rs`, `register_file.sv`) if register semantics changed

### Rationale

- SystemRDL is machine-readable and supports automated code generation, eliminating manual transcription errors between hardware and software.
- Keeping specs in `registers/doc/` (not `doc/interfaces/`) avoids syskit workflow overhead for frequent register iterations during active hardware development.
- The generated SV is checked into the repository so builds do not depend on PeakRDL being installed.

### Alternatives Considered

1. **Hand-maintained SV constants (no codegen)**: Rejected — drift risk between SV and Rust register definitions; manual synchronization is error-prone.
2. **Syskit-managed register specifications**: Rejected — the syskit impact/propose/approve workflow adds overhead unsuited to the rapid iteration cycle of register development.
3. **Generate Rust constants from RDL too**: Deferred — the Rust crate is small enough to maintain by hand; PeakRDL Rust output quality is evolving.

### Consequences

- All register changes start with the RDL file.
- INT-010 through INT-014 in `doc/interfaces/` are stubs that redirect to `registers/doc/`.
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
| `raster_deriv.sv` | ~340 | Purely combinational derivative precomputation (UNIT-005.02) |
| `raster_attr_accum.sv` | ~685 | Attribute accumulators, derivative registers, output promotion (UNIT-005.02/005.03) |
| `raster_edge_walk.sv` | ~275 | Iteration position, edge functions, fragment emission (UNIT-005.04) |

Sub-modules receive decoded control signals (`latch_derivs`, `step_x`, `step_y`, `init_pos_e0`, etc.) rather than the FSM state enum, keeping them decoupled from the FSM encoding.
The parent module's external port list is unchanged; `gpu_top.sv` requires no modifications.

### Rationale

- The `~500-line guideline and one-statement-per-line rule are incompatible with a single-file design at this register count.
- The derivative computation is naturally a purely combinational block (~340 lines) with no state — extracting it as a leaf module is a clear win.
- The attribute accumulator block owns 52 registers with self-contained stepping logic — a clean sequential sub-module boundary.
- The iteration/edge-walk logic owns 17 registers and the fragment output handshake — another clean sequential boundary.
- The ~500-line guideline and one-statement-per-line formatting rule are incompatible with a single-file design at this register count.

### Consequences

- Three new RTL files in `spi_gpu/src/render/`.
- Makefile `RTL_SOURCES`, `HARNESS_RTL_SOURCES`, `SIM_RTL_SOURCES`, `test-rasterizer`, and lint targets updated.
- Testbench `tb_rasterizer.sv` internal signal paths updated (e.g., `dut.c0r_dx` → `dut.u_attr_accum.c0r_dx`).
- `rasterizer.sv` removed from `LEAF_LINT_FILES`; composite lint entry added.

### References

- UNIT-005 (Rasterizer), UNIT-005.01–005.04 (sub-units)

---


## DD-026: Arbiter Port 3 Sharing — Texture Cache vs. PERF_TIMESTAMP Writes

**Date:** 2026-02-28
**Status:** Proposed

### Context

UNIT-007 (Memory Arbiter) port 3 is used for texture cache fill burst reads by UNIT-006 (Pixel Pipeline).
UNIT-003 (Register File) also drives `ts_mem_wr` / `ts_mem_addr` / `ts_mem_data` outputs that `gpu_top.sv` must forward to port 3 as single-word SDRAM writes when a `PERF_TIMESTAMP` register write occurs.
Both sources compete for the same arbiter port, and no sharing mechanism was previously specified.

### Decision

Manage port 3 contention entirely within `gpu_top.sv` using a latch-and-serialize scheme:

1. A pending-write register in `gpu_top.sv` captures `ts_mem_wr` / `ts_mem_addr` / `ts_mem_data` from UNIT-003.
   If a new `ts_mem_wr` pulse arrives while a previous write is still pending, the new data overwrites the pending register (fire-and-forget; back-to-back timestamps may coalesce).
2. `gpu_top.sv` drives `port3_req` by OR-ing UNIT-006's texture fill request with the pending timestamp write request.
   UNIT-006's texture request is checked first; the timestamp write is only injected onto port 3 when UNIT-006 is not asserting a texture request.
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
- UNIT-006 (Pixel Pipeline — texture cache fill, port 3 burst reads)
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

The valid/ready handshake is the standard backpressure mechanism already used between UNIT-003 and UNIT-004 (`tri_valid` / `tri_ready`).
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
- UNIT-006 (Pixel Pipeline — DSP headroom for texture decoders)
- UNIT-010 (Color Combiner — DSP budget)
- REQ-003.06 (Texture Sampling — perspective-correct UV)
- REQ-011.02 (Resource Constraints — DSP budget)

---


## DD-023: SimTransport for pico-gs-core against Verilator Interactive Simulator

**Date:** 2026-02-26
**Status:** Accepted

### Context

The Verilator interactive simulator (REQ-010.02, UNIT-037) needs to drive the GPU RTL model for live visual debugging.
A key question is whether this simulator should implement a Rust `SimTransport` satisfying the `SpiTransport` trait (INT-040), which would allow `pico-gs-core` driver code (UNIT-022) to run against the Verilator sim without modification.
Both UNIT-022 Design Notes and INT-040 Notes require this decision to be captured before UNIT-037 implementation begins.

### Decision

The Verilator interactive simulator is implemented as a standalone C++/Lua binary that drives the GPU RTL out-of-band via `SIM_DIRECT_CMD` injection ports, bypassing SPI serial framing entirely.
It does NOT implement a Rust `SimTransport` satisfying INT-040 in the initial version.

### Rationale

A standalone C++ application is simpler to build, avoids Rust/C FFI complexity, and delivers the core use case (live visual debug with Lua scripting) immediately.
The `SIM_DIRECT_CMD` path presents the same logical 72-bit format (`{rw[0], addr[6:0], data[63:0]}`) to the FIFO write port that the SPI slave would present after deserializing a transaction, so the RTL behavior is exercised faithfully.
A `SimTransport` wrapper could be added later if there is a demonstrated need to run `pico-gs-core` driver code (UNIT-022) against the sim without modification; that path is deferred until the need arises.

### Consequences

- `pico-gs-core` tests cannot currently run against the Verilator sim model.
- UNIT-037 is a standalone C++/Lua binary outside the Rust workspace; it does not participate in `cargo build` or `cargo test`.
- UNIT-022 and INT-040 correctly reference this decision; their notes about a future `SimTransport` remain valid as a deferred option.
- If the need for a `SimTransport` is later demonstrated, a new design decision (superseding this one) would be created and UNIT-037 extended accordingly.

### References

- REQ-010.02 (Verilator Interactive Simulator)
- UNIT-022 Design Notes (GPU Driver Layer)
- INT-040 Notes (Host Platform HAL)


## DD-022: SystemVerilog Style Guide Conformance

**Date:** 2026-02-16
**Status:** Accepted

### Context

All RTL files must conform to a consistent coding style for safety (`\`default_nettype none`), maintainability (separated FSMs), and lint hygiene (zero verilator warnings without pragmas).

### Decision

All SystemVerilog files in `spi_gpu/src/` conform to the project style guide (`.claude/skills/claude-skill-verilog/SKILL.md`).
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

**Firmware (Rust):**
- INT-020: New `gpu_set_z_range()`; `gpu_set_render_mode()` updated for COLOR_WRITE_EN
- INT-021: RenderFlags gains `color_write` field
- Migration: Code using FB_CONTROL[41] must move to RENDER_MODE[4]

**Performance:**
- Positive: Eliminates wasted texture bandwidth for occluded fragments
- Positive: Depth range clipping is free (register comparison only)
- Neutral: No additional BRAM consumption
- Neutral: Pipeline latency unchanged for passing fragments

### References

- INT-010, INT-011, INT-020, INT-021, UNIT-006, REQ-005.07

---


## DD-017: 16-bit Fixed-Point Mesh Vertex Data with SoA Patch Layout

**Date:** 2026-02-13
**Status:** Accepted
**Implementation:** RUST PENDING

### Context

The asset binary format (INT-031) stores mesh vertex data as f32 arrays: positions (3×f32 = 12 B/vertex), normals (3×f32 = 12 B/vertex), and UVs (2×f32 = 8 B/vertex), totaling 32 bytes per vertex plus indices.
For 16-vertex patches this is ~560 bytes per patch.
With ~50 patches per mesh and multiple meshes in flash, vertex data consumes significant flash and DMA bandwidth.

Additionally, each patch uses four separate binary files (_pos.bin, _uv.bin, _norm.bin, _idx.bin), requiring four DMA transfers per patch.

### Decision

1. **Quantize vertex attributes to 16-bit fixed-point:**
   - Positions: u16 with mesh-wide AABB quantization grid ([0, 65535] maps to [aabb_min, aabb_max] per axis)
   - Normals: i16 1:15 signed fixed-point (range [-1.0, +0.99997])
   - UVs: i16 1:2:13 signed fixed-point (range [-4.0, +3.9998])
   - Indices: u8 strip commands (unchanged)

2. **Single contiguous SoA blob per patch:**
   - Layout: `[pos_x[], pos_y[], pos_z[], norm_x[], norm_y[], norm_z[], uv_u[], uv_v[], indices[]]`
   - One file per patch instead of four

3. **Quantization bias matrix:**
   - Core 0 folds quantization parameters into the model matrix: `adjusted_model = model × translate(aabb_min) × scale(extent / 65535.0)`
   - `transform_vertex()` is unchanged — receives MVP and position as before

### Rationale

- **46% flash savings**: 304 B vs 560 B per 16-vertex patch
- **Single DMA transfer**: One 304 B read vs four separate reads (reduced DMA setup overhead)
- **No precision loss in practice**: u16 positions give 1/65535 of the mesh AABB extent per axis — sub-millimeter for typical game meshes.
  Normal 1:15 resolution (1/32768) exceeds Gouraud shading requirements.
  UV 1:2:13 gives 1/16 texel precision at 512px (acceptable with bilinear filtering)
- **Zero-cost conversion on Cortex-M33**: Single-cycle VCVT.F32.U16/VCVT.F32.S16 instructions
- **Bias matrix approach**: Avoids changing `transform_vertex()` — all quantization is absorbed into the model matrix
- **Mesh-wide quantization grid**: All patches share one coordinate system, preventing seam artifacts at patch boundaries

### Alternatives Considered

1. **Keep f32, merge into single blob**: Saves DMA setup but no size reduction.
   Rejected — flash savings are the primary motivation.
2. **Per-patch quantization AABBs**: Each patch has its own [0, 65535] range.
   Rejected — causes seam artifacts where adjacent patches meet due to different quantization grids.
3. **Half-float (f16)**: 16-bit IEEE 754.
   Same size as u16/i16 but with non-uniform precision (more precision near zero, less at extremes).
   Rejected — ARM Cortex-M33 lacks native f16 instructions, requiring software conversion.
   u16/i16 with VCVT is simpler and faster.

### Consequences

- INT-031: Major revision to mesh binary format sections
- UNIT-032: Quantization and SoA packing steps added to mesh splitter
- UNIT-033: Codegen emits single blob files with quantized data
- INT-021: RenderMeshPatch processing steps updated for unpack/convert
- UNIT-021: Input buffer sizes reduced (~1,136 B → ~608 B), working RAM ~7.5 KB
- REQ-007.01: Bias matrix requirement added
- No GPU hardware changes required
- Lights and matrices remain f32 (only vertex attributes are quantized)

### References

- INT-031: Asset Binary Format (primary spec)
- INT-021: Render Command Format (RenderMeshPatch processing)
- REQ-007.01: Matrix Transformation Pipeline (bias matrix)
- DD-016: Mesh Pipeline Restructure (Core 1 vertex processing context)

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


## DD-004: Rust with rp235x-hal

**Date:** 2026-02-08
**Status:** Accepted

### Context

The RP2350 host firmware needs a language and HAL. Rust was specified as the language. The choice is between bare-metal HAL and async frameworks.

### Decision

Use Rust with `rp235x-hal` (bare-metal, no Embassy). Direct access to SPI, DMA, GPIO, and multicore primitives with deterministic timing.

### Rationale

`rp235x-hal` is the community-standard HAL for RP2350, based on the mature `rp2040-hal`. A bare-metal approach (vs Embassy async) gives deterministic timing essential for 30+ FPS real-time rendering on the render core. Embassy's cooperative scheduling adds unpredictable latency.

### Consequences

- Deterministic timing for render loop on Core 1
- No async runtime overhead; interrupt-driven where needed
- Must manually manage concurrency between cores
- Ecosystem limited to `no_std` crates

---


## DD-005: Cortex-M33 Target and Toolchain

**Date:** 2026-02-08
**Status:** Accepted

### Context

The RP2350 has dual Cortex-M33 cores (with hardware FPU) and dual RISC-V cores. A target and toolchain must be chosen.

### Decision

Use `thumbv8m.main-none-eabihf` target (Cortex-M33 with hardware FPU). Build with `probe-rs` for flash/debug, `flip-link` for stack overflow protection, and `defmt` for logging.

### Rationale

The Cortex-M33 cores have a single-precision hardware FPU and DSP extensions. The `eabihf` target enables hardware float calling conventions, critical for matrix math and lighting performance.

### Consequences

- Hardware float for matrix/lighting calculations (no software emulation overhead)
- `probe-rs` enables SWD debug and flash programming
- `flip-link` provides stack overflow detection in debug builds
- `defmt` provides efficient logging over RTT

---


## DD-006: Dual-Core Communication via heapless SPSC Queue

**Date:** 2026-02-08
**Status:** Accepted

### Context

Core 0 (scene manager) must send render commands to Core 1 (render executor). The RP2350 hardware SIO FIFOs are only 8-deep × 32-bit, too small for render commands.

### Decision

Use `heapless::spsc::Queue` for the inter-core render command queue, with SIO FIFO doorbell signaling to wake Core 1.

### Rationale

`heapless::spsc::Queue` is a proven lock-free single-producer single-consumer queue requiring no allocator or mutexes. SIO FIFO signals "new commands available" to avoid busy-polling.

### Consequences

- Lock-free, wait-free command submission from Core 0
- Fixed queue capacity must be sized at compile time
- SIO doorbell avoids Core 1 busy-polling (power savings)
- Queue overflow must be handled by Core 0 (back-pressure)

---


## DD-007: PNG Decoding with image Crate

**Date:** 2026-02-08
**Status:** Accepted

### Context

The asset build tool needs to decode PNG textures and convert them to GPU-native formats (RGBA4444, BC1). A Rust PNG/image library is needed.

### Decision

Use the `image` crate (v0.25+) for PNG decoding in the asset build tool.

### Rationale

The `image` crate is the de facto standard for image processing in Rust. It provides `open()` and `to_rgba8()` for automatic color space conversion, handles PNG and other formats, and is actively maintained (10M+ downloads).

### Consequences

- Simple API for loading any image format to RGBA8
- Large dependency tree (acceptable for host-side build tool, not embedded)
- Future format support (JPEG, etc.) available without additional crates

---


## DD-008: OBJ Parsing with tobj Crate

**Date:** 2026-02-08
**Status:** Accepted

### Context

The asset build tool needs to parse Wavefront OBJ mesh files and extract vertex positions, normals, and UV coordinates.

### Decision

Use the `tobj` crate (v4.0+) for OBJ file parsing.

### Rationale

`tobj` is the most popular Rust OBJ parser (971K+ downloads). It supports triangulation, handles positions/normals/UVs, and provides a simple API.

### Consequences

- Automatic triangulation of non-triangle faces
- Handles all standard OBJ attributes needed (v, vt, vn, f)
- No MTL material support needed (textures assigned separately)

---


## DD-009: Greedy Sequential Triangle Packing with Strip Optimization

**Date:** 2026-02-08 (updated 2026-02-13)
**Status:** Accepted

### Context

Large meshes must be split into "patches" that fit within the GPU's per-draw vertex/index limits. A splitting algorithm is needed. Additionally, after splitting, triangles within each patch should be reordered for strip connectivity to reduce index data size and leverage the GPU's kicked vertex registers.

### Decision

Implement greedy sequential triangle packing: fill each patch with triangles in order until the next triangle would exceed vertex or index limits, then start a new patch. After splitting, perform strip optimization within each patch and encode indices as packed u8 strip commands.

### Rationale

- O(n) time complexity for initial packing
- Deterministic output for the same input
- Simple to implement, debug, and maintain
- Accepts some vertex duplication at patch boundaries as an acceptable trade-off
- Strip optimization reduces index data from 3N entries (triangle list) to ~N+2 (strip), halving index size per entry (u8 vs u16)

### Consequences

- Vertex duplication at patch boundaries (~5-15% overhead for typical meshes)
- Strip-optimized triangle ordering within patches (original ordering not preserved)
- No spatial optimization (adjacent triangles may land in different patches)
- Packed u8 index format maps directly to GPU VERTEX_NOKICK/KICK_012/KICK_021 registers (INT-010)

---


## DD-016: Mesh Pipeline Restructure — Core 1 Vertex Processing with DMA Pipeline

**Date:** 2026-02-13
**Status:** Accepted
**Implementation:** RUST PENDING

### Context

The original mesh pipeline had Core 0 performing all vertex transformation, lighting, back-face culling, and GPU vertex packing (~460 vertices × MVP multiply per frame), then enqueuing ~144 pre-transformed `SubmitScreenTriangle` commands for Core 1 to dispatch as register writes. This created a CPU bottleneck on Core 0 while Core 1 was largely idle between SPI transactions.

### Decision

Restructure the mesh pipeline so that:
1. **Core 0** performs scene management and spatial culling only (AABB frustum tests, ~29 tests/frame)
2. **Core 1** performs the full vertex processing pipeline: DMA-prefetch patch data from flash, transform (MVP), light (Gouraud), cull (back-face), clip (Sutherland-Hodgman), pack (GpuVertex), and submit to GPU
3. **DMA double-buffering** on both sides: input (flash→SRAM prefetch) and output (SRAM→SPI via DMA/PIO)
4. **Packed u8 index format**: Each byte encodes `[7:4]` vertex index, `[3:2]` kick control (NOKICK/KICK_012/KICK_021), `[1:0]` spare — mapping directly to GPU registers in INT-010
5. **PC platform**: 3-thread model (main/scene + render/vertex + SPI/output)

### Rationale

- **Core 0 bottleneck eliminated**: ~460 vertex transforms → ~29 AABB tests (>10× reduction)
- **Core 1 utilization**: DMA overlap hides flash read latency (~1µs per patch) and SPI write latency
- **Memory efficiency**: 16-vertex patches × ~568 bytes = DMA-friendly sizes; working RAM ~8 KB (1.5% of 520 KB)
- **Culling benefit**: Frustum culling eliminates ~30% of patches in typical teapot views
- **u8 index format**: 50% size reduction vs u16; strip optimization gives ~N+2 entries for N triangles vs 3N; direct GPU register mapping (no lookup table)
- **GPU registers exist**: INT-010 already defines VERTEX_NOKICK (0x06), VERTEX_KICK_012 (0x07), VERTEX_KICK_021 (0x08) — no hardware change needed

### Consequences

- **Queue memory**: ~5 KB → ~16.5 KB (RenderMeshPatch ~264 bytes × 64 entries)
- **Core 1 working RAM**: ~8 KB (input buffers 2×568B, vertex cache 640B, clip workspace 280B, output buffers 2×810B, matrices/lights 224B)
- **New HAL traits**: DmaMemcpy, BufferedSpiTransport (INT-040)
- **Asset pipeline changes**: Strip optimization, AABB computation, u8 index encoding, MeshPatchDescriptor generation
- **Compile-time mesh data**: No runtime mesh generation; const flash data from asset pipeline
- **PC 3-thread model**: More complex than single-threaded, but mirrors RP2350 dual-core behavior for testing

### References

- INT-010: GPU Register Map (VERTEX_NOKICK, VERTEX_KICK_012, VERTEX_KICK_021)
- INT-021: Render Command Format (RenderMeshPatch)
- INT-031: Asset Binary Format (packed u8 index, AABB, MeshPatchDescriptor)
- INT-040: Host Platform HAL (DmaMemcpy, BufferedSpiTransport)
- REQ-007.02: Render Mesh Patch (Core 1 vertex processing pipeline)

---


## DD-015: Multi-Platform Host Architecture

**Date:** 2026-02-12
**Status:** Accepted
**Implementation:** RUST PENDING

### Context

Debugging the spi_gpu FPGA is difficult when the only host is the RP2350 microcontroller. The RP2350 has limited logging (defmt over RTT), no filesystem for frame capture, and requires physical hardware for every test. An Adafruit FT232H breakout board can drive the same SPI protocol from a PC, enabling full logging, frame capture, command replay, and faster iteration during GPU development.

The host application currently has platform-specific code (rp235x-hal SPI, TinyUSB input, dual-core SPSC queue) tightly coupled with platform-agnostic logic (scene management, geometry, lighting, command generation). These must be separated.

### Decision

Split the host application into multiple Rust crates with a shared core:

```
crates/
├── pico-gs-core/          # Platform-agnostic shared library
│   ├── gpu/               # GPU driver API (register protocol, command building)
│   ├── render/            # Command types, lighting, mesh rendering, transforms
│   ├── scene/             # Scene state machine, demo definitions
│   └── math/              # Fixed-point utilities
├── pico-gs-hal/           # Platform abstraction traits
│   ├── SpiTransport       # SPI read/write/transfer
│   ├── GpioInput          # CMD_FULL, CMD_EMPTY, VSYNC polling
│   └── InputSource        # Keyboard/input event abstraction
├── pico-gs-rp2350/        # RP2350 embedded application
│   ├── hal_impl/          # rp235x-hal SPI + GPIO implementations
│   ├── main.rs            # Dual-core entry point
│   ├── core1.rs           # Render executor on Core 1
│   └── input.rs           # TinyUSB keyboard handler
├── pico-gs-pc/            # PC debug application
│   ├── hal_impl/          # FT232H SPI + GPIO implementations
│   ├── main.rs            # Single-threaded entry point
│   ├── input.rs           # Terminal keyboard handler
│   ├── capture.rs         # Frame capture / command logging
│   └── replay.rs          # Command replay from logs
└── asset-build-tool/      # Asset preparation (moved from root)
```

Key design principles:
1. GPU driver API (`gpu_write`, `gpu_read`, `gpu_init`, etc.) is generic over HAL traits -- same code runs on both platforms
2. Scene management, transforms, lighting, and command generation are fully platform-agnostic in pico-gs-core
3. Platform-specific code is limited to: SPI transport, GPIO access, input handling, and application orchestration (threading model)
4. The inter-core SPSC queue is RP2350-specific; the PC version calls command execution directly (single-threaded)

### Rationale

- **Multi-crate over feature flags**: Platform differences (threading model, input system, logging framework) are too deep for `#[cfg]` flags. Separate crates give clean boundaries and independent dependency trees (no_std vs std)
- **Trait-based HAL**: The GPU driver already uses `embedded-hal` traits internally. Extracting a custom HAL trait that wraps the 9-byte SPI protocol + flow control GPIO makes the driver genuinely platform-agnostic
- **PC-first for GPU debugging**: Full tracing, frame capture, command replay, and assertion checking are trivial on a PC but impractical on the RP2350
- **Shared core**: ~70% of the host code (scene, geometry, lighting, command building) is pure computation with no platform dependencies

### Alternatives Considered

1. **Single crate with feature flags**: Rejected -- `no_std` vs `std`, different threading models, and different dependency trees make this unwieldy. Would require `#[cfg]` on almost every module.
2. **Separate codebases**: Rejected -- duplicates all shared logic, changes must be applied twice, divergence inevitable.
3. **PC-only testing via simulation**: Rejected -- doesn't test actual SPI protocol over real hardware. FT232H tests the real GPU.

### Consequences

- +3 new crates (pico-gs-core, pico-gs-hal, pico-gs-pc)
- Existing host_app becomes pico-gs-rp2350 (breaking rename)
- asset_build_tool moves to crates/ (path change only)
- GPU debugging dramatically simplified with PC logging + frame capture
- Both platforms share identical GPU driver and rendering logic
- Build system (build.sh, Cargo.toml) must be updated
- All specification path references must be updated

### References

- INT-040: Host Platform HAL (trait definitions)
- REQ-100: Host Firmware Architecture (multi-platform)
- REQ-010.01: PC Debug Host (PC-specific requirements)
- UNIT-035: PC SPI Driver (FT232H implementation)

---
