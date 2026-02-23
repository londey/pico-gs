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
- **`upload_memory()` parameters**: `gpu_addr: u32` (target SDRAM dword address), `data: &[u64]` (dword array to upload).
- **`submit_triangle()` parameters**: Three `&GpuVertex` references and a `textured: bool` flag.
- **`gpu_set_render_mode()` parameters**: Full RENDER_MODE fields — `gouraud`, `z_test`, `z_write`, `color_write`, `cull_mode`, `alpha_blend`, `dither`, `z_compare`, `stipple_en`, `alpha_test_func`, `alpha_ref`.
- **`gpu_set_z_range()` parameters**: `z_min: u16`, `z_max: u16` — write Z_RANGE register (0x31).
- **`gpu_set_fb_config()` parameters**: `color_base: u16`, `z_base: u16`, `width_log2: u8`, `height_log2: u8` — write FB_CONFIG register (0x40).
- **`gpu_set_scissor()` parameters**: `x: u16`, `y: u16`, `width: u16`, `height: u16` — write FB_CONTROL register (0x43).
- **`gpu_mem_fill()` parameters**: `base: u16`, `value: u16`, `count: u32` — write MEM_FILL register (0x44) to initiate a hardware fill.
- **`gpu_set_combiner_mode()` parameters**: Two-cycle `(A-B)*C+D` equation selectors for RGB and Alpha, cycle 0 and cycle 1 — configure CC_MODE register (0x18).
- **`gpu_set_const_color()` parameters**: `const0: RGBA8`, `const1: RGBA8` — write CONST_COLOR register (0x19).

### Outputs

- **`GpuDriver::new()` return**: `Result<GpuDriver<S>, GpuError>` — `GpuNotDetected` if ID register mismatch, `Ok(driver)` on success.
- **SPI transactions**: Delegated to the `SpiTransport` implementation. The driver builds 9-byte frames and calls `write_register()`/`read_register()` on the transport.
- **Flow control and GPIO side effects**: Handled by the `SpiTransport` implementation (transparent to the driver).
- **`gpu_set_render_mode()` return**: None. Packs all RENDER_MODE fields into a 64-bit value and writes to RENDER_MODE (0x30).
- **`gpu_mem_fill()` return**: None. Writes MEM_FILL (0x44); GPU blocks pipeline until fill completes.
- **`gpu_set_combiner_mode()` return**: None. Writes CC_MODE (0x18) with packed cycle-0 and cycle-1 selectors.
- **`gpu_set_const_color()` return**: None. Writes CONST_COLOR (0x19) with CONST0 in [31:0] and CONST1 in [63:32].

### Internal State

- **`GpuDriver<S: SpiTransport>`** struct fields:
  - `spi: S` — platform-specific SPI transport (implements `SpiTransport` from INT-040).
  - `draw_fb: (u16, u16, u8, u8)` — current draw framebuffer (color_base, z_base, width_log2, height_log2).
  - `display_fb: (u16, u16, u8, u8)` — current display framebuffer fields.

### Algorithm / Behavior

1. **Initialization** (`GpuDriver::new(spi)`):
   a. Construct `GpuDriver` with draw and display framebuffer state set to FB_A defaults.
   b. Read the ID register (0x7F) via `spi.read_register(0x7F)`; verify device ID matches `EXPECTED_DEVICE_ID` (0x6702). Return `GpuNotDetected` on mismatch.
   c. Write initial FB_CONFIG (0x40) for the draw framebuffer.
   d. Write initial FB_DISPLAY (0x41) for the display framebuffer (blocks until vsync).

2. **Register write** (`write()`): Delegates to `self.spi.write_register(addr, data)`. Flow control is handled by the transport implementation.

3. **Register read** (`read()`): Delegates to `self.spi.read_register(addr)`.

4. **Vsync wait** (`wait_vsync()`): Delegates to the transport's flow control implementation.

5. **Buffer swap** (`swap_buffers()`): Swap draw and display framebuffer values; write FB_CONFIG (0x40) for the new draw target and FB_DISPLAY (0x41) for the new display target (blocks until vsync).

6. **Memory upload** (`upload_memory()`): Write base address to MEM_ADDR (0x70), then write each data dword to MEM_DATA (0x71) which auto-increments the address.

7. **Triangle submit** (`submit_triangle()`): For each of 3 vertices, write COLOR register (0x00), optionally UV0_UV1 register (0x01) if textured, then VERTEX_KICK_012 (0x07) for the third vertex or VERTEX_NOKICK (0x06) for the first two.

8. **Render mode** (`gpu_set_render_mode(...)`): Pack all RENDER_MODE fields per INT-010 bit layout and write to RENDER_MODE register (0x30).
   Dithering is now a field within RENDER_MODE (bit 10), not a separate register.

9. **Z range** (`gpu_set_z_range(z_min, z_max)`): Write Z_RANGE register (0x31) with `{z_max[15:0], z_min[15:0]}` packed into the lower 32 bits. Default value after reset is 0x0000FFFF (min=0, max=0xFFFF, full range).

10. **FB config** (`gpu_set_fb_config(color_base, z_base, width_log2, height_log2)`): Pack fields and write to FB_CONFIG register (0x40). Used to configure render-to-texture targets.

11. **Scissor** (`gpu_set_scissor(x, y, width, height)`): Write FB_CONTROL register (0x43) with scissor fields.

12. **Hardware fill** (`gpu_mem_fill(base, value, count)`): Write MEM_FILL register (0x44) with:
    - FILL_BASE[15:0] = base (512-byte-granularity address, same encoding as COLOR_BASE/Z_BASE)
    - FILL_VALUE[31:16] = value (16-bit constant, RGB565 for color buffer or Z16 for Z-buffer)
    - FILL_COUNT[51:32] = count (number of 16-bit words)
    GPU executes the fill synchronously within the command FIFO.

13. **Combiner mode** (`gpu_set_combiner_mode(...)`): Pack two-cycle `(A-B)*C+D` selectors into CC_MODE register (0x18).
    Cycle 0 fields occupy [31:0], cycle 1 fields occupy [63:32] per INT-010 CC_MODE layout.
    Common presets:
    - **Modulate (cycle 0, cycle 1 passthrough):** C0: A=TEX0, B=ZERO, C=SHADE0, D=ZERO → `TEX0 * SHADE0`
    - **Decal:** C0: A=TEX0, B=ZERO, C=ONE, D=ZERO → `TEX0`
    - **Specular add (two-stage):** C0: A=TEX0, B=ZERO, C=SHADE0, D=ZERO; C1: A=COMBINED, B=ZERO, C=ONE, D=SHADE1

14. **Constant colors** (`gpu_set_const_color(const0, const1)`): Write CONST_COLOR register (0x19) with CONST0 in bits [31:0] and CONST1 (also used as fog color) in bits [63:32].

15. **Color LUT prepare** (`gpu_prepare_lut(lut_addr, lut)`): Upload 384-byte LUT to SDRAM via MEM_ADDR/MEM_DATA. The LUT is auto-loaded during vblank when FB_DISPLAY.LUT_ADDR is set. See INT-020 for detailed sequence.

16. **Kicked vertex submit** (`submit_vertex_kicked(vertex, kick, textured)`): Write COLOR (0x00), optionally UV0_UV1 (0x01), then VERTEX_NOKICK (0x06), VERTEX_KICK_012 (0x07), or VERTEX_KICK_021 (0x08) based on `kick`.

17. **Buffered register write** (`pack_write(buffer, offset, addr, data)`): Pack 9-byte SPI frame into SRAM buffer. Returns offset + 9.

## Implementation

- `crates/pico-gs-core/src/gpu/mod.rs`: Platform-agnostic GPU driver (generic over `SpiTransport`)
- `crates/pico-gs-core/src/gpu/registers.rs`: Register map constants matching INT-010 (CC_MODE=0x18, CONST_COLOR=0x19, RENDER_MODE=0x30, Z_RANGE=0x31, STIPPLE_PATTERN=0x32, FB_CONFIG=0x40, FB_DISPLAY=0x41, FB_CONTROL=0x43, MEM_FILL=0x44, PERF_TIMESTAMP=0x50, MEM_ADDR=0x70, MEM_DATA=0x71, ID=0x7F)
- `crates/pico-gs-core/src/gpu/vertex.rs`: Vertex packing

## Verification

- **Init test**: Verify `gpu_init()` returns `GpuNotDetected` when ID register returns wrong value, and `Ok` with correct framebuffer setup when ID matches.
- **Write format test**: Verify 9-byte SPI transaction format: address byte has bit 7 clear, data bytes are MSB-first.
- **Read format test**: Verify 9-byte SPI transaction format: address byte has bit 7 set, response reconstructed from bytes 1..8.
- **Flow control test**: Verify `write()` spin-waits when CMD_FULL is asserted and proceeds when deasserted.
- **Vsync test**: Verify `wait_vsync()` detects a low-to-high transition on the VSYNC pin.
- **Buffer swap test**: Verify `swap_buffers()` exchanges draw/display configurations and writes FB_CONFIG and FB_DISPLAY.
- **Triangle submit test**: Verify `submit_triangle()` writes COLOR + VERTEX (non-textured) or COLOR + UV0_UV1 + VERTEX (textured) for each of 3 vertices.
- **Render mode test**: Verify `gpu_set_render_mode()` packs all fields correctly into RENDER_MODE (0x30) per INT-010 bit layout. Verify dither flag maps to bit 10.
- **Z range test**: Verify `gpu_set_z_range(0, 0xFFFF)` writes correct packed value to Z_RANGE (0x31).
- **FB config test**: Verify `gpu_set_fb_config()` packs color_base, z_base, width_log2, height_log2 into FB_CONFIG (0x40).
- **Scissor test**: Verify `gpu_set_scissor()` writes correct packed value to FB_CONTROL (0x43).
- **Mem fill test**: Verify `gpu_mem_fill(base, value, count)` writes correct packed value to MEM_FILL (0x44).
- **Combiner mode test**: Verify `gpu_set_combiner_mode()` writes correct two-cycle packed selectors to CC_MODE (0x18). Verify modulate preset produces expected register value.
- **Const color test**: Verify `gpu_set_const_color(const0, const1)` writes CONST0 in bits [31:0] and CONST1 in bits [63:32] of CONST_COLOR (0x19).
- **LUT prepare test**: Verify `gpu_prepare_lut()` issues MEM_ADDR + correct sequence of MEM_DATA writes for 384 bytes.

## Design Notes

Migrated from speckit module specification.

Dithering is configured via the DITHER_EN field in RENDER_MODE (0x30, bit 10).
The former standalone DITHER_MODE register (0x32) no longer exists; 0x32 is now STIPPLE_PATTERN.

Color LUT upload uses the SDRAM auto-load mechanism: the host prepares LUT data in SDRAM via MEM_ADDR/MEM_DATA, then sets FB_DISPLAY.LUT_ADDR to that address.
The hardware auto-loads the LUT during vblank when COLOR_GRADE_ENABLE=1 and LUT_ADDR!=0.
The former register-based upload protocol (COLOR_GRADE_CTRL / COLOR_GRADE_LUT_ADDR / COLOR_GRADE_LUT_DATA registers) has been removed.

The combiner now has two pipelined stages (CC_MODE[31:0] = cycle 0, CC_MODE[63:32] = cycle 1).
For single-equation rendering, configure cycle 1 as a pass-through: A=COMBINED, B=ZERO, C=ONE, D=ZERO.
CONST0 and CONST1 replace the former separate MAT_COLOR0/MAT_COLOR1/FOG_COLOR registers; they are packed together in CONST_COLOR (0x19).

The `gpu_set_render_mode()` function includes `dither` as a parameter (formerly a separate `gpu_set_dither_mode()` call).
The former `gpu_set_color_grade_enable()` function is replaced by the `enable_grading` field in `gpu_swap_buffers()` via the FB_DISPLAY register.
