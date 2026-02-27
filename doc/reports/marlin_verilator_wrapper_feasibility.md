# Technical Report: Marlin as Verilator Wrapper Feasibility

Date: 2026-02-27
Status: Draft

## Background

This investigation was prompted by a desire to **standardize the project's simulation and test infrastructure on Rust**, replacing the current C++ test harnesses that wrap Verilator.
The project currently has two C++ applications that interface with Verilator:

1. **Integration test harness** (`spi_gpu/tests/harness/`) — drives golden image tests (VER-010 through VER-013) via SPI bit-banging, behavioral SDRAM model, PNG output, and pixel-exact comparison.
2. **Interactive GPU simulator** (`spi_gpu/sim/gpu_sim.cpp`, UNIT-037) — SDL3 live display with Lua 5.4 scripting via sol2, command injection through `SIM_DIRECT_CMD` ports, and backpressure-aware register writes.

[Marlin](https://github.com/ethanuppal/marlin) (v0.11.1) is a Rust crate that wraps Verilator, allowing hardware modules to be instantiated as Rust structs and tested via standard `cargo test`.
The question is whether Marlin could replace direct Verilator/C++ usage for both test harnesses while keeping Lua 5.4 for interactive scripting.

## Scope

### Questions investigated

1. Can Marlin replace the C++ golden image test harness (SDRAM model, SPI transactions, command scripts, PNG comparison)?
2. Can Marlin wrap Verilator while still supporting the interactive Lua scripting interface?
3. Is Marlin mature enough and does it support the Verilator features this project requires?
4. What is the migration surface — how much C++ needs Rust equivalents?
5. Is there a viable alternative approach to achieve Rust standardization without Marlin?

### Out of scope

- Effort estimation or timeline
- Jupyter notebook evaluation (noted as a future possibility, Lua 5.4 retained for now)
- Changes to RTL or specification documents

## Investigation

### 1. Current Verilator usage and features required

The project's Verilator configuration (`spi_gpu/verilator.f`, `verilator_sim.f`) uses these flags:

| Flag | Purpose | Critical? |
|------|---------|-----------|
| `--trace-fst` + `--trace-structs` | FST waveform output (compressed) | Yes |
| `--timing` | SystemVerilog timing constructs | Yes |
| `--assert` | SystemVerilog assertions | Yes |
| `--pins-inout-enables` | Split inout `sdram_dq` into `_in`/`_out`/`_en` | Yes |
| `+define+SIM_DIRECT_CMD` | Enable sim-only command injection ports | Yes (sim) |
| `-Wall -Wno-fatal` | Lint warnings | Nice to have |
| `--x-assign unique` / `--x-initial unique` | X-propagation for uninitialized signals | Important |
| `-j 0` | Parallel compilation | Nice to have |

Additionally, the project makes **heavy use of internal signal access** via `/* verilator public */` annotations on ~30+ internal wires and registers.
These are accessed through the Verilated model's `rootp` pointer to reach deep into the design hierarchy:

- `top->rootp->gpu_top->u_rasterizer->state` (FSM state)
- `top->rootp->gpu_top->u_rasterizer->x0`, `y0`, `r0`, `g0`, `b0` (vertex data)
- `top->rootp->gpu_top->disp_enable`, `disp_pixel_red/green/blue` (pixel tap)
- `top->rootp->gpu_top->sim_cmd_valid/addr/wdata` (command injection)
- `top->rootp->gpu_top->fifo_wr_almost_full` (backpressure)

This deep signal access is used for:

- **Diagnostics** in the golden image harness (rasterizer state tracking, SDRAM write counts, edge test counts)
- **Pixel capture** in the interactive simulator (reading display controller RGB output)
- **Command injection** in the interactive simulator (writing to `SIM_DIRECT_CMD` ports)
- **Backpressure monitoring** (both harness and sim check `fifo_wr_almost_full`)

### 2. Marlin capabilities and API

**Version:** 0.11.1 (released 2026-02-27, same day as this report)
**License:** MPL-2.0
**Maturity:** 91 GitHub stars, 8 contributors, 142 commits, ~1 year old (first release 2025-02-09)
**Rust edition:** 2024 (minimum Rust 1.85)

**Core API:**

- `VerilatorRuntime::new(artifact_dir, source_files, include_dirs, dpi_functions, options)` — creates the runtime
- `runtime.create_model_simple::<Module>()` — instantiates a model via proc macro
- `runtime.create_dyn_model(...)` — instantiates a model with runtime port specification
- Model signals accessed as struct fields: `model.clk = 1`, `let val = model.output`
- `model.eval()` — evaluate combinational logic
- DPI support: `#[verilog::dpi]` macro for calling Rust from Verilog
- VCD tracing: `model.open_vcd("file.vcd")`, `model.dump_vcd(time)`
- Wide signals: `WideIn`/`WideOut` types for signals >64 bits

**Configuration available:**

- `VerilatorRuntimeOptions`: `verilator_executable`, `force_verilator_rebuild`, `log` (3 fields only)
- `VerilatedModelConfig`: `verilator_optimization` (0–3), `ignored_warnings`, `enable_tracing`, `cxx_standard`

### 3. Marlin compatibility gaps

| Required feature | Marlin support | Severity |
|-----------------|---------------|----------|
| Internal signal access (`rootp->...`) | **Not supported** — only top-level ports | **Blocker** |
| FST tracing (`--trace-fst`) | **Not supported** — VCD only (open issue #120) | **Blocker** |
| `--pins-inout-enables` (SDRAM inout) | **Not supported** — no custom flag mechanism | **Blocker** |
| `--timing` | **Not supported** — no custom flag mechanism | **Blocker** |
| `--assert` | **Not supported** — no custom flag mechanism | **High** |
| `+define+SIM_DIRECT_CMD` | **Not supported** — no custom flag mechanism | **Blocker** (sim) |
| `--x-assign unique` / `--x-initial unique` | **Not supported** — no custom flag mechanism | **Medium** |
| Custom Verilator flags | **Not available** — `VerilatorRuntimeOptions` has no `extra_args` field | **Blocker** |
| `Send + Sync` for multi-threaded use | **Not supported** — `VerilatorRuntime` is `!Send + !Sync` | **High** (sim) |

**The fundamental issue:** Marlin's `VerilatorRuntimeOptions` and `VerilatedModelConfig` provide no mechanism for passing arbitrary Verilator command-line flags.
Every project-critical feature (`--timing`, `--assert`, `--trace-fst`, `--pins-inout-enables`, `+define+...`, `--x-assign`) requires custom flags that Marlin cannot pass through.

**The internal signal access gap is equally fundamental.**
Marlin generates struct fields only for top-level ports.
There is no `rootp` equivalent, no hierarchical signal path API, and no evidence this is planned.
The project accesses 30+ internal signals for diagnostics, pixel capture, and command injection — all of which would be inaccessible through Marlin.

### 4. Lua integration: mlua as sol2 replacement

Regardless of Marlin, the Lua scripting layer can be ported from C++ (sol2) to Rust.
[mlua](https://github.com/mlua-rs/mlua) v0.11.5 is a mature Rust crate for Lua bindings:

- **Lua 5.4 support:** Full support via `lua54` feature flag
- **Vendored builds:** `vendored` feature compiles Lua from source (no system dependency)
- **Custom Lua functions:** `lua.create_function(|_, args| { ... })` — direct equivalent of sol2's lambda registration
- **Thread safety:** Optional `Send + Sync` via `send` feature flag
- **Async support:** Optional async/await for coroutine integration
- **Maturity:** Well-established fork of rlua, actively maintained, widely used

The current sol2 Lua API surface is small:

- `gpu.write_reg(addr, data)` — enqueue a register write
- `gpu.wait_vsync()` — block until next vsync

These two functions plus the `gpu_regs.lua` helper library (535 lines, pure Lua) represent the entire C++/Lua interface.
Porting this to Rust/mlua would be straightforward — the Lua script side (`gpu_regs.lua`) would remain unchanged.

### 5. Migration surface (C++ to Rust)

The C++ code that would need Rust equivalents:

| File | Lines | Purpose |
|------|-------|---------|
| `harness.cpp` | ~1046 | Clock helpers, SDRAM connection, SPI bit-bang, command execution, framebuffer extraction, diagnostics |
| `sdram_model.cpp/hpp` | ~100 | Behavioral SDRAM (flat array, 16M words) |
| `sdram_model_sim.cpp/hpp` | ~100 | Interactive sim SDRAM variant |
| `png_writer.cpp/hpp` | ~80 | RGB565 → PNG output |
| `gpu_sim.cpp` | ~712 | SDL3 display, Lua/sol2 integration, SDRAM pin-level connection, command injection, vsync |
| **Total** | **~2040** | |

All of this C++ is "glue code" — it interfaces between Verilator's C++ model and the test logic.
None of it is algorithmically complex; the main challenge is correctly interfacing with the Verilated model's C++ API from Rust.

### 6. Alternative approach: Rust + direct Verilator FFI

Instead of Marlin, a more viable path to Rust standardization would be:

1. **Build integration:** Use Rust's `cc` crate (or `cmake` crate) in a `build.rs` to invoke Verilator and compile the Verilated model as a static library with all required flags.
2. **FFI bindings:** Use `bindgen` or `cxx` to generate Rust bindings to the Verilated model's C++ API, including `rootp` access.
3. **Lua scripting:** Use `mlua` with `lua54` + `vendored` features to embed Lua 5.4.
4. **Display:** Use the `sdl2` crate (Rust SDL2 bindings) or `minifb` for the interactive simulator window.
5. **PNG output:** Use the `png` crate (pure Rust PNG encoder).

This approach provides:

- **Full Verilator flag control** — the `build.rs` invokes Verilator directly
- **Internal signal access** — `bindgen`/`cxx` can expose the full `rootp` hierarchy
- **FST tracing** — use Verilator's native `VerilatedFstC`
- **Threading flexibility** — control the threading model directly
- **No dependency on a young, evolving wrapper** — direct FFI is stable

**Risks of this approach:**

- `bindgen`/`cxx` with Verilator's generated C++ headers can be complex (templates, auto-generated classes)
- Maintaining FFI bindings as the RTL design evolves (port changes regenerate headers)
- The `rootp` struct layout is Verilator-internal and changes with the design

## Findings

### Finding 1: Marlin is not currently viable for this project

Marlin has **five independent blocker-level gaps** that prevent adoption:
no custom Verilator flags, no internal signal access, no FST tracing, no inout port splitting, and no SV define injection.
These are not edge cases — they reflect fundamental architectural choices in Marlin (simplicity-first, top-level-ports-only).

Even if Marlin added a `verilator_args: Vec<String>` field tomorrow, the internal signal access gap would remain a separate, deeper problem requiring proc-macro changes to parse `verilator public` annotations and generate hierarchical access paths.

### Finding 2: mlua is a viable sol2 replacement

The `mlua` crate is a mature, well-maintained Rust equivalent of sol2 with full Lua 5.4 support.
The existing Lua script (`gpu_regs.lua`) would require **zero changes** — only the two C++ callback functions (`write_reg` and `wait_vsync`) need Rust equivalents.
This is the lowest-risk, highest-value component of a potential Rust migration.

### Finding 3: Direct Verilator FFI is the viable Rust path

A `build.rs`-based approach that invokes Verilator directly and uses `bindgen`/`cxx` for FFI is the realistic way to achieve Rust standardization.
This preserves full control over Verilator flags, internal signal access, and threading while moving the harness/sim code from C++ to Rust.

The main complexity is in the FFI layer itself — Verilator generates substantial C++ headers with deep class hierarchies.
A pragmatic approach would be to write a thin C wrapper around the Verilated model's critical access points (signal read/write, eval, trace) and use `bindgen` on the C wrapper rather than the full C++ headers.

### Finding 4: The migration is incremental

The two harnesses (golden image + interactive sim) are independent codebases.
A Rust migration could proceed in phases:

- **Phase 1:** Port `mlua` integration and SDRAM model to Rust (highest Rust-native benefit, simplest)
- **Phase 2:** Port the golden image harness (simpler — single-threaded, no SDL/Lua)
- **Phase 3:** Port the interactive simulator (most complex — multi-threaded, SDL, Lua, pixel capture)

Each phase is independently valuable and testable.

### Finding 5: Marlin is worth watching

Marlin is only 1 year old and iterating rapidly (0.1.0 → 0.11.1 in 12 months).
If it adds custom Verilator flag support and internal signal access in a future release, it could become viable.
The project's DPI support is already interesting — it could replace the `verilator public` + `rootp` pattern by exposing internal signals via DPI functions called from Rust, which would be cleaner and more portable.

## Conclusions

**Q1: Can Marlin replace the golden image harness?**
No, not currently.
The harness requires `--pins-inout-enables`, `--timing`, `--assert`, `--trace-fst`, and extensive internal signal access — none of which Marlin supports.

**Q2: Can Marlin support the interactive Lua simulator?**
No.
In addition to the above gaps, the simulator requires `+define+SIM_DIRECT_CMD`, internal signal access for pixel capture and command injection, and multi-threaded operation (`VerilatorRuntime` is `!Send + !Sync`).

**Q3: Is Marlin mature enough?**
For simple unit-test-style verification of small modules with only top-level ports, yes.
For a project of this complexity with behavioral models, internal diagnostics, and custom Verilator flags, no.

**Q4: What's the migration surface?**
~2040 lines of C++ across 6 files.
All glue code — no complex algorithms.
The main challenge is the FFI boundary with Verilator's generated C++.

**Q5: Is there a viable alternative?**
Yes.
Direct Verilator FFI via `build.rs` + `bindgen`/`cxx`, combined with `mlua` for Lua scripting and the `png`/`sdl2` crates for output, achieves Rust standardization without depending on Marlin's abstraction limitations.

### What remains uncertain

- How well `bindgen` handles Verilator 5.x generated headers (may need a thin C wrapper)
- Whether Marlin will add custom flag support in a future release (worth monitoring)
- Whether a DPI-based approach could replace `verilator public` for internal signal access (cleaner but would require RTL changes)

## Recommendations

1. **Do not adopt Marlin at this time.**
   The compatibility gaps are fundamental and would require significant upstream changes.

2. **Consider a direct-FFI Rust migration** as a future project, starting with the golden image harness (Phase 2 above).
   Use `build.rs` + `bindgen` or a thin C wrapper for the Verilator interface.

3. **Monitor Marlin's development** — if it adds arbitrary Verilator flag passthrough and internal signal access, reassess.
   Subscribe to issue #120 (FST tracing) as a maturity indicator.

4. **If migrating, start with mlua** — porting the sol2 Lua integration to `mlua` is low-risk and independently valuable.
   The `gpu_regs.lua` script needs zero changes; only the two C++ callback functions need Rust equivalents.

5. **If a future syskit change touches the harness/sim architecture**, use `/syskit-impact` with this report as context to evaluate whether to incorporate Rust migration into the change.
