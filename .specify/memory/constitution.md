<!--
SYNC IMPACT REPORT
==================
Version Change: None specified → 1.1.0
Bump Type: MINOR (new articles added)
Date: 2026-02-01

Modified Principles:
- None (no existing principles changed)

Added Sections:
- Article X: Rust Code Standards
- Article XI: Verilog/SystemVerilog Code Standards
- Governance section (version tracking)

Removed Sections:
- None

Templates Requiring Updates:
- ✅ .specify/templates/plan-template.md (reviewed - Constitution Check section remains generic)
- ✅ .specify/templates/spec-template.md (reviewed - no constitution references)
- ✅ .specify/templates/tasks-template.md (reviewed - no constitution references)

Follow-up TODOs:
- None
-->

# Project Constitution: ICEpi GPU

**Version**: 1.1.0
**Ratified**: 2026-01-29
**Last Amended**: 2026-02-01

## Preamble

This document establishes the non-negotiable principles governing the development of a PS2 GS-inspired graphics processor for the ICEpi Zero development board. These principles ensure architectural consistency, resource discipline, and incremental deliverability.

---

## Article I: Open Toolchain Mandate

All RTL **must** synthesize using the open-source FPGA toolchain:

- **Synthesis**: Yosys
- **Place & Route**: nextpnr-ecp5
- **Programming**: openFPGALoader
- **Simulation**: Verilator or Icarus Verilog with cocotb testbenches

No vendor-specific primitives are permitted except documented ECP5 hard blocks (SERDES, PLL, DSP48, EBR). If a feature requires proprietary IP, it must be flagged and an open alternative found or the feature deferred.

---

## Article II: Resource Budget Discipline

The ECP5-25K provides finite resources. All modules **must** document their utilization:

| Resource | Budget | Headroom Target |
|----------|--------|-----------------|
| LUTs | 24,000 | Use ≤ 20,000 |
| BRAM (EBR) | 1,008 kbit | Use ≤ 800 kbit |
| DSP blocks | 28 | Use ≤ 24 |
| SRAM bandwidth | 200 MB/s | Reserve 80 MB/s for display |

Post-synthesis resource reports **must** be generated and reviewed before integration. Any module exceeding 25% of total budget requires architectural review.

---

## Article III: Bandwidth-First Design

Display refresh has **absolute priority** over all other SRAM access. The memory arbiter must guarantee:

1. No visible tearing or scanline corruption under any draw load
2. Display read-ahead FIFO sufficient to mask arbiter latency
3. Draw operations gracefully degrade (stall) rather than corrupt display

Bandwidth allocation:
- Display scanout: 74 MB/s guaranteed (640×480×32bpp×60Hz)
- Draw operations: Best-effort with remaining bandwidth
- Texture fetch: Shared with draw, prioritized per-pixel

---

## Article IV: Interface Stability Covenant

The SPI register interface is the **contract** with host software. Once a register address and bit field is documented in the specification:

1. The address **shall not** be reassigned
2. Bit field meanings **shall not** change semantically
3. Reserved bits **shall** read as zero and ignore writes

Breaking changes require a major version increment and explicit migration documentation. The host-side driver must be able to detect GPU version via a read-only ID register.

---

## Article V: Test-First Development

**No RTL module shall be integrated without simulation coverage.**

Required test progression:
1. **Unit tests**: Individual module functionality (edge functions, interpolators, etc.)
2. **Integration tests**: Module interactions (arbiter + draw engine + display controller)
3. **Reference tests**: Rasterizer output compared against software reference implementation
4. **Hardware tests**: On-device validation after synthesis

Cocotb is the preferred test framework. Test coverage targets:
- All register read/write paths
- All state machine transitions
- Boundary conditions (screen edges, texture wrap, FIFO full/empty)

---

## Article VI: Incremental Delivery

Features **must** be delivered in layers that provide value at each stage:

| Milestone | Deliverable | Validates |
|-----------|-------------|-----------|
| M1 | SPI register interface | Host communication |
| M2 | Framebuffer clear | SRAM write path |
| M3 | Single pixel write | Coordinate mapping |
| M4 | Flat-shaded triangle | Core rasterizer |
| M5 | DVI output | Display pipeline |
| M6 | Gouraud shading | Color interpolation |
| M7 | Z-buffer | Depth testing |
| M8 | Textured triangle | Full pixel pipeline |

Each milestone **must** be demonstrable on hardware before proceeding. "It works in simulation" is necessary but not sufficient.

---

## Article VII: Simplicity Gate

The GPU targets a **specific, constrained feature set** inspired by PS2 GS:

**In scope:**
- Triangle rasterization with edge walking
- Vertex color interpolation (Gouraud shading)
- Single texture with perspective-correct UV
- Z-buffer depth testing
- Double-buffered framebuffer

**Explicitly out of scope (for initial release):**
- Programmable shaders
- Multiple texture units
- Stencil buffer
- Anti-aliasing
- Alpha blending (deferred to future milestone)

Feature creep is the enemy. Any addition must justify its resource cost and implementation complexity against the core goal: **lit teapot and textured cube on screen**.

---

## Article VIII: Documentation as Artifact

Specifications, register maps, and timing diagrams are **first-class deliverables**, not afterthoughts.

Required documentation:
- Register map with bit-level definitions
- SPI transaction timing diagram
- Memory map showing SRAM allocation
- State machine diagrams for rasterizer and arbiter
- Host-side example code demonstrating triangle submission

Documentation **must** be updated when implementation changes. Stale documentation is a defect.

---

## Article IX: Host Responsibility Boundary

The GPU is a **rasterizer**, not a geometry processor. The host (RP2350) is responsible for:

- Model/view/projection matrix transforms
- Clipping to view frustum
- Perspective division (computing 1/W per vertex)
- Back-face culling
- Scene management and draw ordering

The GPU accepts screen-space vertices with pre-computed attributes. This division of labor matches the PS2 architecture (EE/VU → GS) and keeps the FPGA design tractable.

---

## Article X: Rust Code Standards

All Rust code (host firmware and asset tooling) **must** adhere to the standards documented in `.claude/skills/claude-skill-rust/skill.md`.

**Non-negotiable requirements:**

1. **Module Organization**: Use modern `<module_name>.rs` style, not legacy `mod.rs` patterns
2. **Error Handling**: Use `Result<T, E>` with `?` operator. **No** `.unwrap()` or `.expect()` in production code
   - Libraries: Use `thiserror` for custom error types
   - Applications: Use `anyhow` for error context
3. **Logging**: Use `log` crate with appropriate levels. **No** `println!`/`eprintln!` outside main entry points
4. **Documentation**: All public items **must** have rustdoc comments including:
   - Functions: Purpose, Arguments, Returns, Errors, Panics sections
   - Constants: Purpose and specification references where applicable
5. **Formatting**: Run `cargo fmt` before commits
6. **Linting**: Configure crate-level lints in `lib.rs`/`main.rs` (deny `unsafe_code` unless justified)
7. **Dependencies**: Add with `default-features = false` and explicit feature selection
8. **Build Verification**: All code **must** pass:
   - `cargo fmt --check`
   - `cargo clippy -- -D warnings`
   - `cargo test`
   - `cargo build --release`
   - `cargo deny check` (license and advisory validation)
   - `cargo audit` (security vulnerability scan)

**Rationale**: Embedded systems demand reliability. Panics are unacceptable in no_std firmware contexts. Strict error handling, minimal dependencies, and thorough validation prevent runtime failures in deployed hardware.

---

## Article XI: Verilog/SystemVerilog Code Standards

All RTL code (FPGA modules and testbenches) **must** adhere to the standards documented in `.claude/skills/claude-skill-verilog/skill.md`.

**Non-negotiable requirements:**

1. **Documentation**: All modules, ports, wires, and registers **must** have inline comments
2. **Naming**: Active-low signals use `_n` suffix (e.g., `rst_n`). Descriptive names over abbreviations
3. **Declarations**:
   - Start files with `` `default_nettype none ``
   - One declaration per line with explicit bit widths on all literals
   - Always use `begin`/`end` blocks for `if`/`else`/`case` items
4. **Sequential Logic (`always_ff`)**:
   - **Simple assignments only** (exceptions: memory inference, async reset synchronizers)
   - Use non-blocking assignments (`<=`)
   - All logic belongs in `always_comb`, not `always_ff`
5. **Combinational Logic (`always_comb`)**:
   - Default assignments at block start to prevent latches
   - Use `unique case` or `priority case` with explicit `default`
6. **Module Instantiation**:
   - One module per file, filename matches module name
   - **Named port connections only** (never positional)
7. **Testing**: Every module **must** have a Verilator testbench
   - Build with: `verilator --binary -Wall module_tb.sv module.sv`
   - Run linting: `verilator --lint-only -Wall module.sv`
   - **All warnings must be fixed** (no pragma suppression)
8. **Simulation Flags**: Use comprehensive verification flags:
   - `--assert` (enable assertions)
   - `--trace-fst` (waveform dumps)
   - `--x-assign unique` and `--x-initial unique` (expose uninitialized state bugs)

**Rationale**: FPGA synthesis behavior differs from simulation. Strict separation of combinational and sequential logic ensures Verilator simulations accurately predict synthesized hardware behavior. Comprehensive testing catches timing, initialization, and CDC issues before expensive FPGA compile cycles.

---

## Governance

### Version Control

This constitution follows semantic versioning (MAJOR.MINOR.PATCH):

- **MAJOR**: Backward-incompatible governance changes, principle removals, or architectural redefinitions
- **MINOR**: New principles/articles added or material expansions to existing guidance
- **PATCH**: Clarifications, wording improvements, typo fixes, or non-semantic refinements

### Amendment Process

This constitution may be amended when:

1. A fundamental assumption proves incorrect (e.g., resource constraints more/less severe than anticipated)
2. Architectural changes require updated governance (e.g., transition to different FPGA family)
3. A new capability or technology is deemed essential to project goals

**Amendment procedure:**

1. Propose change with rationale and impact assessment
2. Update constitution file with version increment
3. Update affected templates and documentation for consistency
4. Document in sync impact report (HTML comment at file top)
5. Commit with message format: `docs: amend constitution to vX.Y.Z (brief description)`

### Compliance Review

All feature plans **must** include a "Constitution Check" section validating adherence to applicable articles. Violations require explicit justification in the plan's complexity tracking table.

### Change History

- **1.1.0** (2026-02-01): Added Article X (Rust Code Standards), Article XI (Verilog/SystemVerilog Code Standards), and Governance section
- **1.0.0** (2026-01-29): Initial constitution ratified with Articles I-IX
