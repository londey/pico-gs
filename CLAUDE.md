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
