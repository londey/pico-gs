# INT-020: GPU Driver API

## Type

Internal

## Parties

- **Provider:** UNIT-022 (GPU Driver Layer)
- **Consumer:** UNIT-021 (Core 1 Render Executor)

## Referenced By

- REQ-100 (Unknown)
- REQ-101 (Unknown)
- REQ-102 (Unknown)
- REQ-105 (Unknown)
- REQ-110 (GPU Initialization)
- REQ-115 (Render Mesh Patch)
- REQ-116 (Upload Texture)
- REQ-117 (VSync Synchronization)
- REQ-118 (Clear Framebuffer)
- REQ-119 (GPU Flow Control)

## Specification


**Version**: 1.0
**Date**: 2026-01-30
**Implements**: FR-001, FR-009, FR-012, FR-016

---

## Overview

The GPU driver provides the low-level interface between the RP2350 host and the SPI GPU. It encapsulates SPI transaction formatting, flow control via GPIO, and buffer management. This contract defines the public API that the render core uses to communicate with the GPU.

---

## Initialization

### `gpu_init() → Result<GpuHandle, GpuError>`

Initialize SPI peripheral and GPIO pins, verify GPU presence.

**Preconditions**:
- SPI peripheral and GPIO pins are available and not in use
- GPU hardware is powered and connected

**Postconditions**:
- SPI configured: Mode 0, MSB first, 25 MHz clock
- GPIO inputs configured: CMD_FULL, CMD_EMPTY, VSYNC
- GPU device ID verified (expect 0x6702 for v2.0)

**Errors**:
- `GpuNotDetected`: ID register read returned unexpected value
- `SpiBusError`: SPI transaction failed

---

## Register Access

### `gpu_write(handle: &GpuHandle, addr: u8, data: u64)`

Write a 64-bit value to a GPU register. Blocks until CMD_FULL is deasserted.

**Preconditions**:
- `addr` is a valid write register (0x00-0x7F, excluding read-only)

**Flow control**:
1. Poll CMD_FULL GPIO
2. If asserted, spin-wait until deasserted
3. Assert CS low
4. Transmit 72 bits: [0 | addr(7) | data(64)] MSB first
5. Deassert CS high

**SPI Transaction Format** (9 bytes):
```
byte[0] = addr & 0x7F        (bit 7 = 0 for write)
byte[1] = (data >> 56) & 0xFF
byte[2] = (data >> 48) & 0xFF
...
byte[8] = data & 0xFF
```

### `gpu_read(handle: &GpuHandle, addr: u8) → u64`

Read a 64-bit value from a GPU register.

**Preconditions**:
- `addr` is a readable register (STATUS: 0x7E, ID: 0x7F)
- For consistent reads, CMD_EMPTY should be asserted

**Transaction**:
1. Assert CS low
2. Transmit 8 bits: [1 | addr(7)]
3. Clock in 64 bits from MISO
4. Deassert CS high

---

## Bulk Memory Upload

### `gpu_upload_memory(handle: &GpuHandle, gpu_addr: u32, data: &[u32])`

Upload a block of 32-bit words to GPU SRAM via MEM_ADDR/MEM_DATA registers.

**Sequence**:
1. `gpu_write(MEM_ADDR, gpu_addr)`
2. For each word in `data`: `gpu_write(MEM_DATA, word)`
3. MEM_ADDR auto-increments by 4 after each MEM_DATA write

**Performance**: ~3 MB/s at 25 MHz SPI (each 32-bit word requires a full 72-bit transaction).

**Use cases**: Texture upload, LUT upload

---

## Frame Synchronization

### `gpu_wait_vsync(handle: &GpuHandle)`

Block until the GPU asserts the VSYNC GPIO signal.

**Implementation**:
1. Wait for VSYNC GPIO rising edge
2. Return immediately after edge detected

**Timing**: VSYNC pulses every 16.67 ms (60 Hz), pulse width ~400 ns

### `gpu_swap_buffers(handle: &GpuHandle, draw: u32, display: u32)`

Configure which framebuffer is drawn to and which is displayed.

**Sequence**:
1. `gpu_write(FB_DISPLAY, display)` — takes effect at next VSYNC
2. `gpu_write(FB_DRAW, draw)`

---

## Flow Control

### `gpu_is_fifo_full(handle: &GpuHandle) → bool`

Returns true if the GPU's command FIFO is almost full (≤2 slots free).

**Implementation**: Read CMD_FULL GPIO pin state.

### `gpu_is_fifo_empty(handle: &GpuHandle) → bool`

Returns true if the GPU's command FIFO is completely empty.

**Implementation**: Read CMD_EMPTY GPIO pin state.

---

## Triangle Submission

### `gpu_submit_triangle(handle: &GpuHandle, v0: &GpuVertex, v1: &GpuVertex, v2: &GpuVertex)`

Submit a single triangle to the GPU by writing vertex state registers.

**Sequence for Gouraud-shaded, textured triangle**:
```
gpu_write(COLOR, v0.color_packed)
gpu_write(UV0,   v0.uv_packed)
gpu_write(VERTEX, v0.position_packed)  // vertex_count → 1

gpu_write(COLOR, v1.color_packed)
gpu_write(UV0,   v1.uv_packed)
gpu_write(VERTEX, v1.position_packed)  // vertex_count → 2

gpu_write(COLOR, v2.color_packed)
gpu_write(UV0,   v2.uv_packed)
gpu_write(VERTEX, v2.position_packed)  // vertex_count → 3, triggers rasterization
```

**Register writes per triangle**: 9 (3 vertices × 3 registers each)

### Triangle Strip Submission

For efficient mesh rendering, triangles are submitted as strips with strip restart.

**Requires GPU support**: Separate registers for "push vertex without draw" and "push vertex with draw" (see Dependencies in spec). This is a GPU register map extension not yet in the v2.0 spec.

**Proposed strip protocol**:
```
VERTEX_NODRAW (0x06?): Push vertex to strip, advance counter, no triangle emitted
VERTEX_DRAW (0x05):    Push vertex to strip, advance counter, emit triangle if ≥3 vertices

Strip restart: Write to VERTEX_NODRAW resets strip
```

---

## GpuVertex (packed format)

Pre-packed vertex data ready for GPU register writes.

| Field | Format | GPU Register |
|-------|--------|-------------|
| color_packed | u64: [31:24]=A, [23:16]=B, [15:8]=G, [7:0]=R | COLOR (0x00) |
| uv_packed | u64: [47:32]=Q(1.15), [31:16]=VQ(1.15), [15:0]=UQ(1.15) | UV0 (0x01) |
| position_packed | u64: [56:32]=Z(25), [31:16]=Y(12.4), [15:0]=X(12.4) | VERTEX (0x05) |

---

## Error Model

| Error | Cause | Recovery |
|-------|-------|----------|
| GpuNotDetected | ID mismatch on init | Halt with error indicator |
| SpiBusError | SPI peripheral failure | Halt with error indicator |
| FifoOverflow | Write when full (should not happen with flow control) | N/A — prevented by flow control |


## Constraints

See specification details above.

## Notes

Migrated from speckit contract: specs/002-rp2350-host-software/contracts/gpu-driver.md
