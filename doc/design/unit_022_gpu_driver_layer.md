# UNIT-022: GPU Driver Layer

## Purpose

SPI transaction handling and flow control

## Implements Requirements

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
- REQ-121 (Async SPI Transmission)
- REQ-123 (Double-Buffered Rendering)
- REQ-132 (Ordered Dithering)
- REQ-133 (Color Grading LUT)
- REQ-134 (Extended Precision Fragment Processing)

## Interfaces

### Provides

- INT-020 (GPU Driver API)

### Consumes

- INT-001 (SPI Mode 0 Protocol)
- INT-010 (GPU Register Map)
- INT-012 (SPI Transaction Format)
- INT-013 (GPIO Status Signals)

### Internal Interfaces

- **UNIT-021 (Core 1 Render Executor)**: `GpuHandle` is owned by Core 1 and called exclusively from `render::commands::execute()`.
- **UNIT-023 (Transformation Pipeline)**: Uses constants from `gpu::registers` (SCREEN_WIDTH, SCREEN_HEIGHT) for viewport mapping.

## Design Description

### Inputs

- **`gpu_init()` parameters**: `SpiBus` (SPI0 peripheral), `CsPin` (GPIO5), `CmdFullPin` (GPIO6), `CmdEmptyPin` (GPIO7), `VsyncPin` (GPIO8).
- **`write()` parameters**: `addr: u8` (7-bit register address), `data: u64` (64-bit register value).
- **`read()` parameters**: `addr: u8` (7-bit register address with bit 7 set for read).
- **`upload_memory()` parameters**: `gpu_addr: u32` (target SRAM address), `data: &[u32]` (word array to upload).
- **`submit_triangle()` parameters**: Three `&GpuVertex` references and a `textured: bool` flag.
- **`gpu_set_dither_mode()` parameters**: `enabled: bool` -- enable or disable ordered dithering.
- **`gpu_set_color_grade_enable()` parameters**: `enabled: bool` -- enable or disable color grading LUT at scanout.
- **`gpu_upload_color_lut()` parameters**: `red: &[u32; 32]` (Red LUT, 32 RGB888 entries), `green: &[u32; 64]` (Green LUT, 64 RGB888 entries), `blue: &[u32; 32]` (Blue LUT, 32 RGB888 entries).

### Outputs

- **`gpu_init()` return**: `Result<GpuHandle, GpuError>` -- `GpuNotDetected` if ID register mismatch, `Ok(handle)` on success.
- **SPI bus writes**: 9-byte transactions (1 address byte + 8 data bytes, MSB-first) via SPI0 at 25 MHz.
- **SPI bus reads**: 9-byte full-duplex transfer (address byte with bit 7 set, 8 response bytes).
- **GPIO side effects**: CS pin (GPIO5) toggled low/high around each SPI transaction. VSYNC pin polled for edge detection. CMD_FULL pin polled for flow control.
- **`gpu_set_dither_mode()` return**: None. Writes DITHER_MODE register (0x32) with 0x01 (enabled) or 0x00 (disabled).
- **`gpu_set_color_grade_enable()` return**: None. Writes COLOR_GRADE_CTRL register (0x44) with 0x01 (enabled) or 0x00 (disabled).
- **`gpu_upload_color_lut()` return**: None. Performs 260 SPI register writes (1 reset + 128 addr/data pairs + 1 swap) to upload all three LUT channels and activate at next vblank.

### Internal State

- **`GpuHandle`** struct fields:
  - `spi: SpiBus` -- SPI0 peripheral instance.
  - `cs: CsPin` -- manual chip-select (GPIO5, active low).
  - `cmd_full: CmdFullPin` -- GPU FIFO almost-full status (GPIO6, active high).
  - `cmd_empty: CmdEmptyPin` -- GPU FIFO empty status (GPIO7, active high).
  - `vsync: VsyncPin` -- vertical sync signal (GPIO8, active high).
  - `draw_fb: u32` -- current draw framebuffer SRAM address (swapped on buffer swap).
  - `display_fb: u32` -- current display framebuffer SRAM address (swapped on buffer swap).

### Algorithm / Behavior

1. **Initialization** (`gpu_init()`):
   a. Construct `GpuHandle` with `draw_fb = FB_A_ADDR` (0x000000) and `display_fb = FB_B_ADDR` (0x12C000).
   b. Read the ID register (0x7F); verify device ID matches `EXPECTED_DEVICE_ID` (0x6702). Return `GpuNotDetected` on mismatch.
   c. Write initial framebuffer addresses to FB_DRAW (0x40) and FB_DISPLAY (0x41).
2. **Register write** (`write()`):
   a. **Flow control**: Spin-wait while `cmd_full` GPIO is high (GPU FIFO full).
   b. Pack 9-byte buffer: `[addr & 0x7F, data[63:56], data[55:48], ..., data[7:0]]`.
   c. Assert CS low, write 9 bytes via SPI, deassert CS high.
3. **Register read** (`read()`):
   a. Pack 9-byte TX buffer: `[0x80 | (addr & 0x7F), 0, 0, ..., 0]`.
   b. Assert CS low, full-duplex transfer (TX and RX), deassert CS high.
   c. Reconstruct 64-bit value from RX bytes 1..8 (MSB-first).
4. **Vsync wait** (`wait_vsync()`): Wait for VSYNC pin low (ensure not mid-pulse), then wait for rising edge (pin goes high).
5. **Buffer swap** (`swap_buffers()`): Swap `draw_fb` and `display_fb` values, write both to their respective GPU registers.
6. **Memory upload** (`upload_memory()`): Write base address to MEM_ADDR (0x70), then write each data word to MEM_DATA (0x71) which auto-increments the address.
7. **Triangle submit** (`submit_triangle()`): For each of 3 vertices, write COLOR register, optionally UV0 register (if textured), then VERTEX register (third VERTEX write triggers GPU rasterization).
8. **Dither mode** (`gpu_set_dither_mode(enabled)`): Write DITHER_MODE register (0x32) with 0x01 if enabled, 0x00 if disabled. Dithering smooths 10.8-to-RGB565 quantization using a blue noise pattern; enabled by default after GPU init.
9. **Color grade enable** (`gpu_set_color_grade_enable(enabled)`): Write COLOR_GRADE_CTRL register (0x44) with 0x01 if enabled, 0x00 if disabled. The LUT must be uploaded before enabling (undefined output with uninitialized LUT).
10. **Color LUT upload** (`gpu_upload_color_lut(red, green, blue)`):
    a. Write COLOR_GRADE_CTRL with bit 2 set (RESET_ADDR) to reset the LUT address pointer.
    b. For each of the 32 Red LUT entries: write COLOR_GRADE_LUT_ADDR (0x45) with `(0b00 << 6) | index`, then write COLOR_GRADE_LUT_DATA (0x46) with `red[index] & 0xFFFFFF`.
    c. For each of the 64 Green LUT entries: write COLOR_GRADE_LUT_ADDR with `(0b01 << 6) | index`, then write COLOR_GRADE_LUT_DATA with `green[index] & 0xFFFFFF`.
    d. For each of the 32 Blue LUT entries: write COLOR_GRADE_LUT_ADDR with `(0b10 << 6) | index`, then write COLOR_GRADE_LUT_DATA with `blue[index] & 0xFFFFFF`.
    e. Write COLOR_GRADE_CTRL with bit 1 set (SWAP_BANKS) to activate the new LUT data at the next vblank.

## Implementation

- `host_app/src/gpu/mod.rs`: Main implementation

## Verification

- **Init test**: Verify `gpu_init()` returns `GpuNotDetected` when ID register returns wrong value, and `Ok` with correct framebuffer addresses when ID matches.
- **Write format test**: Verify 9-byte SPI transaction format: address byte has bit 7 clear, data bytes are MSB-first.
- **Read format test**: Verify 9-byte SPI transaction format: address byte has bit 7 set, response reconstructed from bytes 1..8.
- **Flow control test**: Verify `write()` spin-waits when CMD_FULL is asserted and proceeds when deasserted.
- **Vsync test**: Verify `wait_vsync()` detects a low-to-high transition on the VSYNC pin.
- **Buffer swap test**: Verify `swap_buffers()` exchanges draw/display addresses and writes both registers.
- **Triangle submit test**: Verify `submit_triangle()` writes COLOR + VERTEX (non-textured) or COLOR + UV0 + VERTEX (textured) for each of 3 vertices.
- **Dither mode test**: Verify `gpu_set_dither_mode(true)` writes 0x01 to DITHER_MODE (0x32), and `gpu_set_dither_mode(false)` writes 0x00.
- **Color grade enable test**: Verify `gpu_set_color_grade_enable(true)` writes 0x01 to COLOR_GRADE_CTRL (0x44), and `gpu_set_color_grade_enable(false)` writes 0x00.
- **Color LUT upload test**: Verify `gpu_upload_color_lut()` performs the correct sequence: reset addr, 32 red entries (addr + data writes), 64 green entries, 32 blue entries, then swap banks. Total: 260 SPI transactions.

## Design Notes

Migrated from speckit module specification.

API functions `gpu_set_dither_mode()`, `gpu_set_color_grade_enable()`, and `gpu_upload_color_lut()` were added per INT-020 and are now reflected in the Inputs, Outputs, and Algorithm/Behavior sections above. These wrap register writes to DITHER_MODE (0x32) and COLOR_GRADE_CTRL/LUT_ADDR/LUT_DATA (0x44-0x46). Note: the Rust implementation (gpu/mod.rs) does not yet include these functions and needs to be updated to match this design.
