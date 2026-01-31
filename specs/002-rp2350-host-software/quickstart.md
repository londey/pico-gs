# Quickstart: RP2350 Host Software

**Feature Branch**: `002-rp2350-host-software`
**Date**: 2026-01-30

---

## Prerequisites

### Hardware
- Raspberry Pi Pico 2 (RP2350) board
- ICEpi Zero with SPI GPU bitstream loaded
- SPI connection: SCK, MOSI, MISO, CS (4 wires)
- GPIO connections: CMD_FULL, CMD_EMPTY, VSYNC (3 wires)
- USB cable for flashing/debugging (Pico 2 USB port)
- (Optional) USB keyboard for demo switching
- (Optional) Debug probe (picoprobe, CMSIS-DAP, or J-Link) for SWD debugging

### Software
- Rust toolchain (stable or nightly)
- Target: `thumbv8m.main-none-eabihf`
- `probe-rs` (v0.24+) for flashing and debugging
- `flip-link` for stack overflow protection

### Install toolchain
```bash
# Install Rust target for Cortex-M33
rustup target add thumbv8m.main-none-eabihf

# Install flashing/debug tools
cargo install probe-rs-tools
cargo install flip-link
cargo install elf2uf2-rs  # Alternative: UF2 drag-and-drop
```

---

## Build & Flash

### Build
```bash
cd firmware
cargo build --release
```

### Flash via probe-rs (SWD debug probe)
```bash
cd firmware
cargo run --release
# Configured in .cargo/config.toml to use probe-rs
```

### Flash via UF2 (no debug probe)
1. Hold BOOTSEL button on Pico 2
2. Connect USB cable (Pico 2 mounts as USB drive)
3. Run:
```bash
cd firmware
cargo build --release
elf2uf2-rs target/thumbv8m.main-none-eabihf/release/pico-gs-host
# Drag the .uf2 file to the Pico 2 USB drive
```

---

## Verify

### Step 1: GPU Detection
On power-up, the host reads the GPU ID register (0x7F). Expected value: `0x6702` (GPU v2.0).

**Success**: LED solid (or defmt log: "GPU detected: v2.0")
**Failure**: LED blink pattern (error indicator), system halts

### Step 2: Default Demo
After successful GPU init, the Gouraud-shaded triangle demo starts automatically.

**Success**: A smoothly shaded triangle appears on the display within 2 seconds.

### Step 3: Demo Switching (requires USB keyboard)
- Press `1` → Gouraud-shaded triangle
- Press `2` → Textured triangle
- Press `3` → Spinning Utah Teapot

---

## Development Workflow

### Logging
The firmware uses `defmt` for efficient real-time logging over RTT (Real-Time Transfer).

```bash
# View logs while running
cargo run --release
# defmt output appears in the terminal via probe-rs
```

### Pin Configuration

| Signal | Pico 2 Pin | Direction | GPU Signal |
|--------|-----------|-----------|------------|
| SPI SCK | GP2 (SPI0) | Out | SCK |
| SPI MOSI | GP3 (SPI0) | Out | MOSI |
| SPI MISO | GP4 (SPI0) | In | MISO |
| SPI CS | GP5 (GPIO) | Out | CS (manual) |
| CMD_FULL | GP6 (GPIO) | In | CMD_FULL |
| CMD_EMPTY | GP7 (GPIO) | In | CMD_EMPTY |
| VSYNC | GP8 (GPIO) | In | VSYNC |
| Error LED | GP25 (onboard) | Out | — |

*Note: Pin assignments are preliminary and may change during implementation. The onboard LED (GP25) is used for error indication.*

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        RP2350                                │
│                                                              │
│  Core 0                          Core 1                      │
│  ┌────────────────┐              ┌────────────────────────┐  │
│  │ Scene Graph    │   Command    │ Render Command         │  │
│  │ USB Keyboard   │───Queue────▶│ Executor               │  │
│  │ Demo Selection │  (SPSC)     │   ├─ Transform          │  │
│  │ Animation      │              │   ├─ Lighting           │  │
│  └────────────────┘              │   └─ GPU Submit (SPI)   │  │
│                                  └─────────┬──────────────┘  │
│                                            │ SPI + GPIO      │
└────────────────────────────────────────────┼─────────────────┘
                                             │
                                    ┌────────▼────────┐
                                    │   SPI GPU       │
                                    │   (ICEpi Zero)  │
                                    │   ECP5 FPGA     │
                                    └────────┬────────┘
                                             │ DVI/HDMI
                                    ┌────────▼────────┐
                                    │    Display      │
                                    │  640×480@60Hz   │
                                    └─────────────────┘
```

---

## Key Files

| File | Purpose |
|------|---------|
| `firmware/src/main.rs` | Entry point, Core 0 main loop |
| `firmware/src/core1.rs` | Core 1 entry, render loop |
| `firmware/src/gpu/mod.rs` | GPU driver (SPI + GPIO) |
| `firmware/src/gpu/registers.rs` | GPU register constants |
| `firmware/src/render/commands.rs` | Render command execution |
| `firmware/src/render/transform.rs` | MVP transform pipeline |
| `firmware/src/render/lighting.rs` | Gouraud lighting |
| `firmware/src/scene/demos.rs` | Demo definitions |
| `firmware/src/scene/input.rs` | USB keyboard handling |
| `firmware/src/assets/teapot.rs` | Utah Teapot mesh data |
