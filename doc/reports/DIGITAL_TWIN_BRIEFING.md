# pico-gs Digital Twin — Implementation Briefing

## Context

pico-gs is an ECP5-25K FPGA 3D graphics synthesizer (repo: github.com/londey/pico-gs).
The project uses syskit for spec-driven development with requirements (REQ-*),
interfaces (INT-*), and design units (UNIT-*) in `doc/`.

We are adding a **digital twin** — a bit-accurate, transaction-level Rust model
of the GPU pipeline — located at `spi_gpu/dt/` within the existing repo.
The twin serves as both the algorithmic design documentation and the golden
reference for validating the SystemVerilog RTL via Verilator.

## Goals

1. **Bit-accurate output**: The twin uses the same fixed-point Q formats and
   rounding/overflow behavior as the RTL. Any pixel difference between twin
   and Verilator output indicates a real bug, not a numeric approximation.

2. **Design documentation**: The rustdoc on each type and function IS the
   authoritative design spec for the corresponding RTL module. Syskit UNIT
   docs for algorithmic modules become thin pointers to the twin source.

3. **Inter-stage comparison**: Binary trace files at pipeline boundaries
   allow field-by-field comparison between twin and Verilator, localizing
   bugs to a specific pipeline stage.

## Architecture Decisions

### Stateless functions vs. structs

- **Vertex stage**: stateless function (combinational in RTL)
- **Clip/viewport stage**: stateless function (combinational in RTL)
- **Rasterizer**: struct with two-phase interface (RTL has 2-deep FIFO between
  triangle setup and edge walker)
- **Fragment stage**: stateless function taking &mut memory references (reads/writes
  SRAM for Z-buffer and framebuffer)
- **Command processor**: stateless function taking &mut GpuState + &mut GpuMemory

### Rasterizer two-phase design

The RTL has a ~14-cycle triangle setup stage followed by a per-pixel edge walker,
connected by a 2-deep FIFO. The twin models this as:

```rust
impl Rasterizer {
    /// Phase 1: Triangle setup. Output is the FIFO entry.
    fn setup(&self, tri: &ScreenTriangle) -> Option<TriangleSetup>;

    /// Phase 2: Edge walk. Consumes one setup, yields fragments.
    fn walk(&self, setup: &TriangleSetup) -> FragmentIter;
}
```

`TriangleSetup` must match the RTL's FIFO word layout field-for-field:
edge function initial values, per-pixel X/Y increments, bounding box,
attribute base values and gradients.

`FragmentIter` implements `Iterator<Item = Fragment>` — no Vec allocation.
Test code can `.collect()` when needed.

### Fixed-point types (authoritative Q format spec)

| Type | Q Format | Bits | Usage |
|------|----------|------|-------|
| `Coord` | Q16.16 | 32 | Vertex positions, MVP matrix elements, clip-space |
| `MulAccum` | Q16.16 | 32 | MAC intermediate (widen if RTL uses ALU54B) |
| `ScreenCoord` | Q12.4 | 16 | Pixel coords + 4-bit sub-pixel |
| `Depth` | Q4.12 | 16 | Z-buffer entries, signed comparison |
| `EdgeAccum` | Q16.16 | 32 | Edge function cross products, barycentrics |
| `TexCoord` | Q2.14 | 16 | UV coordinates, wrap via bitmask |
| `WRecip` | Q0.16 | 16 | 1/w unsigned, for perspective correction |
| `ColorChannel` | Q1.7 | 8 | Per-channel expanded from RGB565 for interpolation |

All multiplications use `wrapping_mul` (matching Verilog truncation on sized
assignment). Use `wrapping_add` for accumulation. Use the `fixed` crate
(version 1.x).

### Rounding and overflow convention

- **Multiplication**: truncate low fractional bits (toward zero), matching
  Verilog's default behavior and the MULT18X18D's 36-bit product truncated
  to 32 bits.
- **Overflow**: wrapping (matching Verilog), unless the RTL explicitly
  saturates (use `saturating_narrow` for those cases).
- **Division**: truncating (fixed crate's default).

### Inter-stage types (RTL wire formats)

These structs correspond to signals crossing module boundaries in the RTL:

- `ClipVertex`: 4× Q16.16 clip coords + Q2.14 UVs + RGB565 color
- `ScreenVertex`: Q12.4 x/y + Q4.12 depth + Q0.16 w_recip + Q2.14 UVs + RGB565
- `TriangleSetup`: edge function init/increments + bbox + attribute gradients
  (matches RTL's 2-deep FIFO entry)
- `Fragment`: u16 x/y + Q4.12 depth + Q2.14 UVs + RGB565 color + Q16.16 barycentrics

### Binary trace format for Verilator comparison

Each inter-stage type implements `to_trace_record(&self) -> Vec<u8>`:
- Packed little-endian fixed-width integers
- No enum tags, no padding — just raw `.to_bits()` values in defined order
- Companion `.fields` text file defines field name, byte offset, width, Q format
- Verilator testbenches emit identical format via `$fwrite`
- Comparison is field-by-field diff with named output on first divergence

Use Rust enums internally for readability. Map to integer discriminants
only in `to_trace_record()`.

### SDRAM access counting

The fragment stage maintains an `SdramAccessCounts` struct:
```rust
pub struct SdramAccessCounts {
    pub z_reads: u32,       // every fragment attempts a Z read
    pub z_writes: u32,      // fragments that pass depth test
    pub fb_writes: u32,     // fragments that pass depth test
    pub tex_fetches: u32,   // texture samples (if texture bound)
}
```
Used for bandwidth budgeting, not timing simulation.

### Texture cache model

A configurable cache simulator inside the texture sampler:
- Parameterized: line size, line count, associativity (direct-mapped or N-way)
- Tracks tag array state, counts hits/misses
- Access sequence is identical to RTL (same fragment order from bounding-box walk)
- Hit rates are exact, enabling cache sizing design space exploration
- Keep it small and optional (feature-gated or runtime-configured)

### Known divergence: 1/w reciprocal

The clip stage's perspective divide currently uses an f32 intermediate to
compute 1/w, then quantizes to Q0.16. This is a placeholder. Once the RTL's
reciprocal method (LUT + Newton-Raphson or similar) is implemented, the twin
must match the same algorithm for bit-exact results. Marked with TODO.

### Relationship to syskit

- **syskit owns**: REQ-*, INT-*, architectural ADRs, concept of execution
- **twin owns**: algorithmic design for pipeline stages (the rustdoc IS the spec)
- **UNIT docs for algorithmic modules**: become thin pointers to twin source,
  e.g. "authoritative design is in spi_gpu/dt/src/pipeline/rasterize.rs"
- **UNIT docs for non-algorithmic modules** (SPI controller, clock crossings,
  SRAM arbiter): remain in syskit as the primary design documentation

### Test philosophy

- **Primary criterion**: exact RGB565 bit match between twin and Verilator framebuffer
- **Inter-stage traces**: field-by-field binary comparison at pipeline boundaries
- **PSNR and channel diffs**: diagnostic aids only, not pass/fail criteria
- **Test scenes**: defined as `Vec<GpuCommand>`, serialized to bincode fixtures,
  consumed by both twin and Verilator testbench

## Crate Structure

```
spi_gpu/dt/
├── Cargo.toml              (workspace or standalone)
├── src/
│   ├── lib.rs              Top-level Gpu struct, module re-exports
│   ├── cmd.rs              GPU command set (shared ISA with host/RTL)
│   ├── math.rs             Fixed-point type aliases, Vec/Mat types
│   │                       (authoritative Q format specification)
│   ├── mem.rs              Framebuffer, Z-buffer, texture store
│   ├── trace.rs            Binary trace emission + .fields definitions
│   ├── sdram_budget.rs     SDRAM access counters
│   ├── pipeline/
│   │   ├── mod.rs          Inter-stage transaction types
│   │   ├── command_proc.rs Command interpreter, draw dispatch
│   │   ├── vertex.rs       MVP transform (Q16.16 MAC)
│   │   ├── clip.rs         Frustum reject, persp divide, viewport
│   │   ├── rasterize.rs    Rasterizer struct: setup + FragmentIter
│   │   └── fragment.rs     Depth test, texture sample, FB write
│   └── cache.rs            Configurable texture cache model
├── tests/
│   ├── integration.rs      Smoke tests, roundtrip checks
│   └── fixtures/           Bincode command streams, golden PNGs
└── README.md
```

## Getting Started

1. Read the existing UNIT-* docs in `doc/design/` to understand the current
   RTL module decomposition and design intent.
2. Read INT-010 (GPU Register Map) and INT-011 (SRAM Memory Layout) for the
   hardware/software contracts.
3. Create `spi_gpu/dt/` with the crate structure above.
4. Start with `math.rs` — the Q format aliases are the foundation everything
   else depends on. Get these right first.
5. Build out the pipeline stages bottom-up: vertex → clip → rasterize → fragment.
6. Add trace emission after each stage is working.
7. Wire up to existing Verilator testbenches for comparison.

The scaffold tarball from the design conversation provides a starting point
for all source files, but needs the following changes applied:
- Rasterizer: split into setup + FragmentIter (currently a single function returning Vec)
- Add trace.rs and .fields definitions (not yet present)
- Add sdram_budget.rs (not yet present)
- Add cache.rs (not yet present)
- TriangleSetup struct (not yet defined — needs to match RTL FIFO word layout)
