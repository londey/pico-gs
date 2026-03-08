# gs-twin — pico-gs Digital Twin

Bit-accurate, transaction-level Rust model of the pico-gs ECP5 graphics synthesizer.
Produces golden reference images that must match Verilator RTL simulation output **exactly** at the RGB565 pixel level.

## Why

1. **Algorithm clarity** — express rasterization/texturing/depth algorithms in readable Rust with the same fixed-point math as the RTL
2. **Bit-accurate golden references** — automated exact-match comparison between twin output and Verilator framebuffer dumps catches any divergence
3. **Design documentation** — the rustdoc on each type and function *is* the authoritative design spec for the corresponding RTL module

## Fixed-Point Contract

Every numeric type in the pipeline uses the same Q format as the corresponding RTL wire:

| Pipeline Stage | Type | Q Format | Bits | Notes |
|---|---|---|---|---|
| Vertex coords | `Coord` | Q16.16 | 32 | MVP matrix elements, clip-space positions |
| Screen coords | `ScreenCoord` | Q12.4 | 16 | Pixel + 4-bit sub-pixel for edge functions |
| Depth | `Depth` | Q4.12 | 16 | Z-buffer entries, signed comparison |
| Edge functions | `EdgeAccum` | Q16.16 | 32 | Cross products for inside test + barycentrics |
| Texture coords | `TexCoord` | Q2.14 | 16 | UV with wrap, perspective-correct interpolation |
| Reciprocal W | `WRecip` | Q0.16 | 16 | Unsigned, for perspective correction |
| Color channels | `ColorChannel` | Q1.7 | 8 | Expanded from RGB565 for interpolation |
| Pixel | `Rgb565` | 5-6-5 | 16 | Framebuffer native format |

The `math` module documents the RTL's rounding (truncation) and overflow (wrapping) behavior for each operation. If a type alias changes, the RTL must change to match.

## Architecture

```
gs-twin (library)
├── cmd              GPU command definitions (shared ISA)
├── math             Fixed-point type aliases, vectors, matrices
│                    (authoritative Q format spec for RTL)
├── mem              Framebuffer (RGB565), Z-buffer (Q4.12), textures
├── pipeline/
│   ├── command_proc Interpret commands, dispatch draws
│   ├── vertex       MVP transform (Q16.16 MAC chain)
│   ├── clip         Frustum reject, perspective divide, viewport → Q12.4
│   ├── rasterize    Edge functions (Q16.16), perspective-correct UV interp
│   └── fragment     Depth test (Q4.12), texture sample, RGB565 modulate
└── test_harness     Exact-match comparison, diff images, test scenes

gs-twin-cli (binary)
    render           Render a test scene to PNG
    diff             Compare twin PNG vs Verilator raw RGB565 dump
                     (exit code 1 on any pixel mismatch)
```

## Integration with pico-gs

### Test fixture workflow

```
1. Define test scene as Vec<GpuCommand>
2. Serialize to bincode → tests/fixtures/scene_name.bin

3a. Rust twin:   load .bin → Gpu::execute → framebuffer pixels (exact RGB565)
3b. Verilator:   C++ loader reads .bin → SPI register writes → dump framebuffer.raw

4. gs-twin-cli diff --reference ref.png --actual framebuffer.raw
   → exit 0 on exact match, exit 1 on any pixel difference
   → optional --diff-image highlights mismatches
```

### CI integration

```makefile
test-golden:
    cargo test -p gs-twin
    cargo run -p gs-twin-cli -- render --scene single_triangle --output ref.png
    cd spi_gpu && make verilator-test SCENE=single_triangle
    cargo run -p gs-twin-cli -- diff \
        --reference ref.png \
        --actual spi_gpu/build/single_triangle.raw \
        --diff-image build/diff.png
```

## The 1/w Problem

The one known source of intentional divergence is the reciprocal W computation
in `clip.rs`. The twin currently uses an f32 intermediate to compute 1/w,
then quantizes to Q0.16. The RTL will use a LUT + Newton-Raphson or similar
hardware-friendly method. Once the RTL's reciprocal is implemented, the twin's
`project_vertex` function should be updated to match the same algorithm (LUT
contents + iteration count), at which point the output will be bit-exact.

This is marked with a `TODO` in `clip.rs`.

## Relationship to syskit specs

- **syskit owns**: requirements (REQ-*), interfaces (INT-*), architectural
  ADRs, concept of execution — system-level "what" and "why"
- **gs-twin owns**: algorithmic design — the "how" for each pipeline stage,
  expressed as executable Rust with type-level Q format specs
- **syskit UNIT docs** for algorithmic modules become thin pointers:
  "authoritative design is in `gs-twin/src/pipeline/rasterize.rs`"
