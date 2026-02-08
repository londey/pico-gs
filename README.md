# pico-gs
This repository contains the design and implementation of an FPGA based 3D graphics synthesiser for the ICEpi platform.

## Architecture

pico-gs consists of three main components:

- **spi_gpu** - ECP5 FPGA implementing the 3D graphics pipeline (SystemVerilog)
- **host_app** - RP2350 host firmware driving the GPU (Rust no_std)
- **asset_build_tool** - Asset preparation pipeline converting OBJ/PNG to GPU formats (Rust)

## Repository Structure

```
pico-gs/
├── spi_gpu/              # FPGA RTL component
│   ├── src/              # SystemVerilog sources
│   ├── tests/            # Verilator testbenches
│   ├── constraints/      # ECP5 constraints
│   └── Makefile          # FPGA build system
├── host_app/             # RP2350 firmware
│   ├── src/              # Rust firmware sources
│   ├── tests/            # Firmware unit tests
│   └── Cargo.toml
├── asset_build_tool/     # Asset preparation tool
│   └── src/              # Asset conversion pipeline
├── assets/
│   └── compiled/         # Generated GPU data (gitignored)
├── doc/                  # Syskit specifications
│   ├── requirements/     # REQ-NNN (what the system must do)
│   ├── interfaces/       # INT-NNN (contracts between components)
│   └── design/           # UNIT-NNN (implementation approach)
├── build.sh              # Unified build script
└── Cargo.toml            # Workspace root
```

## Specifications

This project follows specification-driven development using syskit.

**Requirements** (`doc/requirements/`) define what the system must do:
- REQ-001 through REQ-016: SPI GPU features (v1.0 and v2.0)
- REQ-020 through REQ-029: GPU functional requirements (SPI, rasterization, texture, display)
- REQ-110 through REQ-123: RP2350 host firmware capabilities

**Interfaces** (`doc/interfaces/`) define contracts:
- INT-010: GPU Register Map (primary hardware/software contract)
- INT-011: SRAM Memory Layout (framebuffer, z-buffer, textures)
- INT-020: GPU Driver API (host firmware SPI driver)
- INT-021: Render Command Format (inter-core communication)

**Design** (`doc/design/`) documents implementation:
- UNIT-001 through UNIT-009: FPGA GPU hardware modules
- UNIT-020 through UNIT-027: Host firmware software components
- UNIT-030 through UNIT-034: Asset pipeline processing stages
- design_decisions.md: Architecture Decision Records (ADRs)
- concept_of_execution.md: Runtime behavior documentation

To explore the specifications:
1. Start with requirements to understand features
2. Check interfaces to see contracts between components
3. Read design units to understand implementation approach
4. Follow traceability links (REQ → INT → UNIT → code files)

## Building

### Prerequisites

- Rust stable (1.75+)
- FPGA toolchain: Yosys, nextpnr-ecp5, ecppack
- Verilator (for RTL simulation)
- ARM cross-compilation target: `rustup target add thumbv8m.main-none-eabihf`

### Build Commands

Build everything:
```bash
./build.sh
```

Build specific components:
```bash
./build.sh --fpga-only       # Build FPGA bitstream only
./build.sh --firmware-only   # Build RP2350 firmware only
./build.sh --assets-only     # Process assets only
```

Build in release mode:
```bash
./build.sh --release
```

Flash to hardware:
```bash
./build.sh --flash-fpga --flash-firmware
```

### Component-Specific Builds

**FPGA:**
```bash
cd spi_gpu
make bitstream    # Full synthesis, PNR, bitstream
make synth        # Synthesis only
make program      # Flash to FPGA via JTAG
```

**Firmware:**
```bash
cargo build -p pico-gs-host
cargo test -p pico-gs-host
```

**Assets:**
```bash
cargo build -p asset-prep
./target/debug/asset-prep mesh host_app/assets/meshes/model.obj -o assets/compiled/meshes
```

## Development

See [CLAUDE.md](CLAUDE.md) for development guidelines and project conventions.

## License

MIT
