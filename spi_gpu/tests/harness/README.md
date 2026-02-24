# Integration Test Harness

Shared C++ harness for VER-010 through VER-013 golden image integration tests.
This harness drives a Verilated `gpu_top` model with register-write command scripts, captures the resulting framebuffer from a behavioral SDRAM model, and writes PPM golden images for comparison.

## Architecture Overview

The harness consists of four components:

1. **Main harness** (`harness.cpp`) -- Instantiates the Verilated GPU model, connects the behavioral SDRAM model to the memory arbiter ports, drives register-write command scripts into the register file inputs, runs the clock loop until rendering completes, and calls the PPM writer to serialize the framebuffer.

2. **Behavioral SDRAM model** (`sdram_model.h`, `sdram_model.cpp`) -- A cycle-accurate behavioral model of the W9825G6KH-6 SDRAM (INT-011).
   Provides a simple C++ API (`read_word()`, `write_word()`, `fill_texture()`) and implements the 4x4 block-tiled address layout defined in INT-011.

3. **PPM writer** (`ppm_writer.h`, `ppm_writer.cpp`) -- Reads an RGB565 framebuffer array and writes a binary P6 PPM file, converting 16-bit RGB565 pixels to 8-bit-per-channel RGB for PPM output.

4. **Command scripts** -- C++ arrays of `{addr, data}` pairs encoding INT-021 register-write sequences.
   Each VER test scene provides its own command script that replicates the register writes produced by `RenderMeshPatch`, `ClearFramebuffer`, and other render commands.

## Verilator Invocation

The harness is compiled with Verilator using the project's shared flags:

```
verilator --binary -f verilator.f <RTL sources> tests/harness/harness.cpp tests/harness/sdram_model.cpp tests/harness/ppm_writer.cpp --top-module gpu_top -o harness
```

This matches the existing Makefile convention (`VERILATOR_FLAGS = --binary -f verilator.f`).

## Behavioral SDRAM Model

The SDRAM model implements the INT-011 4x4 block-tiled address layout for all surface types (color buffers, Z-buffer, textures).

### Block-Tiled Address Calculation (INT-011)

```
block_x    = x >> 2
block_y    = y >> 2
local_x    = x & 3
local_y    = y & 3
block_idx  = (block_y << (WIDTH_LOG2 - 2)) | block_x
word_addr  = base_word + block_idx * 16 + (local_y * 4 + local_x)
byte_addr  = word_addr * 2
```

### C++ API

- `read_word(uint32_t addr)` -- Read a 16-bit word from the given word address.
- `write_word(uint32_t addr, uint16_t data)` -- Write a 16-bit word at the given word address.
- `fill_texture(uint32_t base_addr, uint8_t format, const uint8_t* pixel_data, size_t size)` -- Upload texture data to the model, laying out pixels in the INT-011 4x4 block-tiled scheme at the burst lengths defined in INT-032 for each format.

### INT-032 Burst Lengths

The texture cache (INT-032) issues burst reads with format-dependent lengths on cache miss:

| Format   | burst_len (16-bit words) | Bytes | Description               |
|----------|--------------------------|-------|---------------------------|
| BC1      | 4                        | 8     | 64-bit BC1 block          |
| BC2      | 8                        | 16    | 128-bit BC2 block         |
| BC3      | 8                        | 16    | 128-bit BC3 block         |
| BC4      | 4                        | 8     | 64-bit BC4 block          |
| RGB565   | 16                       | 32    | 16 x 16-bit pixels        |
| RGBA8888 | 32                       | 64    | 16 x 32-bit pixels        |
| R8       | 8                        | 16    | 16 x 8-bit pixels packed  |

The behavioral model must serve data at these burst lengths when the Verilated memory arbiter issues burst read requests.

## Command Script Format

Each test scene defines a command script as a C++ array of register-write pairs:

```cpp
struct RegWrite {
    uint8_t  addr;   // Register address (INT-010 register map index)
    uint64_t data;   // Register data (up to 64 bits for MEM_DATA)
};

// Example: VER-010 flat-shaded triangle
static const RegWrite ver_010_script[] = {
    {REG_RENDER_MODE, 0x...},   // Configure render mode
    {REG_COLOR,       0x...},   // Set vertex color
    {REG_VERTEX,      0x...},   // Submit vertex (kick triangle)
    // ...
};
```

This format directly encodes the register-write sequences that INT-021 `RenderMeshPatch` and `ClearFramebuffer` commands produce on the SPI bus.
The harness drives these writes into the register file inputs of the Verilated model.

## PPM Output

After the simulation completes rendering, the harness:

1. Extracts the framebuffer contents from the SDRAM model (512x480 region of the 512x512 color buffer).
2. Calls `ppm_writer::write_ppm()` to convert RGB565 pixels to 8-bit RGB and write a binary P6 PPM file.
3. The output PPM is compared against approved golden images in `tests/golden/`.

## Directory Layout

```
tests/
  harness/
    README.md           -- This file
    harness.cpp         -- Main harness skeleton
    sdram_model.h       -- Behavioral SDRAM model header
    sdram_model.cpp     -- Behavioral SDRAM model implementation
    ppm_writer.h        -- PPM image writer header
    ppm_writer.cpp      -- PPM image writer implementation
  golden/
    .gitkeep            -- Golden images (empty until first approved image)
  vectors/
    .gitkeep            -- Test vectors (empty until extended)
```

## References

- **INT-011** (SDRAM Memory Layout) -- 4x4 block-tiled address calculation, memory map, SDRAM timing.
- **INT-014** (Texture Memory Layout) -- Texture format encodings and block sizes.
- **INT-021** (Render Command Format) -- Register-write sequences for render commands.
- **INT-032** (Texture Cache Architecture) -- Cache miss burst lengths per texture format.
- **VER-010** -- Flat-Shaded Triangle Golden Image Test.
- **VER-011** -- Depth-Tested Overlapping Triangles Golden Image Test.
- **VER-012** -- Textured Triangle Golden Image Test.
- **VER-013** -- Color-Combined Output Golden Image Test.
