# INT-020: GPU Driver API

## Type

Internal

## Serves Requirement Areas

- Area 7: Vertex Transformation (REQ-007.02, REQ-013.02)
- Area 8: Scene Graph/ECS (REQ-008.01, REQ-008.02, REQ-008.03, REQ-008.04, REQ-008.05)

## Parties

- **Provider:** UNIT-022 (GPU Driver Layer)
- **Consumer:** UNIT-021 (Core 1 Render Executor), pico-gs-pc main loop

## Referenced By

- REQ-008.01 (Scene Management) — Area 8: Scene Graph/ECS
- REQ-008.02 (Render Pipeline Execution) — Area 8: Scene Graph/ECS
- REQ-013.01 (GPU Communication Protocol) — Area 1: GPU SPI Controller
- REQ-010.01 (PC Debug Host) — Area 10: GPU Debug GUI
- REQ-008.03 (Scene Graph Management) — Area 8: Scene Graph/ECS
- REQ-007.02 (Render Mesh Patch) — Area 7: Vertex Transformation
- REQ-013.02 (Upload Texture) — Area 1: GPU SPI Controller
- REQ-013.03 (VSync Synchronization) — Area 6: Screen Scan Out
- REQ-005.08 (Clear Framebuffer) — Area 5: Blend/Frame Buffer Store
- REQ-001.06 (GPU Flow Control) — Area 1: GPU SPI Controller
- REQ-008.05 (Default Demo Startup) — Area 8: Scene Graph/ECS
- REQ-005.10 (Ordered Dithering) — Area 5: Blend/Frame Buffer Store
- REQ-006.03 (Color Grading LUT) — Area 6: Screen Scan Out
- REQ-004.02 (Extended Precision Fragment Processing) — Area 4: Fragment Processor/Color Combiner

Note: REQ-100 (Host Firmware Architecture) and REQ-110 (GPU Initialization) and REQ-120 (Async Data Loading) are retired; their references have been removed.

## Specification

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
- GPU device ID verified (expect 0x6702)

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
- `addr` is a readable register (ID: 0x7F, MEM_DATA: 0x71, PERF_TIMESTAMP: 0x50)
- For consistent reads, CMD_EMPTY should be asserted

**Transaction**:
1. Assert CS low
2. Transmit 8 bits: [1 | addr(7)]
3. Clock in 64 bits from MISO
4. Deassert CS high

---

## Bulk Memory Transfer

### `gpu_upload_memory(handle: &GpuHandle, dword_addr: u32, data: &[u64])`

Upload a block of 64-bit dwords to GPU SDRAM via MEM_ADDR/MEM_DATA registers.

**Sequence**:
1. `gpu_write(MEM_ADDR, dword_addr)` — 22-bit dword address (addresses 8-byte dwords in 32 MiB SDRAM)
2. For each dword in `data`: `gpu_write(MEM_DATA, dword)`
3. MEM_ADDR auto-increments by 1 after each MEM_DATA write

**Performance**: ~6 MB/s at 25 MHz SPI (each 64-bit dword requires a single 72-bit transaction).

**Use cases**: Texture upload, LUT upload

### `gpu_read_memory(handle: &GpuHandle, dword_addr: u32, buf: &mut [u64])`

Read a block of 64-bit dwords from GPU SDRAM via MEM_ADDR/MEM_DATA registers.

**Sequence**:
1. `gpu_write(MEM_ADDR, dword_addr)` — triggers prefetch of first dword
2. For each slot in `buf`: `gpu_read(MEM_DATA)` — returns prefetched dword, triggers next prefetch
3. MEM_ADDR auto-increments by 1 after each MEM_DATA read

**Performance**: ~6 MB/s at 25 MHz SPI.

**Use cases**: Memory readback, verification

---

## Hardware Fill

### `gpu_mem_fill(handle: &GpuHandle, base: u16, value: u16, count: u32)`

Fill a contiguous region of SDRAM with a 16-bit constant value using the hardware MEM_FILL engine.

**Sequence**:
1. Build MEM_FILL register value:
   ```rust
   let reg_value = ((count as u64) << 32)
                 | ((value as u64) << 16)
                 | (base as u64);
   ```
2. `gpu_write(MEM_FILL, reg_value)`
3. GPU executes the fill within the command FIFO; subsequent commands are queued and execute after completion

**Parameters**:
- `base`: Target base address (512-byte granularity, same encoding as FB_CONFIG.COLOR_BASE)
  - Byte address = base × 512
- `value`: 16-bit constant to write at each position (RGB565 for color buffer, Z16 for Z-buffer)
- `count`: Number of 16-bit words to write (up to 1,048,576 = 1M words = 2 MB per fill)

**Use cases**:
- Clear framebuffer: fill with background RGB565 color
- Clear Z-buffer: fill with 0xFFFF (far depth)

**Performance**: MEM_FILL uses sequential SDRAM burst writes for maximum throughput (~100 MB/s theoretical, burst-limited to ~50 MB/s with SDRAM overhead).

**Example**:
```rust
// Clear color buffer (black)
let fb_base: u16 = (FB_A_BYTE_ADDR / 512) as u16;
let pixels = (width * height) as u32;
gpu_mem_fill(&gpu, fb_base, 0x0000, pixels);

// Clear Z-buffer (far = 0xFFFF)
let z_base: u16 = (FB_A_Z_BYTE_ADDR / 512) as u16;
gpu_mem_fill(&gpu, z_base, 0xFFFF, pixels);
```

---

## Texture Upload

### `gpu_upload_texture(handle: &GpuHandle, slot: u8, width: u32, height: u32, format: TextureFormat, data: &[u8])`

Upload a single-level texture to GPU SDRAM and configure texture unit registers.

**Sequence**:
1. Allocate GPU SDRAM for texture (512-byte aligned)
2. Upload texture data via `gpu_upload_memory()`
3. Write TEXn_CFG register (0x10 + slot) with base_addr, width_log2, height_log2, format, enable, mip_levels=1

**Parameters**:
- `slot`: Texture unit index (0-1)
- `width`, `height`: Texture dimensions (power-of-2, 8-1024)
- `format`: One of `TextureFormat` variants (see below)
- `data`: Texture pixel data in 4×4 block-tiled layout (size must match format and dimensions)

**`TextureFormat` enum**:
| Variant | Value | Description |
|---------|-------|-------------|
| `BC1` | 0 | 4 bpp, 4×4 blocks, opaque or 1-bit alpha |
| `BC2` | 1 | 8 bpp, 4×4 blocks, explicit 4-bit alpha |
| `BC3` | 2 | 8 bpp, 4×4 blocks, interpolated alpha |
| `BC4` | 3 | 4 bpp, 4×4 blocks, single channel (R8 quality) |
| `RGB565` | 4 | 16 bpp, 4×4 tiled, no alpha |
| `RGBA8888` | 5 | 32 bpp, 4×4 tiled, full alpha |
| `R8` | 6 | 8 bpp, 4×4 tiled, single channel |

**Example**:
```rust
gpu_upload_texture(&gpu, 0, 256, 256, TextureFormat::BC1, PLAYER_DATA);
gpu_upload_texture(&gpu, 1, 64, 64, TextureFormat::RGB565, LIGHTMAP_DATA);
```

---

### `gpu_upload_texture_with_mipmaps(handle: &GpuHandle, slot: u8, width: u32, height: u32, format: TextureFormat, mip_levels: u8, data: &[u8], mip_offsets: &[usize])`

Upload a texture with mipmap chain to GPU SDRAM and configure texture unit registers.

**Sequence**:
1. Calculate total size (sum of all mipmap level sizes)
2. Allocate GPU SDRAM for texture chain (512-byte aligned base address)
3. Upload all mipmap levels sequentially via `gpu_upload_memory()`
4. Write TEXn_CFG register (base_addr, width_log2, height_log2, format, enable, mip_levels)

**Parameters**:
- `slot`: Texture unit index (0-1)
- `width`, `height`: Base level dimensions (power-of-2, 8-1024)
- `format`: `TextureFormat` variant
- `mip_levels`: Number of mipmap levels (1-11)
- `data`: Complete mipmap chain data (all levels concatenated, 4×4 block-tiled)
- `mip_offsets`: Byte offsets of each mipmap level within `data`

**Validation**:
- `mip_levels` must be in range [1, 11]
- `mip_levels` must be ≤ min(width_log2, height_log2) + 1
- `mip_offsets.len()` must equal `mip_levels`

---

## Rendering Configuration

### `gpu_set_render_mode(handle: &GpuHandle, gouraud: bool, z_test: bool, z_write: bool, color_write: bool, z_compare: ZCompare, alpha_blend: AlphaBlend, cull_mode: CullMode, dither: bool, stipple_en: bool, alpha_test: AlphaTest, alpha_ref: u8)`

Configure per-material rendering state in a single RENDER_MODE register write.

**Sequence**:
1. Build RENDER_MODE register value per INT-010 bit layout:
   ```rust
   let value = ((z_compare as u64) << 13)
             | ((dither as u64) << 10)
             | ((alpha_blend as u64) << 7)
             | ((cull_mode as u64) << 5)
             | ((color_write as u64) << 4)
             | ((z_write as u64) << 3)
             | ((z_test as u64) << 2)
             | (gouraud as u64)
             | ((stipple_en as u64) << 16)
             | ((alpha_test as u64) << 17)
             | ((alpha_ref as u64) << 19);
   ```
2. `gpu_write(RENDER_MODE, value)`

**Parameters**:
- `gouraud`: Enable Gouraud shading (true) or flat shading (false)
- `z_test`: Enable depth testing
- `z_write`: Enable Z-buffer writes on depth test pass
- `color_write`: Enable color buffer writes (false = Z-only prepass)
- `z_compare`: Depth comparison function (LESS, LEQUAL, EQUAL, GEQUAL, GREATER, NOTEQUAL, ALWAYS, NEVER)
- `alpha_blend`: Alpha blending mode (DISABLED, ADD, SUBTRACT, BLEND)
- `cull_mode`: Backface culling (NONE, CW, CCW)
- `dither`: Enable ordered dithering before RGB565 framebuffer write
- `stipple_en`: Enable 8×8 stipple pattern fragment discard
- `alpha_test`: Alpha test function (ALWAYS, LESS, GEQUAL, NOTEQUAL)
- `alpha_ref`: Alpha reference value (UNORM8, compared against fragment alpha)

**Notes**:
- Dithering is configured here; there is no separate `gpu_set_dither_mode()` function.
- Dithering smooths the Q4.12→RGB565 quantization using a blue noise pattern.

### `gpu_set_stipple_pattern(handle: &GpuHandle, pattern: u64)`

Set the 8×8 stipple bitmask. Bit index = y[2:0] × 8 + x[2:0]. Fragment passes when bit = 1.

**Sequence**:
1. `gpu_write(STIPPLE_PATTERN, pattern)`

**Default**: 0xFFFFFFFF_FFFFFFFF (all fragments pass)

### `gpu_set_z_range(handle: &GpuHandle, z_min: u16, z_max: u16)`

Configure depth range clipping (Z scissor). Fragments outside [z_min, z_max] are discarded before any SDRAM access.

**Sequence**:
1. `gpu_write(Z_RANGE, ((z_max as u64) << 16) | (z_min as u64))`

**Parameters**:
- `z_min`: Minimum Z value (16-bit unsigned, inclusive)
- `z_max`: Maximum Z value (16-bit unsigned, inclusive)

**Notes**:
- Default (disabled): z_min=0x0000, z_max=0xFFFF (passes all fragments)

---

## Color Combiner Configuration

### `gpu_set_combiner_mode(handle: &GpuHandle, c0: CombinerCycle, c1: CombinerCycle)`

Configure the two-stage color combiner equation `(A - B) × C + D` for both RGB and alpha channels.

**`CombinerCycle`** struct:
```rust
struct CombinerCycle {
    rgb_a: CcSource,
    rgb_b: CcSource,
    rgb_c: CcRgbCSource,   // extended source set for blend factor
    rgb_d: CcSource,
    alpha_a: CcSource,
    alpha_b: CcSource,
    alpha_c: CcSource,
    alpha_d: CcSource,
}
```

**Sequence**:
1. Build CC_MODE register value:
   ```rust
   let cycle0 = pack_cycle(c0);  // bits [31:0]
   let cycle1 = pack_cycle(c1);  // bits [63:32]
   let value = cycle0 | (cycle1 << 32);
   ```
2. `gpu_write(CC_MODE, value)`

**`CcSource` enum** (4-bit, used for A/B/D slots):
- `Combined` (0x0): Previous cycle output
- `TexColor0` (0x1): Texture unit 0 output
- `TexColor1` (0x2): Texture unit 1 output
- `Shade0` (0x3): Vertex color 0 (diffuse)
- `Const0` (0x4): Constant color 0
- `Const1` (0x5): Constant color 1 / fog color
- `One` (0x6): Constant 1.0
- `Zero` (0x7): Constant 0.0
- `Shade1` (0x8): Vertex color 1 (specular)

**`CcRgbCSource` enum** (4-bit, RGB C slot extended set):
- Includes all CcSource values plus:
  - `TexColor0Alpha` (0x8): TEX0 alpha broadcast to RGB
  - `TexColor1Alpha` (0x9): TEX1 alpha broadcast to RGB
  - `Shade0Alpha` (0xA): Shade0 alpha broadcast to RGB
  - `Const0Alpha` (0xB): Const0 alpha broadcast to RGB
  - `CombinedAlpha` (0xC): Combined alpha broadcast to RGB
  - `Shade1` (0xD): Shade1 RGB
  - `Shade1Alpha` (0xE): Shade1 alpha broadcast to RGB

**Single-stage helper** (`gpu_set_combiner_simple`): Sets cycle 0 with provided equation and cycle 1 as pass-through (A=COMBINED, B=ZERO, C=ONE, D=ZERO).

**Common presets**:
```rust
// Modulate: TEX0 * SHADE0
gpu_set_combiner_simple(&gpu, CombinerCycle {
    rgb_a: CcSource::TexColor0, rgb_b: CcSource::Zero, rgb_c: CcRgbCSource::Shade0, rgb_d: CcSource::Zero,
    alpha_a: CcSource::TexColor0, alpha_b: CcSource::Zero, alpha_c: CcSource::Shade0, alpha_d: CcSource::Zero,
});

// Fog (two-stage): stage 0 = TEX0 * SHADE0, stage 1 = lerp(COMBINED, CONST1, SHADE0.A)
gpu_set_combiner_mode(&gpu, modulate_cycle, CombinerCycle {
    rgb_a: CcSource::Combined, rgb_b: CcSource::Const1, rgb_c: CcRgbCSource::Shade0Alpha, rgb_d: CcSource::Const1,
    alpha_a: CcSource::One, alpha_b: CcSource::Zero, alpha_c: CcSource::One, alpha_d: CcSource::Zero,
});
```

### `gpu_set_const_color(handle: &GpuHandle, const0: RGBA8, const1: RGBA8)`

Set the two per-draw-call constant colors. CONST1 also serves as the fog color.

**Sequence**:
1. `gpu_write(CONST_COLOR, (const1.to_u32() as u64) << 32 | const0.to_u32() as u64)`

---

## Framebuffer Configuration

### `gpu_set_fb_config(handle: &GpuHandle, color_base: u16, z_base: u16, width_log2: u8, height_log2: u8)`

Configure the render target (color buffer + Z-buffer) for subsequent rendering.

**Sequence**:
1. Build FB_CONFIG register value:
   ```rust
   let value = ((height_log2 as u64) << 36)
             | ((width_log2 as u64) << 32)
             | ((z_base as u64) << 16)
             | (color_base as u64);
   ```
2. `gpu_write(FB_CONFIG, value)`

**Parameters**:
- `color_base`: Byte address of color buffer ÷ 512 (512-byte granularity)
- `z_base`: Byte address of Z-buffer ÷ 512
- `width_log2`: Surface width as power-of-two exponent (e.g., 9 = 512 pixels wide)
- `height_log2`: Surface height as power-of-two exponent

**Notes**:
- Both color and Z surfaces use 4×4 block-tiled layout at these dimensions.
- Use to switch between double-buffered framebuffers or render-to-texture targets.

### `gpu_set_scissor(handle: &GpuHandle, x: u16, y: u16, width: u16, height: u16)`

Set the pixel-precision scissor rectangle. Fragments outside are discarded.

**Sequence**:
1. Build FB_CONTROL register value and `gpu_write(FB_CONTROL, value)`.

---

## Dithering and Color Grading

### `gpu_prepare_lut(handle: &GpuHandle, lut_addr: u32, lut: &ColorGradeLut)`

Upload color grading LUT data to SDRAM for later auto-load.

**Sequence**:
1. `gpu_write(MEM_ADDR, lut_addr)` — set SDRAM destination address (dword address)
2. For each Red LUT entry (32 entries × 3 bytes):
   - Write 3 bytes R,G,B via `MEM_DATA` (auto-increments address)
3. For each Green LUT entry (64 entries × 3 bytes):
   - Write 3 bytes R,G,B via `MEM_DATA`
4. For each Blue LUT entry (32 entries × 3 bytes):
   - Write 3 bytes R,G,B via `MEM_DATA`

**Parameters**:
- `lut_addr`: SDRAM dword address for LUT storage (must be 512-byte aligned → dword_addr must be multiple of 64)
- `lut`: LUT data structure with red[32], green[64], blue[32] RGB888 entries

**Format in SDRAM** (384 bytes total):
```rust
struct ColorGradeLut {
    red: [(u8, u8, u8); 32],    // 32 entries × 3 bytes (R,G,B) = 96 bytes
    green: [(u8, u8, u8); 64],  // 64 entries × 3 bytes = 192 bytes
    blue: [(u8, u8, u8); 32],   // 32 entries × 3 bytes = 96 bytes
}
```

**Performance**: 384 bytes ÷ 4 bytes/write = 96 MEM_DATA writes ≈ 276 µs at 25 MHz

**Notes**:
- LUT data can be prepared once at init or anytime before use.
- Multiple LUTs can be pre-prepared in SDRAM for instant switching at vblank.
- The LUT is auto-loaded during vblank when FB_DISPLAY.COLOR_GRADE_ENABLE=1 and LUT_ADDR!=0.

### `gpu_create_identity_lut() → ColorGradeLut`

Create identity LUT where each channel maps to itself (no color change).

### `gpu_create_gamma_lut(gamma: f32) → ColorGradeLut`

Create gamma correction LUT (linear → gamma curve).

**Parameters**:
- `gamma`: Gamma value (typical: 2.2 for sRGB, 2.4 for Rec.709)

### `gpu_create_contrast_lut(contrast: f32, brightness: f32) → ColorGradeLut`

Create contrast/brightness adjustment LUT.

**Parameters**:
- `contrast`: Contrast multiplier (1.0 = no change)
- `brightness`: Brightness offset (-128 to +128, 0 = no change)

---

## Frame Synchronization

### `gpu_wait_vsync(handle: &GpuHandle)`

Block until the GPU asserts the VSYNC GPIO signal.

**Implementation**:
1. Wait for VSYNC GPIO rising edge
2. Return immediately after edge detected

**Timing**: VSYNC pulses every 16.67 ms (60 Hz)

### `gpu_swap_buffers(handle: &GpuHandle, draw_color_base: u16, draw_z_base: u16, width_log2: u8, height_log2: u8, display_fb_addr: u16, display_width_log2: u8, lut_addr: u16, enable_grading: bool, line_double: bool)`

Configure the draw and display framebuffers atomically at vsync.

**Parameters**:
- `draw_color_base`, `draw_z_base`, `width_log2`, `height_log2`: New draw render target (written to FB_CONFIG, 0x40)
- `display_fb_addr`: New display scanout base address (512-byte granularity)
- `display_width_log2`: Display surface width log2 for tiled address calculation
- `lut_addr`: SDRAM address of color grading LUT (512-byte granularity), or 0 to skip LUT update
- `enable_grading`: Enable (true) or bypass (false) color grading at scanout
- `line_double`: Double each source line to fill 480 display lines from 240 source rows

**Sequence**:
1. Write FB_CONFIG (0x40) with new draw target parameters (non-blocking)
2. Build FB_DISPLAY register value:
   ```rust
   let fb_display_value = ((display_width_log2 as u64) << 48)
                        | ((display_fb_addr as u64) << 32)
                        | ((lut_addr as u64) << 16)
                        | ((line_double as u64) << 1)
                        | (enable_grading as u64);
   ```
3. Write to FB_DISPLAY (0x41) — **blocks the GPU pipeline until vsync**; changes apply atomically

**Behavior**:
- FB_DISPLAY write waits for vsync within the command FIFO (SPI CS held asserted until vsync)
- If `lut_addr != 0` and `enable_grading`: hardware auto-loads 384-byte LUT from SDRAM during vblank
- If `lut_addr == 0`: skip LUT load, only switch display scanout

**Examples**:
```rust
// Swap with gamma correction LUT
gpu_swap_buffers(&gpu, FB_B_COLOR, FB_B_Z, 9, 9, FB_A_ADDR, 9, LUT_ADDR, true, false);

// Swap without color grading
gpu_swap_buffers(&gpu, FB_A_COLOR, FB_A_Z, 9, 9, FB_B_ADDR, 9, 0, false, false);
```

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
gpu_write(COLOR, v0.color_packed)         // COLOR0 + COLOR1
gpu_write(UV0_UV1, v0.uv_packed)
gpu_write(VERTEX_NOKICK, v0.position_packed)

gpu_write(COLOR, v1.color_packed)
gpu_write(UV0_UV1, v1.uv_packed)
gpu_write(VERTEX_NOKICK, v1.position_packed)

gpu_write(COLOR, v2.color_packed)
gpu_write(UV0_UV1, v2.uv_packed)
gpu_write(VERTEX_KICK_012, v2.position_packed)  // triggers rasterization
```

**Register writes per triangle**: 9 (3 vertices × 3 registers each)

### Triangle Strip Submission

For efficient mesh rendering, triangles are submitted as strips using kicked vertex registers defined in INT-010:

- `VERTEX_NOKICK (0x06)`: Push vertex, no triangle emitted
- `VERTEX_KICK_012 (0x07)`: Push vertex, emit triangle (v[0], v[1], v[2])
- `VERTEX_KICK_021 (0x08)`: Push vertex, emit triangle (v[0], v[2], v[1])
- `VERTEX_KICK_RECT (0x09)`: Two-corner axis-aligned rectangle emit

### Buffered SPI Output

For DMA/PIO-driven SPI output on RP2350, the GPU driver supports a buffered write mode where register commands are packed into a SRAM buffer:

```rust
fn pack_register_write(buffer: &mut [u8], offset: usize, addr: u8, data: u64) -> usize
```

---

## GpuVertex (packed format)

Pre-packed vertex data ready for GPU register writes.

| Field | Format | GPU Register |
|-------|--------|-------------|
| color_packed | u64: COLOR0 in [31:0], COLOR1 in [63:32] (RGBA8888 each) | COLOR (0x00) |
| uv_packed | u64: UV0_U in [15:0], UV0_V in [31:16], UV1_U in [47:32], UV1_V in [63:48] (S3.12) | UV0_UV1 (0x01) |
| position_packed | u64: X in [15:0], Y in [31:16], Z in [47:32], Q (1/W) in [63:48] (S12.4, S3.12) | VERTEX_NOKICK/KICK (0x06-0x09) |

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
