# Research: RP2350 Host Software

**Feature Branch**: `002-rp2350-host-software`
**Date**: 2026-01-30

---

## Decision 1: Language and HAL

**Decision**: Rust with `rp235x-hal` (bare-metal, no Embassy)

**Rationale**: The user specified Rust targeting Cortex M33 cores. `rp235x-hal` is the community-standard HAL for RP2350, based on the mature `rp2040-hal`. It provides direct access to SPI, DMA, GPIO, and multicore primitives. A bare-metal approach (vs Embassy async) gives deterministic timing essential for 30+ FPS real-time rendering on the render core.

**Alternatives considered**:
- Embassy-rp: Good for async I/O but cooperative scheduling would block during vertex transform/lighting computations. Adds complexity to dual-core setup.
- RTIC v2: Supports Cortex-M33 but does not natively support multi-core. Would require separate instances per core.

---

## Decision 2: Target and Toolchain

**Decision**: `thumbv8m.main-none-eabihf` target (Cortex-M33 with hardware FPU)

**Rationale**: The RP2350's Cortex-M33 cores have a single-precision hardware FPU and DSP extensions. The `eabihf` target enables hardware float calling conventions, critical for matrix math and lighting performance. The user explicitly chose Cortex M33 over the RP2350's RISC-V cores for this reason.

**Build tools**:
- `probe-rs` (v0.24+) for flash/debug via SWD
- `flip-link` for stack overflow protection
- `defmt` + `defmt-rtt` for efficient logging
- `elf2uf2-rs` as fallback for UF2 drag-and-drop flashing

---

## Decision 3: Dual-Core Communication

**Decision**: `heapless::spsc::Queue` for the inter-core render command queue, with SIO FIFO doorbell signaling

**Rationale**: The RP2350 provides hardware SIO FIFOs (8-deep, 32-bit) for inter-core signaling, but they're too small for render commands. `heapless::spsc::Queue` is a proven single-producer single-consumer lock-free queue that requires no allocator and no mutexes. The SIO FIFO can signal "new commands available" to avoid busy-polling on Core 1.

**Alternatives considered**:
- `bbqueue`: Byte-oriented SPSC queue, good for variable-size messages but more complex API.
- Raw shared memory with atomics: Maximum flexibility but requires manual ring buffer implementation.
- SIO FIFO only: Too small (8×32-bit) for render command payloads.

**Memory ordering**: Cortex-M33 requires `Release`/`Acquire` ordering on atomic operations for multi-core correctness. `heapless` handles this internally.

---

## Decision 4: USB Host Keyboard Input

**Decision**: TinyUSB via FFI wrapper (primary), with option to defer to later milestone

**Rationale**: The RP2350 needs to act as USB Host (not device) to connect a keyboard. Pure Rust USB host support on RP2350 is immature. TinyUSB (C library) has proven USB host HID support on RP2350 and is used by the official Pico SDK. A thin Rust FFI wrapper is the most reliable approach.

**Alternatives considered**:
- `embassy-usb` host: Experimental for RP2350, not production-ready.
- `usb-host` crate: Early-stage, limited RP2350 support.
- PIO-based USB host: Community experiments exist but not mature in Rust.

**Risk note**: USB keyboard is P4 priority in the spec. If TinyUSB FFI proves complex, it can be deferred while the rendering pipeline is developed using hardcoded demo selection.

---

## Decision 5: SPI Configuration

**Decision**: `rp235x-hal::spi` at 25 MHz, Mode 0, MSB first, with manual CS via GPIO

**Rationale**: Matches the GPU's SPI protocol spec (Mode 0, max 40 MHz). 25 MHz is a conservative starting point that works reliably on typical PCB/wire connections. Manual CS control (GPIO pin, not hardware CS) is required because each GPU command is exactly 9 bytes (72 bits) and CS must frame each transaction precisely.

**Transaction format**: 9 bytes per GPU register write, packed as:
```
byte[0] = addr & 0x7F (write) or 0x80 | addr (read)
byte[1..9] = 64-bit data, MSB first
```

---

## Decision 6: DMA Strategy

**Decision**: Two-phase DMA approach per spec clarification

**Phase 1 (MUST)**: DMA for flash-to-RAM data pre-fetch
- Use DMA to asynchronously load mesh/texture data from flash to SRAM while the render core processes previous data.
- RP2350 DMA supports memory-to-memory transfers.

**Phase 2 (SHOULD, stretch goal)**: DMA for SPI GPU command streaming
- Prepare a buffer of packed 9-byte SPI commands.
- DMA the buffer to SPI TX while CPU prepares the next batch.
- **Challenge**: CS must be toggled between each 9-byte transaction. Options:
  a. Use DMA completion interrupt to toggle CS between commands
  b. Investigate if GPU allows multiple commands in a single CS-low window (protocol spec says "CS rising edge latches command", suggesting each command needs its own CS cycle)
  c. Use PIO to manage CS automatically based on byte count

**Rationale**: Async flash reads are straightforward and provide immediate benefit. Async SPI transmission has the CS-toggle challenge that may require PIO or interrupt-based CS management.

---

## Decision 7: Math Libraries

**Decision**: `glam` (no_std, libm feature) for matrix/vector math, `fixed` crate for GPU register formats

**Rationale**:
- `glam` provides `Mat4`, `Vec3`, `Vec4`, `Quat` — all needed for model-view-projection transforms and lighting. Optimized for f32, which maps directly to the M33's hardware FPU. Lightweight with no allocations.
- `fixed` crate provides fixed-point types for GPU register packing: 12.4 signed fixed-point for vertex X/Y, 1.15 signed fixed-point for UV/Q, 25-bit unsigned for Z depth.
- The `libm` feature on glam provides software `sin`/`cos`/`sqrt` that the M33 FPU lacks (it only has add/mul/div/sqrt for single precision; trig is software).

**Alternatives considered**:
- `nalgebra`: Full linear algebra, overkill for this use case and larger code size.
- `micromath`: Lighter than glam but less feature-complete.

---

## Decision 8: Testing Strategy

**Decision**: `cargo test` for host-side unit tests, on-target hardware tests for integration

**Approach**:
- **Unit tests** (run on host): Math functions (matrix transforms, lighting, fixed-point conversion), render command serialization, GPU register packing.
- **On-target tests**: SPI communication, DMA transfers, GPU interaction, dual-core queue operation.
- **defmt logging**: Real-time performance metrics (FPS, CPU utilization) via RTT during development.
- **Reference comparison**: Pre-computed expected vertex outputs for known inputs, compared against transform pipeline results.

---

## Decision 9: Project Source Structure

**Decision**: Single Cargo workspace with the firmware crate under `firmware/`

```
firmware/
├── Cargo.toml              # Workspace root
├── .cargo/
│   └── config.toml         # Target, runner, rustflags
├── memory.x                # Linker memory layout
├── src/
│   ├── main.rs             # Entry point, Core 0 main loop
│   ├── core1.rs            # Core 1 entry, render loop
│   ├── gpu/
│   │   ├── mod.rs           # GPU driver (SPI + GPIO)
│   │   ├── registers.rs     # Register address constants and types
│   │   └── vertex.rs        # GpuVertex packing (fixed-point conversion)
│   ├── render/
│   │   ├── mod.rs           # Render command queue and types
│   │   ├── transform.rs     # Matrix transforms, viewport mapping
│   │   ├── lighting.rs      # Gouraud lighting calculation
│   │   └── commands.rs      # Command execution (mesh render, clear, etc.)
│   ├── scene/
│   │   ├── mod.rs           # Scene graph management
│   │   ├── demos.rs         # Demo definitions (triangle, teapot)
│   │   └── input.rs         # USB keyboard input handling
│   ├── math/
│   │   └── fixed.rs         # Fixed-point conversion helpers
│   └── assets/
│       ├── teapot.rs        # Utah Teapot mesh data (const)
│       └── textures.rs      # Texture data (const)
└── build.rs                # (optional) asset processing
```

**Rationale**: Matches the existing `firmware/` directory in the repo. Single crate keeps things simple. Module organization follows the dual-core architecture: `scene/` runs on Core 0, `render/` + `gpu/` runs on Core 1.

---

## Crate Summary

| Purpose | Crate | Version | Maturity |
|---------|-------|---------|----------|
| HAL | `rp235x-hal` | ~0.2.x | Good |
| PAC | `rp235x-pac` | ~0.2.x | Stable |
| BSP | `rp-pico2` | ~0.2.x | Good |
| Runtime | `cortex-m-rt` | 0.7.x | Mature |
| Cortex-M | `cortex-m` | 0.7.x | Mature |
| Lock-free queue | `heapless` | 0.8.x | Mature |
| USB Host | TinyUSB via FFI | C lib | Mature |
| Logging | `defmt` + `defmt-rtt` | 0.3.x | Mature |
| Panic handler | `panic-probe` | 0.3.x | Mature |
| Matrix math | `glam` | 0.29.x | Mature |
| Fixed-point | `fixed` | 1.28.x | Mature |
| Flash tool | `probe-rs` | 0.24+ | Mature |
| Linker | `flip-link` | 0.1.x | Mature |
| Critical section | `critical-section` | 1.x | Mature |

---

## Key Risks

1. **USB Host in Rust**: Weakest link in the crate ecosystem. TinyUSB FFI is the fallback. P4 priority allows deferral.
2. **DMA + SPI + CS control**: Each 9-byte GPU command needs its own CS cycle. DMA streaming requires interrupt-based or PIO-based CS management.
3. **Triangle strip registers**: FR-008 requires GPU register map extension (VERTEX_NODRAW register). This is a GPU-side dependency.
4. **RP2350 SRAM budget**: 520 KB total. Must fit: firmware stack (2×4KB), render command queue (~8-16KB), frame working buffers, mesh patch transform buffers. Teapot mesh data and textures live in flash.
5. **Fixed-point precision**: 1.15 format for UV/Q has limited range (-1.0 to +0.99997). Large or distant textures may show precision artifacts.
