# UNIT-022: GPU Driver Layer

## Purpose

Platform-agnostic GPU register protocol and flow control, generic over SPI transport

## Parent Requirement Area

- Area 7: Vertex Transformation / Area 8: Scene Graph/ECS (per proposed change: UNIT-022 serves both areas)

## Implements Requirements

- REQ-008.01 (Scene Management) — Area 8: Scene Graph/ECS
- REQ-008.02 (Render Pipeline Execution) — Area 8: Scene Graph/ECS
- REQ-013.01 (GPU Communication Protocol) — Area 1: GPU SPI Controller
- REQ-007.02 (Render Mesh Patch) — Area 7: Vertex Transformation
- REQ-013.02 (Upload Texture) — Area 1: GPU SPI Controller
- REQ-013.03 (VSync Synchronization) — Area 6: Screen Scan Out
- REQ-005.08 (Clear Framebuffer) — Area 5: Blend/Frame Buffer Store
- REQ-001.06 (GPU Flow Control) — Area 1: GPU SPI Controller
- REQ-005.09 (Double-Buffered Rendering) — Area 5: Blend/Frame Buffer Store
- REQ-005.10 (Ordered Dithering) — Area 5: Blend/Frame Buffer Store
- REQ-006.03 (Color Grading LUT) — Area 6: Screen Scan Out
- REQ-004.02 (Extended Precision Fragment Processing) — Area 4: Fragment Processor/Color Combiner

Note: REQ-100 (Host Firmware Architecture), REQ-110 (GPU Initialization), and REQ-121 (Async SPI Transmission) are retired; their references have been removed.

## Interfaces

### Provides

- INT-020 (GPU Driver API)

### Consumes

- INT-010 (GPU Register Map)
- INT-012 (SPI Transaction Format)
- INT-040 (Host Platform HAL)
- INT-001 (SPI Mode 0 Protocol)
- INT-013 (GPIO Status Signals)

### Internal Interfaces

- **UNIT-021 (Core 1 Render Executor)**: On RP2350, `GpuDriver` is owned by Core 1 and called from `render::commands::execute()`. On PC, it is owned by the main thread.
- **UNIT-023 (Transformation Pipeline)**: Uses constants from `gpu::registers` (SCREEN_WIDTH, SCREEN_HEIGHT) for viewport mapping.
- **UNIT-035 (PC SPI Driver)**: Provides the `Ft232hTransport` implementation of `SpiTransport` for the PC platform.

## Design Description

### Inputs

- **`GpuDriver::new(transport: S)`**: Generic constructor taking any `S: SpiTransport` implementation (INT-040).
- **`write()` parameters**: `addr: u8` (7-bit register address), `data: u64` (64-bit register value).
- **`read()` parameters**: `addr: u8` (7-bit register address with bit 7 set for read).
- **`upload_memory()` parameters**: `gpu_addr: u32` (target SRAM address), `data: &[u32]` (word array to upload).
- **`submit_triangle()` parameters**: Three `&GpuVertex` references and a `textured: bool` flag.
- **`gpu_set_render_mode()` parameters**: `gouraud: bool`, `z_test: bool`, `z_write: bool`, `color_write: bool` -- configure RENDER_MODE register (0x30) flags. When `color_write` is false, the GPU writes only to the Z-buffer (Z-prepass mode).
- **`gpu_set_z_range()` parameters**: `z_min: u16`, `z_max: u16` -- write Z_RANGE register (0x31) to restrict Z-test to a sub-range. Default: min=0, max=0xFFFF (full range).
- **`gpu_set_dither_mode()` parameters**: `enabled: bool` -- enable or disable ordered dithering.
- **`gpu_set_color_grade_enable()` parameters**: `enabled: bool` -- enable or disable color grading LUT at scanout.
- **`gpu_upload_color_lut()` parameters**: `red: &[u32; 32]` (Red LUT, 32 RGB888 entries), `green: &[u32; 64]` (Green LUT, 64 RGB888 entries), `blue: &[u32; 32]` (Blue LUT, 32 RGB888 entries).
- **`gpu_set_combiner_mode()` parameters**: `rgb_a: u8, rgb_b: u8, rgb_c: u8, rgb_d: u8, alpha_a: u8, alpha_b: u8, alpha_c: u8, alpha_d: u8` -- configure the color combiner equation `(A-B)*C+D` input selectors for RGB and Alpha channels. Each selector is a 4-bit value choosing from: 0=TEX_COLOR0, 1=TEX_COLOR1, 2=VER_COLOR0, 3=VER_COLOR1, 4=MAT_COLOR0, 5=MAT_COLOR1, 6=Z_COLOR, 7=ONE, 8=ZERO.
- **`gpu_set_material_color()` parameters**: `slot: u8` (0 or 1), `color: u32` (RGBA8888) -- write MAT_COLOR0 or MAT_COLOR1 register.

### Outputs

- **`GpuDriver::new()` return**: `Result<GpuDriver<S>, GpuError>` -- `GpuNotDetected` if ID register mismatch, `Ok(driver)` on success.
- **SPI transactions**: Delegated to the `SpiTransport` implementation. The driver builds 9-byte frames and calls `write_register()`/`read_register()` on the transport.
- **Flow control and GPIO side effects**: Handled by the `SpiTransport` implementation (transparent to the driver).
- **`gpu_set_dither_mode()` return**: None. Writes DITHER_MODE register (0x32) with 0x01 (enabled) or 0x00 (disabled).
- **`gpu_set_color_grade_enable()` return**: None. Writes COLOR_GRADE_CTRL register (0x44) with 0x01 (enabled) or 0x00 (disabled).
- **`gpu_upload_color_lut()` return**: None. Performs 260 SPI register writes (1 reset + 128 addr/data pairs + 1 swap) to upload all three LUT channels and activate at next vblank.
- **`gpu_set_combiner_mode()` return**: None. Writes COMBINER_RGB (0x33) and COMBINER_ALPHA (0x34) registers with packed input selectors.
- **`gpu_set_material_color()` return**: None. Writes MAT_COLOR0 (0x35) or MAT_COLOR1 (0x36) register.

### Internal State

- **`GpuDriver<S: SpiTransport>`** struct fields:
  - `spi: S` -- platform-specific SPI transport (implements `SpiTransport` from INT-040).
  - `draw_fb: u32` -- current draw framebuffer SRAM address (swapped on buffer swap).
  - `display_fb: u32` -- current display framebuffer SRAM address (swapped on buffer swap).

### Algorithm / Behavior

1. **Initialization** (`GpuDriver::new(spi)`):
   a. Construct `GpuDriver` with `draw_fb = FB_A_ADDR` (0x000000) and `display_fb = FB_B_ADDR` (0x12C000).
   b. Read the ID register (0x7F) via `spi.read_register(0x7F)`; verify device ID matches `EXPECTED_DEVICE_ID` (0x6702). Return `GpuNotDetected` on mismatch.
   c. Write initial framebuffer addresses to FB_DRAW (0x40) and FB_DISPLAY (0x41).
2. **Register write** (`write()`): Delegates to `self.spi.write_register(addr, data)`. Flow control is handled by the transport implementation.
3. **Register read** (`read()`): Delegates to `self.spi.read_register(addr)`.
4. **Vsync wait** (`wait_vsync()`): Delegates to the transport's flow control implementation.
5. **Buffer swap** (`swap_buffers()`): Swap `draw_fb` and `display_fb` values, write both to their respective GPU registers.
6. **Memory upload** (`upload_memory()`): Write base address to MEM_ADDR (0x70), then write each data word to MEM_DATA (0x71) which auto-increments the address.
7. **Triangle submit** (`submit_triangle()`): For each of 3 vertices, write COLOR register, optionally UV0 register (if textured), then VERTEX register (third VERTEX write triggers GPU rasterization).
8. **Render mode** (`gpu_set_render_mode(gouraud, z_test, z_write, color_write)`): Pack flags into a single byte (bit 0 = gouraud, bit 1 = textured (reserved, always 0 via this API), bit 2 = z_test, bit 3 = z_write, bit 4 = color_write) and write to RENDER_MODE register (0x30). Replaces the legacy TRI_MODE register.
9. **Z range** (`gpu_set_z_range(z_min, z_max)`): Write Z_RANGE register (0x31) with `{z_max[15:0], z_min[15:0]}` packed into the lower 32 bits. Default value after reset is 0x0000FFFF (min=0, max=0xFFFF, full range). Used to restrict Z-test to a depth sub-range for layered rendering or Z-prepass partitioning.
10. **Dither mode** (`gpu_set_dither_mode(enabled)`): Write DITHER_MODE register (0x32) with 0x01 if enabled, 0x00 if disabled. Dithering smooths 10.8-to-RGB565 quantization using a blue noise pattern; enabled by default after GPU init.
11. **Color grade enable** (`gpu_set_color_grade_enable(enabled)`): Write COLOR_GRADE_CTRL register (0x44) with 0x01 if enabled, 0x00 if disabled. The LUT must be uploaded before enabling (undefined output with uninitialized LUT).
12. **Color LUT upload** (`gpu_upload_color_lut(red, green, blue)`):
    a. Write COLOR_GRADE_CTRL with bit 2 set (RESET_ADDR) to reset the LUT address pointer.
    b. For each of the 32 Red LUT entries: write COLOR_GRADE_LUT_ADDR (0x45) with `(0b00 << 6) | index`, then write COLOR_GRADE_LUT_DATA (0x46) with `red[index] & 0xFFFFFF`.
    c. For each of the 64 Green LUT entries: write COLOR_GRADE_LUT_ADDR with `(0b01 << 6) | index`, then write COLOR_GRADE_LUT_DATA with `green[index] & 0xFFFFFF`.
    d. For each of the 32 Blue LUT entries: write COLOR_GRADE_LUT_ADDR with `(0b10 << 6) | index`, then write COLOR_GRADE_LUT_DATA with `blue[index] & 0xFFFFFF`.
    e. Write COLOR_GRADE_CTRL with bit 1 set (SWAP_BANKS) to activate the new LUT data at the next vblank.
13. **Kicked vertex submit** (`submit_vertex_kicked(vertex, kick, textured)`): Write COLOR, optionally COLOR1 (if dual vertex colors enabled), optionally UV0, then VERTEX_NOKICK (0x06), VERTEX_KICK_012 (0x07), or VERTEX_KICK_021 (0x08) based on kick parameter (0/1/2).
14. **Buffered register write** (`pack_write(buffer, offset, addr, data)`): Pack 9-byte SPI frame into SRAM buffer. Returns offset + 9.
15. **Combiner mode** (`gpu_set_combiner_mode(rgb_a, rgb_b, rgb_c, rgb_d, alpha_a, alpha_b, alpha_c, alpha_d)`): Pack RGB selectors into COMBINER_RGB register (0x33) as `{rgb_d[3:0], rgb_c[3:0], rgb_b[3:0], rgb_a[3:0]}` in the lower 16 bits, and write. Pack Alpha selectors into COMBINER_ALPHA register (0x34) similarly.
    Common presets:
    - **Modulate:** rgb = (TEX0, ZERO, VER0, ZERO) → `TEX0 * VER0`
    - **Decal:** rgb = (TEX0, ZERO, ONE, ZERO) → `TEX0`
    - **Add specular:** rgb = (TEX0, ZERO, VER0, VER1) → `TEX0 * VER0 + VER1`
16. **Material color** (`gpu_set_material_color(slot, color)`): Write MAT_COLOR0 (0x35) if slot=0, MAT_COLOR1 (0x36) if slot=1.

## Implementation

- `crates/pico-gs-core/src/gpu/mod.rs`: Platform-agnostic GPU driver (generic over `SpiTransport`)
- `crates/pico-gs-core/src/gpu/registers.rs`: Register map constants (includes `Z_RANGE = 0x31`, `RENDER_MODE = 0x30`, `RENDER_MODE_COLOR_WRITE = 1 << 4`, `COMBINER_RGB = 0x33`, `COMBINER_ALPHA = 0x34`, `MAT_COLOR0 = 0x35`, `MAT_COLOR1 = 0x36`)
- `crates/pico-gs-core/src/gpu/vertex.rs`: Vertex packing

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
- **Render mode test**: Verify `gpu_set_render_mode(true, true, true, true)` writes 0x1D to RENDER_MODE (0x30) (bits 0,2,3,4 set), and `gpu_set_render_mode(false, false, false, false)` writes 0x00. Verify `color_write=false` produces a value with bit 4 clear.
- **Z range test**: Verify `gpu_set_z_range(0, 0xFFFF)` writes 0x0000_FFFF_0000_0000 to Z_RANGE (0x31). Verify `gpu_set_z_range(0x100, 0xFF00)` writes the correct packed value.
- **Combiner mode test**: Verify `gpu_set_combiner_mode()` writes correct packed selectors to COMBINER_RGB (0x33) and COMBINER_ALPHA (0x34). Verify modulate preset produces expected register values.
- **Material color test**: Verify `gpu_set_material_color(0, 0xFF0000FF)` writes to MAT_COLOR0 (0x35), and `gpu_set_material_color(1, 0x00FF00FF)` writes to MAT_COLOR1 (0x36).

## Design Notes

Migrated from speckit module specification.

API functions `gpu_set_dither_mode()`, `gpu_set_color_grade_enable()`, and `gpu_upload_color_lut()` were added per INT-020 and are now reflected in the Inputs, Outputs, and Algorithm/Behavior sections above. These wrap register writes to DITHER_MODE (0x32) and COLOR_GRADE_CTRL/LUT_ADDR/LUT_DATA (0x44-0x46).

**Note:** Register-based LUT upload has been superseded. See DD-014 and INT-010 for the SRAM-based auto-load approach.

**Dual-texture + color combiner update:** Added `gpu_set_combiner_mode()` and `gpu_set_material_color()` API functions.
Texture slot range reduced from 0-3 to 0-1 (2 texture units per pass).
The `submit_triangle()` function no longer writes UV2_UV3; only UV0_UV1 is written when textured.
A second vertex color (COLOR1) register write is added to the vertex submission sequence when the color combiner uses VER_COLOR1.
Register constants in `registers.rs` updated: TEX2/TEX3 constants removed; COMBINER_RGB, COMBINER_ALPHA, MAT_COLOR0, MAT_COLOR1 added.

