# pico-gs Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-01-31

## Active Technologies
- Rust (stable), target `thumbv8m.main-none-eabihf` (Cortex-M33 with hardware FPU) + `rp235x-hal` ~0.2.x, `cortex-m-rt` 0.7.x, `heapless` 0.8.x, `glam` 0.29.x (no_std), `fixed` 1.28.x, `defmt` 0.3.x, TinyUSB (C FFI for USB host) (002-rp2350-host-software)
- Flash (4 MB) for mesh data, texture data, and firmware binary; RP2350 SRAM (520 KB) for runtime state (002-rp2350-host-software)
- Rust stable (1.75+) (003-asset-data-prep)
- File I/O (input: .png/.obj files, output: .rs source files + .bin data files) (003-asset-data-prep)
- Rust stable (1.75+) + PNG decoding library, OBJ file parser (003-asset-data-prep)

- (002-rp2350-host-software)

## Project Structure

```text
pico-gs/
├── crates/
│   ├── pico-gs-hal/          # Platform abstraction traits (no_std)
│   │   └── src/lib.rs        # SpiTransport, FlowControl, InputSource traits
│   ├── pico-gs-core/         # Platform-agnostic GPU driver, rendering, scene (no_std)
│   │   ├── src/
│   │   │   ├── gpu/          # GpuDriver<S>, registers, vertex packing
│   │   │   ├── math/         # Fixed-point math (12.4, 1.15, z25)
│   │   │   ├── render/       # Commands, mesh rendering, transform, lighting
│   │   │   └── scene/        # Scene management, demo definitions
│   │   └── tests/            # Integration tests
│   ├── pico-gs-rp2350/       # RP2350 firmware (dual-core, USB keyboard, SPI GPIO)
│   │   ├── src/
│   │   │   ├── transport.rs  # Rp2350Transport: SpiTransport + FlowControl
│   │   │   ├── input.rs      # USB keyboard InputSource
│   │   │   ├── core1.rs      # Core 1 render loop (SPSC consumer)
│   │   │   ├── queue.rs      # SPSC queue type aliases
│   │   │   ├── assets/       # Build-generated mesh/texture includes
│   │   │   └── main.rs       # Dual-core entry point
│   │   ├── build.rs          # Asset conversion via asset-build-tool
│   │   ├── assets/           # Source assets (.obj, .png)
│   │   └── memory.x          # RP2350 linker script
│   ├── pico-gs-pc/           # PC debug host (FT232H stub, terminal input)
│   │   └── src/
│   │       ├── transport.rs  # Ft232hTransport (stub, todo!())
│   │       ├── input.rs      # TerminalInput (stub)
│   │       └── main.rs       # Single-threaded entry point
│   └── asset-build-tool/     # Asset preparation tool (.obj/.png → GPU format)
│       └── src/
├── spi_gpu/                  # FPGA RTL component (SystemVerilog)
│   ├── src/                  # RTL sources
│   ├── tests/                # Testbenches
│   ├── constraints/          # FPGA constraints
│   └── Makefile              # FPGA build system
├── doc/                      # Syskit specifications
│   ├── requirements/         # REQ-NNN documents
│   ├── interfaces/           # INT-NNN documents
│   └── design/               # UNIT-NNN documents
├── build.sh                  # Unified build script
└── Cargo.toml                # Workspace root
```

## Commands

# Build entire project
./build.sh

# Build specific component
./build.sh --fpga-only
./build.sh --firmware-only
./build.sh --pc-only
./build.sh --assets-only

# Build in release mode
./build.sh --release

# FPGA-specific builds
cd spi_gpu && make bitstream
cd spi_gpu && make synth

# Firmware-specific builds (RP2350)
cargo build -p pico-gs-rp2350 --target thumbv8m.main-none-eabihf
cargo test -p pico-gs-core

# PC debug host build
cargo build -p pico-gs-pc

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

- All modules, wires, registers require comments; active-low signals use `_n` suffix
- `always_ff`: simple non-blocking assignments only (exceptions: memory inference, async reset synchronizers)
- `always_comb`: all combinational logic; default assignments at top to avoid latches
- One declaration per line; explicit bit widths on all literals; files start with `` `default_nettype none ``
- Always use `begin`/`end` blocks for `if`/`else`/`case`
- FSMs: separate state register (`always_ff`) from next-state logic (`always_comb`); use enums for state encoding
- One module per file, filename matches module name; always use named port connections
- CDC: 2-FF synchronizer for single-bit, gray coding for multi-bit
- Lint with `verilator --lint-only -Wall`; fix all warnings, do not suppress with pragmas

## Recent Changes
- 003-asset-data-prep: Added Rust stable (1.75+) + PNG decoding library, OBJ file parser
- 003-asset-data-prep: Added Rust stable (1.75+)
- 002-rp2350-host-software: Added Rust (stable), target `thumbv8m.main-none-eabihf` (Cortex-M33 with hardware FPU) + `rp235x-hal` ~0.2.x, `cortex-m-rt` 0.7.x, `heapless` 0.8.x, `glam` 0.29.x (no_std), `fixed` 1.28.x, `defmt` 0.3.x, TinyUSB (C FFI for USB host)


<!-- MANUAL ADDITIONS START -->

## Markdown Style

- Use semantic line breaks: start each sentence on its own line.
  Adjacent lines render as a single paragraph in HTML, but one-sentence-per-line produces cleaner diffs and easier code review.

## ICEpi Zero Board Documentation

The ICEpi Zero v1.3 board documentation lives locally at `external/icepi-zero/`.
**Always consult this directory before searching the web for ICEpi Zero pinouts, schematics, or constraints.**

Key files:
- `external/icepi-zero/firmware/v1.3/icepi-zero-v1_3.lpf` — Official v1.3 pin constraints (canonical source of truth for all ball assignments)
- `external/icepi-zero/hardware/v1.3/` — KiCad schematics and PCB files
- `external/icepi-zero/documentation/manual.pdf` — Board manual
- `external/icepi-zero/firmware/icepi-zero.lpf` — Symlink pointing to v1.3 LPF

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

<!-- MANUAL ADDITIONS END -->

<!-- syskit-start -->
## syskit

This project uses **syskit** for specification-driven development. Specifications in `doc/` define what the system must do, how components interact, and how the design is structured. Implementation follows from specs. When creating new specifications, define interfaces and requirements before design — understand the contracts and constraints before deciding how to build.

### Working with code

- Source files may contain `Spec-ref:` comments linking to design units — **preserve these; never edit the hash manually**.
- Before modifying code, check `doc/design/` for a relevant design unit (`unit_NNN_*.md`) that describes the component's intended behavior.
- After code changes, run `.syskit/scripts/impl-check.sh` to verify spec-to-implementation freshness.
- After spec changes, run `.syskit/scripts/impl-stamp.sh UNIT-NNN` to update Spec-ref hashes in source files.

### Making changes

For non-trivial changes affecting system behavior, use the syskit workflow:

1. `/syskit-impact <change>` — Analyze what specifications are affected
2. `/syskit-propose` — Propose all specification updates at once
   **OR** `/syskit-refine --scope <type>` — Propose changes incrementally by document type (requirements, interfaces, design)
3. `/syskit-plan` — Break into implementation tasks
4. `/syskit-implement` — Execute with traceability

New to syskit? Run `/syskit-guide` for an interactive walkthrough.

### Reference

- Specifications: `doc/requirements/`, `doc/interfaces/`, `doc/design/`
- Working documents: `.syskit/analysis/`, `.syskit/tasks/`
- Scripts: `.syskit/scripts/`
- Full instructions: `.syskit/AGENTS.md` (read on demand, not auto-loaded)
<!-- syskit-end -->
