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
- REQ-132 (Ordered Dithering)
- REQ-133 (Color Grading LUT)
- REQ-134 (Extended Precision Fragment Processing)

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

## Texture Upload

### `gpu_upload_texture(handle: &GpuHandle, slot: u8, width: u32, height: u32, format: TextureFormat, data: &[u8])`

Upload a single-level texture to GPU SRAM and configure texture unit registers.

**Sequence**:
1. Allocate GPU SRAM for texture (4K aligned)
2. Upload texture data via `gpu_upload_memory()`
3. Write TEXn_BASE register (texture address)
4. Write TEXn_FMT register (width_log2, height_log2, format, enable, mip_levels=1)

**Parameters**:
- `slot`: Texture unit index (0-3)
- `width`, `height`: Texture dimensions (power-of-2, 8-1024)
- `format`: TextureFormat::RGBA4444 or TextureFormat::BC1
- `data`: Texture pixel data (size must match format and dimensions)

**Example**:
```rust
gpu_upload_texture(&gpu, 0, 256, 256, TextureFormat::BC1, PLAYER_DATA);
```

---

### `gpu_upload_texture_with_mipmaps(handle: &GpuHandle, slot: u8, width: u32, height: u32, format: TextureFormat, mip_levels: u8, data: &[u8], mip_offsets: &[usize])`

Upload a texture with mipmap chain to GPU SRAM and configure texture unit registers.

**Sequence**:
1. Calculate total size (sum of all mipmap level sizes)
2. Allocate GPU SRAM for texture chain (4K aligned base address)
3. Upload all mipmap levels sequentially via `gpu_upload_memory()`
4. Write TEXn_BASE register (base level address)
5. Write TEXn_FMT register (width_log2, height_log2, format, enable, mip_levels)
6. Write TEXn_MIP_BIAS register (default: 0, no bias)

**Parameters**:
- `slot`: Texture unit index (0-3)
- `width`, `height`: Base level dimensions (power-of-2, 8-1024)
- `format`: TextureFormat::RGBA4444 or TextureFormat::BC1
- `mip_levels`: Number of mipmap levels (1-11)
- `data`: Complete mipmap chain data (all levels concatenated)
- `mip_offsets`: Byte offsets of each mipmap level within `data`

**Validation**:
- `mip_levels` must be in range [1, 11]
- `mip_levels` must be ≤ min(width_log2, height_log2) + 1
- `mip_offsets.len()` must equal `mip_levels`
- Total data size must match expected mipmap chain size

**Example**:
```rust
gpu_upload_texture_with_mipmaps(
    &gpu,
    0,  // slot
    PLAYER_WIDTH,
    PLAYER_HEIGHT,
    PLAYER_FORMAT,
    PLAYER_MIP_LEVELS,
    PLAYER_DATA,
    &PLAYER_MIP_OFFSETS
);
```

**Performance**: Same as single-level upload (~3 MB/s), but total size is ~33% larger with full mipmap chain.

---

## Dithering and Color Grading

### `gpu_set_dither_mode(handle: &GpuHandle, enabled: bool)`

Enable or disable ordered dithering before RGB565 framebuffer conversion.

**Sequence**:
1. `gpu_write(DITHER_MODE, if enabled { 0x01 } else { 0x00 })`

**Notes**:
- Dithering is enabled by default after GPU init
- Dithering smooths the 10.8→RGB565 quantization using a blue noise pattern
- Disable for pixel-perfect rendering or solid-color fills

### `gpu_set_color_grade_enable(handle: &GpuHandle, enabled: bool)`

Enable or disable the color grading LUT at display scanout.

**Sequence**:
1. `gpu_write(COLOR_GRADE_CTRL, if enabled { 0x01 } else { 0x00 })`

**Notes**:
- When disabled, framebuffer pixels pass directly to DVI encoder with standard RGB565→RGB888 expansion
- LUT must be uploaded before enabling (undefined output with uninitialized LUT)

### `gpu_upload_color_lut(handle: &GpuHandle, red: &[u16; 32], green: &[u16; 64], blue: &[u16; 32])`

Upload all 3 color grading LUTs and activate at next vblank.

**Sequence**:
1. Write COLOR_GRADE_CTRL[2] (RESET_ADDR) to reset LUT address pointer
2. For each Red LUT entry (0-31):
   - `gpu_write(COLOR_GRADE_LUT_ADDR, (0b00 << 6) | index)`
   - `gpu_write(COLOR_GRADE_LUT_DATA, red[index] & 0x7FFF)`
3. For each Green LUT entry (0-63):
   - `gpu_write(COLOR_GRADE_LUT_ADDR, (0b01 << 6) | index)`
   - `gpu_write(COLOR_GRADE_LUT_DATA, green[index] & 0x7FFF)`
4. For each Blue LUT entry (0-31):
   - `gpu_write(COLOR_GRADE_LUT_ADDR, (0b10 << 6) | index)`
   - `gpu_write(COLOR_GRADE_LUT_DATA, blue[index] & 0x7FFF)`
5. Write COLOR_GRADE_CTRL[1] (SWAP_BANKS) to activate at next vblank

**Parameters**:
- `red`: 32 entries, each R5G5B5 (15-bit) packed in low bits of u16
- `green`: 64 entries, each R5G5B5 (15-bit) packed in low bits of u16
- `blue`: 32 entries, each R5G5B5 (15-bit) packed in low bits of u16

**Performance**: 128 entries × 2 register writes each = 256 SPI transactions ≈ 737 µs at 25 MHz

**Example** (identity LUT — no color change):
```rust
let mut red = [0u16; 32];
let mut green = [0u16; 64];
let mut blue = [0u16; 32];

// Identity: each channel maps to itself
for i in 0..32 {
    red[i] = (i as u16) << 10;   // R input → R output only
    blue[i] = i as u16;           // B input → B output only
}
for i in 0..64 {
    green[i] = ((i >> 1) as u16) << 5;  // G input → G output only (6→5 bit)
}

gpu_upload_color_lut(&gpu, &red, &green, &blue);
```

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
