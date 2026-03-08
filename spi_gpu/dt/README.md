# gs-twin — pico-gs Digital Twin

Bit-accurate, transaction-level Rust model of the pico-gs ECP5 graphics synthesizer.
Produces golden reference images that must match Verilator RTL simulation output **exactly** at the RGB565 pixel level.

## Why

1. **Algorithm clarity** — express rasterization/depth algorithms in readable Rust with the same integer math as the RTL
2. **Bit-accurate golden references** — automated exact-match comparison between twin output and Verilator framebuffer dumps catches any divergence
3. **Design documentation** — the rustdoc on each type and function *is* the authoritative design spec for the corresponding RTL module

## Scope

The GPU accepts pre-transformed screen-space vertices via 72-bit SPI register writes.
All vertex transformation, clipping, and projection is performed by the host CPU (RP2350 firmware in `pico-gs-core`), not the GPU hardware.
The digital twin models only what the FPGA does: register decode, integer rasterization, depth test, and framebuffer writes.

## Architecture

```
gs-twin (library)
├── cmd              Depth comparison function enum (shared with reg + mem)
├── math             Fixed-point type aliases (Depth Q4.12, TexCoord Q2.14),
│                    Rgb565 color type
├── mem              Framebuffer (RGB565), Z-buffer (u16), textures
├── reg              Register file state machine matching register_file.sv
│                    (vertex latching, render mode, scissor, kick → rasterize)
├── pipeline/
│   └── rasterize    Integer edge functions, Gouraud color interpolation,
│                    Z interpolation — matches rasterizer.sv
├── hex_parser       Parse .hex test scripts into register write sequences
└── test_harness     Exact-match comparison, diff images

gs-twin-cli (binary)
    render           Render a hex-script test scene to PNG
    diff             Compare twin PNG vs Verilator raw RGB565 dump
                     (exit code 1 on any pixel mismatch)
```

## Integration with pico-gs

### Test fixture workflow

```
1. Define test scene as .hex register-write script
2. Both the Rust twin and Verilator testbench consume the same .hex file

3a. Rust twin:   parse .hex → Gpu::reg_write_script → framebuffer pixels
3b. Verilator:   C++ loader reads .hex → SPI register writes → dump framebuffer.raw

4. gs-twin-cli diff --reference ref.png --actual framebuffer.raw
   → exit 0 on exact match, exit 1 on any pixel difference
   → optional --diff-image highlights mismatches
```

### CI integration

```makefile
test-golden:
    cargo test -p gs-twin
    cargo run -p gs-twin-cli -- render --scene ver_010 --output ref.png
    cd spi_gpu && make verilator-test SCENE=ver_010
    cargo run -p gs-twin-cli -- diff \
        --reference ref.png \
        --actual spi_gpu/build/ver_010.raw \
        --diff-image build/diff.png
```

## Relationship to syskit specs

- **syskit owns**: requirements (REQ-*), interfaces (INT-*), architectural
  ADRs, concept of execution — system-level "what" and "why"
- **gs-twin owns**: algorithmic design — the "how" for the rasterizer,
  expressed as executable Rust matching the RTL integer arithmetic
- **syskit UNIT docs** for algorithmic modules become thin pointers:
  "authoritative design is in `gs-twin/src/pipeline/rasterize.rs`"
