# pico-gs

A PS1/N64-era 3D graphics processor implemented in SystemVerilog, targeting the **ECP5-25K** FPGA on an [ICEpi Zero v1.3](external/icepi-zero/) board.
An **RP2350** (Raspberry Pi Pico 2) drives the GPU over SPI; the GPU outputs 640x480 @ 60 Hz DVI.
Named after the PS2 Graphics Synthesizer.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the GPU pipeline architecture, block diagram, and memory system.

## Repository Structure

```
pico-gs/
├── spi_gpu/              # FPGA RTL (SystemVerilog)
├── crates/
│   ├── pico-gs-hal/      # Platform abstraction traits (no_std)
│   ├── pico-gs-core/     # GPU driver, rendering, scene (no_std)
│   ├── pico-gs-rp2350/   # RP2350 firmware (dual-core, USB keyboard)
│   ├── pico-gs-pc/       # PC debug host (FT232H stub)
│   └── asset-build-tool/ # OBJ/PNG → GPU format converter
├── registers/            # GPU register interface (SystemRDL source of truth)
├── doc/                  # Syskit specifications (REQ/INT/UNIT)
├── ARCHITECTURE.md       # GPU architecture document
├── build.sh              # Unified build script
└── Cargo.toml            # Workspace root
```

## Specifications

This project uses [syskit](CLAUDE.md#syskit) for specification-driven development.
Specifications live in `doc/`:

- **Requirements** (`doc/requirements/`): What the system must do (REQ-NNN)
- **Interfaces** (`doc/interfaces/`): Contracts between components (INT-NNN)
- **Design** (`doc/design/`): Implementation approach and decisions (UNIT-NNN)

## Building

### Prerequisites

- Rust stable (1.75+)
- FPGA toolchain: Yosys, nextpnr-ecp5, ecppack
- Verilator (for RTL simulation)
- ARM cross-compilation target: `rustup target add thumbv8m.main-none-eabihf`

### Build Commands

Build everything (software + FPGA + all tests):
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
cargo build -p pico-gs-rp2350 --target thumbv8m.main-none-eabihf
cargo test -p pico-gs-core
```

**Asset tool:**
```bash
cargo build -p asset-build-tool
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

## License

MIT
