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
├── spi_gpu/              # FPGA RTL component (SystemVerilog)
│   ├── src/              # RTL sources (gpu_top.sv, core/, spi/, memory/, render/, display/, utils/)
│   ├── tests/            # Testbenches (parallel structure)
│   ├── constraints/      # FPGA constraints
│   └── Makefile          # FPGA build system
├── host_app/             # RP2350 firmware component (Rust)
│   ├── src/              # Firmware sources
│   ├── tests/            # Firmware tests
│   └── Cargo.toml        # Workspace member
├── asset_build_tool/     # Asset preparation tool (Rust)
│   ├── src/              # Tool sources
│   └── Cargo.toml        # Workspace member
├── assets/               # Asset management
│   ├── source/           # Source assets (.obj, .png - committed)
│   └── compiled/         # Generated assets (.rs, .bin - gitignored)
├── doc/                  # Syskit specifications
│   ├── requirements/     # REQ-NNN documents (what the system must do)
│   ├── interfaces/       # INT-NNN documents (contracts between components)
│   └── design/           # UNIT-NNN documents (how components implement requirements)
├── build.sh              # Unified build script
└── Cargo.toml            # Workspace root
```

## Commands

# Build entire project
./build.sh

# Build specific component
./build.sh --fpga-only
./build.sh --firmware-only
./build.sh --assets-only

# Build in release mode
./build.sh --release

# FPGA-specific builds
cd spi_gpu && make bitstream
cd spi_gpu && make synth

# Firmware-specific builds
cargo build -p pico-gs-host
cargo test -p pico-gs-host 

## Code Style

: Follow standard conventions

## Recent Changes
- 003-asset-data-prep: Added Rust stable (1.75+) + PNG decoding library, OBJ file parser
- 003-asset-data-prep: Added Rust stable (1.75+)
- 002-rp2350-host-software: Added Rust (stable), target `thumbv8m.main-none-eabihf` (Cortex-M33 with hardware FPU) + `rp235x-hal` ~0.2.x, `cortex-m-rt` 0.7.x, `heapless` 0.8.x, `glam` 0.29.x (no_std), `fixed` 1.28.x, `defmt` 0.3.x, TinyUSB (C FFI for USB host)


<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->

## syskit

This project uses syskit for specification-driven development.

**Before any syskit workflow, read `.syskit/AGENTS.md` for full instructions.**

Quick reference:
- `/syskit-guide` — Interactive onboarding (start here if new)
- `/syskit-impact <change>` — Analyze impact of a proposed change
- `/syskit-propose` — Propose spec modifications based on impact analysis
- `/syskit-plan` — Create implementation task breakdown
- `/syskit-implement` — Execute planned tasks

**Specifications** live in `doc/`:
- `doc/requirements/` — REQ-NNN documents (what the system must do)
- `doc/interfaces/` — INT-NNN documents (contracts between components)
- `doc/design/` — UNIT-NNN documents (how components implement requirements)

**Key documents**:
- [INT-010](doc/interfaces/int_010_gpu_register_map.md) — GPU Register Map (primary hardware/software interface)
- [INT-011](doc/interfaces/int_011_sram_memory_layout.md) — SRAM Memory Layout
- [INT-020](doc/interfaces/int_020_gpu_driver_api.md) — GPU Driver API (host firmware)
- [INT-021](doc/interfaces/int_021_render_command_format.md) — Render Command Format
- [REQ-050](doc/requirements/req_050_performance_targets.md) — Performance Targets
- [doc/design/design_decisions.md](doc/design/design_decisions.md) — Architecture Decision Records (ADRs)
- [doc/design/concept_of_execution.md](doc/design/concept_of_execution.md) — Runtime behavior

Working documents live in `.syskit/` (analysis, tasks, manifest).

# Scripts and tools

* Prefer to use pre-created .sh files when available
* Prefer to use common bash commands
* Python is not available
