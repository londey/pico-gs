# pico-gs Development Guidelines

## Key Rules

- `./build.sh --check` must pass after every change (Verilator lint, cargo fmt, cargo check, cargo clippy).
- Minimize blast radius: only change code directly related to the current task. If you notice problems in other areas, mention them but don't fix them without approval.
- `ARCHITECTURE.md` is the authoritative high-level GPU architecture document.
- `spi_gpu/dt/gs-twin/` is the authoritative detailed design for the pixel pipeline; read the corresponding gs-twin module before modifying RTL in `spi_gpu/src/render/`.
- `registers/rdl/gpu_regs.rdl` is the authoritative GPU register definition; generated output from `registers/scripts/generate.sh` is what code must reference for register values and constants.
- All code follows its respective style guide:
  - SystemVerilog: `.claude/skills/claude-skill-verilog/SKILL.md`
  - Rust: `.claude/skills/claude-skill-rust/SKILL.md`
  - C++: `.claude/skills/claude-skill-cpp/SKILL.md`
- ICEpi Zero board documentation lives in `external/icepi-zero/`; always consult this directory before searching the web.

## Project Structure

```text
pico-gs/
├── crates/
│   └── qfixed/               # Fixed-point math library
├── registers/                 # GPU register interface (single source of truth)
│   ├── rdl/gpu_regs.rdl       # SystemRDL register definitions
│   ├── src/lib.rs             # Rust crate (gpu-registers, no_std)
│   └── scripts/generate.sh   # PeakRDL codegen → Rust + SV
├── spi_gpu/                   # FPGA RTL component (SystemVerilog)
│   ├── src/                   # RTL sources
│   │   ├── core/              # Core pipeline logic
│   │   ├── display/           # Scan-out / display
│   │   ├── memory/            # Memory controllers
│   │   ├── render/            # Pixel pipeline RTL
│   │   ├── spi/               # SPI transport + generated register file
│   │   ├── utils/             # Shared RTL utilities
│   │   ├── gpu_top.sv         # Top-level module
│   │   └── fp_types_pkg.sv    # Fixed-point type package
│   ├── dt/                    # Digital twin (bit-accurate Rust model)
│   │   ├── gs-twin/           # Library: authoritative pipeline algorithms
│   │   └── gs-twin-cli/       # CLI: render golden references, diff vs Verilator
│   ├── tests/                 # Testbenches
│   ├── sim/                   # Simulation support files
│   ├── scripts/               # Build/test scripts
│   ├── constraints/           # FPGA constraints
│   └── Makefile               # FPGA build system
├── doc/                       # Syskit specifications
│   ├── requirements/          # REQ-NNN documents
│   ├── interfaces/            # INT-NNN documents
│   ├── design/                # UNIT-NNN documents
│   ├── verification/          # VER-NNN documents
│   └── reports/               # Technical reports
├── external/
│   └── icepi-zero/            # Board documentation (git submodule)
├── ARCHITECTURE.md            # Authoritative GPU architecture document
├── build.sh                   # Unified build script
└── Cargo.toml                 # Workspace root
```

## Digital Twin (gs-twin)

The digital twin (`spi_gpu/dt/gs-twin/`) is the **authoritative detailed design** for the GPU's rasterizer and pixel pipeline.
Its rustdoc on each type and function IS the design spec for the corresponding RTL module.
It is a bit-accurate, transaction-level Rust model — not cycle-accurate (Verilator owns that role).

### When to consult gs-twin

- **Before implementing or modifying pixel pipeline SystemVerilog**, read the corresponding gs-twin module first to understand the expected bit-accurate behavior.
- **When debugging RTL mismatches**, gs-twin output is the "expected" result — the RTL must match it exactly at the RGB565 pixel level.
- **When adding new pipeline features**, implement in gs-twin first, verify with golden image tests, then implement the RTL to match.

### Module mapping (gs-twin → RTL)

| gs-twin module | RTL module(s) | Pipeline stage |
|----------------|---------------|----------------|
| `pipeline/rasterize.rs` | `rasterizer.sv`, `raster_recip_area.sv`, `raster_deriv.sv`, `raster_edge_walk.sv` | Triangle setup + iteration |
| `pipeline/stipple.rs` | `stipple.sv` | Stipple test |
| `pipeline/early_z.rs` | `early_z.sv` | Early depth test |
| `pipeline/tex_sample.rs` | `texture_cache.sv`, `texture_*.sv` decoders | Texture sampling |
| `pipeline/color_combine.rs` | `color_combiner.sv` | Color combiner |
| `pipeline/alpha_blend.rs` | `alpha_blend.sv` | Alpha blending |
| `pipeline/dither.rs` | `dither.sv` | Ordered dithering |
| `pipeline/pixel_write.rs` | `pixel_pipeline.sv` | Framebuffer write |
| `reg.rs` | `register_file.sv` | Register decode |
| `mem.rs` | `sram_arbiter.sv` (INT-011 tiled layout) | Memory model |
| `pipeline/recip.rs` | `raster_recip_lut.sv`, `raster_recip_q.sv` | Reciprocal LUTs |

### Verification workflow

- `cargo test -p gs-twin` — runs golden image tests (exact RGB565 match)
- `cargo run -p gs-twin-cli -- render` — generates reference PNGs
- Same `.hex` scripts in `spi_gpu/dt/gs-twin/tests/scripts/` feed both gs-twin and Verilator testbenches
- Any pixel mismatch = real bug in RTL (not floating-point divergence)
- Full workflow: `./build.sh --dt-only`

### Scope boundaries

- **gs-twin owns:** rasterization algorithms, pixel pipeline math, fixed-point formats, memory addressing
- **gs-twin does NOT model:** scan-out/display (UNIT-008), cycle-level timing, SPI transport
- **syskit UNIT docs** for algorithmic pipeline modules are thin pointers to gs-twin source

For detailed architecture, see `spi_gpu/dt/README.md`.

## Commands

# Build entire project (FPGA + digital twin + tests)
./build.sh

# Quick lint check (Verilator lint, cargo fmt/check/clippy)
./build.sh --check

# Build specific components
./build.sh --fpga-only
./build.sh --dt-only
./build.sh --test-only

# FPGA-specific builds
cd spi_gpu && make bitstream
cd spi_gpu && make synth

# Digital twin build and test
cargo test -p gs-twin

## Rust Code Style

- Follow standard Rust conventions and idioms; use `rustfmt` for formatting
- Prefer modern `module_name.rs` file style over `mod.rs` (Rust 2018+)
- All public items require `///` doc comments (modules use `//!`); functions need `# Arguments`, `# Returns`, `# Errors` sections
- Document constants with purpose and spec reference where applicable
- Blank lines between module-level items, between doc-commented struct fields, and after `use` blocks
- Avoid `.unwrap()` / `.expect()` in production code; use `Result<T, E>` + `?` operator
- Libraries: `thiserror` for error types; applications: `anyhow` (std crates only; no_std uses custom enums)
- Logging: `defmt` for no_std/embedded, `log` crate for std; avoid `println!`/`eprintln!`
- Add dependencies with `default-features = false`, explicitly enable only needed features
- Crate-level lints: `#![deny(unsafe_code)]`, clippy pedantic + `missing_docs` gated on release builds via `cfg_attr`

### Build Verification (Rust)

After changes: `cargo fmt` → `cargo clippy -- -D warnings` → `cargo test` → `cargo build --release`

## SystemVerilog Code Style

- All `.sv` files MUST follow `.claude/skills/claude-skill-verilog/SKILL.md`.
- Lint with `verilator --lint-only -Wall`; fix all warnings, do not suppress with pragmas.
- Before modifying pixel pipeline RTL (`spi_gpu/src/render/`), read the corresponding gs-twin module in `spi_gpu/dt/gs-twin/src/pipeline/` to understand the expected bit-accurate behavior.
  The Rust twin is the authoritative algorithm spec; the RTL must produce identical results.

## C++ Code Style

When writing or modifying C++ code (`.cpp`, `.hpp`), follow `.claude/skills/claude-skill-cpp/SKILL.md`.
Target **C++20** (`-std=c++20`).

## Markdown Style

- Use semantic line breaks: start each sentence on its own line.
  Adjacent lines render as a single paragraph in HTML, but one-sentence-per-line produces cleaner diffs and easier code review.

## Fixed-Point Notation

All fixed-point values use TI-style Q notation:
- `Qm.n` — signed: m integer bits (including sign bit), n fractional bits, total width = m + n bits.
- `UQm.n` — unsigned: m integer bits, n fractional bits, total width = m + n bits.

Examples:
- `Q2.2` is a signed 4-bit value with resolution 2⁻² (1/4), range −2.0 to +1.75.
- `UQ2.2` is an unsigned 4-bit value with resolution 2⁻² (1/4), range 0.0 to +3.75.

Apply this notation consistently in documentation, code comments, and specifications.
When sign/unsigned is ambiguous, always use the explicit `Q` or `UQ` prefix.

## ICEpi Zero Board Documentation

The ICEpi Zero v1.3 board documentation lives locally at `external/icepi-zero/`.
**Always consult this directory before searching the web for ICEpi Zero pinouts, schematics, or constraints.**

Key files:
- `external/icepi-zero/firmware/v1.3/icepi-zero-v1_3.lpf` — Official v1.3 pin constraints (canonical source of truth for all ball assignments)
- `external/icepi-zero/hardware/v1.3/` — KiCad schematics and PCB files
- `external/icepi-zero/documentation/manual.pdf` — Board manual

The board uses an **ECP5-25K in CABGA256** package.
All valid ball coordinates use columns A–T (no column >16 for rows; columns are letters A–T and rows are numbers 1–16).
Pins like B19, A18, A19, C19, D19, E19 do **not** exist in CABGA256 and must not be used.

GPIO header pins available for SPI from an external MCU (from the official LPF):

| Signal       | Ball | Header pin # | Notes                  |
|--------------|------|--------------|------------------------|
| pi_miso      | J1   | 21           | gpio[9]                |
| pi_mosi      | L2   | 19           | gpio[10]               |
| pi_sclk      | G2   | 23           | gpio[11]               |
| pi_ce0       | H2   | 24           | gpio[8]                |
| pi_nirq      | J2   | 22           | gpio[25] (IRQ/flow ctrl)|
| pi_rx (UART) | N1   | 10           | gpio[15]               |
| pi_tx (UART) | P1   | 8            | gpio[14]               |

All GPIO header balls (gpio[0]–gpio[27]) use LVCMOS33 at 3.3 V.

## Register Interface

The register interface (`registers/`) is the single source of truth for the GPU register map.
INT-010 through INT-014 live in `doc/interfaces/` alongside all other interface specs, but are **NOT managed by syskit** — do not use syskit workflows to modify them.

- **SystemRDL source:** `registers/rdl/gpu_regs.rdl` — canonical machine-readable definition
- **Rust crate:** `registers/src/lib.rs` (`gpu-registers`, `no_std`) — hand-maintained flat constants matching the RDL
- **Generated SV:** `spi_gpu/src/spi/generated/` — PeakRDL output (package + register file module)
- **Specs:** `doc/interfaces/int_010_*` through `int_014_*` — register interface specifications

Change process:
1. Edit `registers/rdl/gpu_regs.rdl` and update `registers/src/lib.rs` to match
2. Update the corresponding markdown spec in `doc/interfaces/`
3. Run `registers/scripts/generate.sh` to regenerate SV
4. Review the diff in generated files
5. Update consuming code (`driver.rs`, `register_file.sv`) if register semantics changed

<!-- syskit-start -->
## syskit

This project uses **syskit** for specification-driven development. Specifications in `doc/` define what the system must do, how components interact, and how the design is structured. Implementation follows from specs. When creating new specifications, define interfaces and requirements before design — understand the contracts and constraints before deciding how to build.

### Working with code

- Source files may contain `Spec-ref:` comments linking to design units — **preserve these; never edit the hash manually**.
- Before modifying code, check `doc/design/` for a relevant design unit (`unit_NNN_*.md`) that describes the component's intended behavior.
- After code changes, run `.syskit/scripts/impl-check.sh` to verify spec-to-implementation freshness.
- After spec changes, run `.syskit/scripts/impl-stamp.sh UNIT-NNN` to update Spec-ref hashes in source files.

### Documentation principle

- **Reference, don't reproduce.** Don't duplicate definitions, requirements, or design descriptions — reference the authoritative source instead. For project documents, reference by ID (`REQ-NNN`, `INT-NNN`, `UNIT-NNN`, `VER-NNN`). For external standards, reference by name, version/year, and section number (e.g., "IEEE 802.3-2022 §4.2.1", "RFC 9293 §3.1"). This applies to specification documents and code comments alike.

### Making changes

For non-trivial changes affecting system behavior, use the syskit workflow:

1. `/syskit-impact <change>` — Analyze what specifications are affected
2. `/syskit-propose` — Propose specification updates
3. `/syskit-refine --feedback "<issues>"` — Iterate on proposed changes based on review feedback (optional, repeatable)
4. `/syskit-approve` — Approve changes (works across sessions, enables overnight review)
5. `/syskit-plan` — Break into implementation tasks
6. `/syskit-implement` — Execute with traceability

New to syskit? Run `/syskit-guide` for an interactive walkthrough.

### Reference

- Specifications: `doc/requirements/`, `doc/interfaces/`, `doc/design/`, `doc/verification/`
- Working documents: `.syskit/analysis/`, `.syskit/tasks/`
- Scripts: `.syskit/scripts/`
- Full instructions: `.syskit/AGENTS.md` (read on demand, not auto-loaded)
<!-- syskit-end -->
