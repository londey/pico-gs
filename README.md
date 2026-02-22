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

## Installing onto Hardware

pico-gs requires two boards: an **ICEpi Zero** (ECP5 FPGA) for the GPU and a **Raspberry Pi Pico 2** (RP2350) as the host controller.

### Prerequisites

In addition to the build prerequisites above:

- [openFPGALoader](https://trabucayre.github.io/openFPGALoader/) for FPGA programming
- [probe-rs](https://probe.rs/) for RP2350 flashing (via a debug probe such as the Raspberry Pi Debug Probe or another CMSIS-DAP adapter)

### Step 1: Build in release mode

```bash
./build.sh --release
```

This produces:
- FPGA bitstream: `build/gpu_top.bit`
- Firmware ELF: `build/pico-gs-rp2350.elf`

### Step 2: Flash the ICEpi Zero

Connect the ICEpi Zero via USB (the on-board FT231X provides JTAG).

**Volatile load** (bitstream lost on power-off — useful for development):
```bash
openFPGALoader -b icepi-zero build/gpu_top.bit
```

**Persistent flash** (bitstream survives power cycles):
```bash
openFPGALoader -b icepi-zero --write-flash build/gpu_top.bit
```

> **Note:** If you have an older version of openFPGALoader that does not recognise the `-b icepi-zero` flag, use `-cft231X --pins=7:3:5:6` instead.

### Step 3: Flash the Pico 2

#### Option A: Debug probe (probe-rs)

Connect a CMSIS-DAP debug probe (e.g. Raspberry Pi Debug Probe) to the Pico 2's SWD pins, then run:

```bash
probe-rs run --chip RP2350 build/pico-gs-rp2350.elf
```

Or use the cargo runner shortcut (configured in `.cargo/config.toml`):

```bash
cargo run --release -p pico-gs-rp2350 --target thumbv8m.main-none-eabihf
```

#### Option B: UF2 drag-and-drop (no debug probe required)

1. Hold the **BOOTSEL** button on the Pico 2 while connecting it via USB.
   It mounts as a USB mass-storage device.
2. Convert the ELF to UF2:
   ```bash
   elf2uf2-rs build/pico-gs-rp2350.elf build/pico-gs-rp2350.uf2
   ```
3. Copy the `.uf2` file to the mounted drive.
   The Pico 2 reboots and runs the firmware automatically.

> Install the conversion tool with `cargo install elf2uf2-rs` if you don't have it.

### One-step build and flash

The build script can build and flash both targets in one go:

```bash
./build.sh --release --flash-fpga --flash-firmware
```

## Development

See [CLAUDE.md](CLAUDE.md) for development guidelines and project conventions.

### Conventions

Fixed-point values throughout the project use TI-style Q notation (`Qm.n` for signed, `UQm.n` for unsigned).
See [CLAUDE.md](CLAUDE.md) for the full definition and examples.

## License

MIT
