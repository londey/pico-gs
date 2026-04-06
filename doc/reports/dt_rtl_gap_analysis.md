# Digital Twin / RTL Gap Analysis

Date: 2026-04-06

This report identifies gaps between the digital twin (DT) and RTL implementations across two areas:
pipeline stall propagation and DT-to-RTL completeness mismatches.

## 1. Pipeline Stall Propagation

The RTL pipeline uses valid/ready handshaking between stages.
The DT is transaction-level and does not model any of this.
Below is the status of each link in the stall chain.

### 1.1 Rasterizer -> Pixel Pipeline: COMPLETE

- `frag_valid`/`frag_ready` handshake at rasterizer output and pixel_pipeline input.
- `frag_ready` is driven by pixel_pipeline when FSM is in `PP_IDLE` ([pixel_pipeline.sv:837](components/pixel-write/rtl/src/pixel_pipeline.sv#L837)).
- Rasterizer holds iteration when `frag_ready` is deasserted.

### 1.2 Texture Sampler Stall: IMPLICIT

- On cache miss, pixel_pipeline FSM holds at `PP_TEX_LOOKUP` waiting for `tc_cache_ready` ([pixel_pipeline.sv:995](components/pixel-write/rtl/src/pixel_pipeline.sv#L995)).
- While the FSM is stalled, `frag_ready` is deasserted (FSM not in `PP_IDLE`), so the rasterizer is implicitly back-pressured.
- There is no dedicated "texture stall" signal — backpressure works through the FSM state machine.

### 1.3 Color Combiner Backpressure: COMPLETE

- `out_ready` input to color_combiner is driven by pixel_pipeline's `cc_in_ready` output ([pixel_pipeline.sv:844](components/pixel-write/rtl/src/pixel_pipeline.sv#L844), [gpu_top.sv:1169](integration/gpu_top.sv#L1169), [gpu_top.sv:1345](integration/gpu_top.sv#L1345)).
- `pipeline_enable = out_ready` gates all pipeline register advances ([color_combiner.sv:149](components/color-combiner/rtl/src/color_combiner.sv#L149)).
- Pixel pipeline asserts `cc_in_ready` only when in `PP_CC_WAIT` state, preventing color combiner from advancing when pixel pipeline isn't ready.

### 1.4 Pixel Write -> SDRAM Arbiter: COMPLETE

- `fb_ready` from sram_arbiter port 1 gates the `PP_WRITE` state ([pixel_pipeline.sv:942-957](components/pixel-write/rtl/src/pixel_pipeline.sv#L942)).
- Arbiter drives `port1_ready` based on `mem_ready` from SDRAM controller ([gpu_top.sv:370-372](integration/gpu_top.sv#L370)).

### 1.5 Z-Buffer Cache Stall: COMPLETE

- `cache_ready` is deasserted during evict/fill/lazy-fill states ([zbuf_tile_cache.sv:628](components/zbuf/rtl/src/zbuf_tile_cache.sv#L628)).
- Pixel pipeline `PP_Z_READ` and `PP_Z_WRITE` states gate on `zbuf_ready` ([pixel_pipeline.sv:889-894](components/pixel-write/rtl/src/pixel_pipeline.sv#L889)).

### 1.6 Overall Stall Chain: COMPLETE

The full chain from SDRAM back to rasterizer is connected:

```
SDRAM mem_ready -> sram_arbiter -> fb_ready -> pixel_pipeline (PP_WRITE)
SDRAM mem_ready -> sram_arbiter -> zbuf_ready -> pixel_pipeline (PP_Z_*)
pixel_pipeline FSM != PP_IDLE -> frag_ready=0 -> rasterizer stalls
color_combiner out_ready <- pixel_pipeline cc_in_ready (PP_CC_WAIT)
```

All backpressure paths are wired.
The DT models none of this, which is correct — these are hardware implementation concerns.
The gap is not in the RTL wiring but in the DT's inability to predict timing-related issues like sustained cache miss penalties or arbitration starvation.

## 2. DT-to-RTL Completeness

### 2.1 DT Stubs (RTL Complete)

These components have fully implemented RTL but the DT is a stub/passthrough:

| Component | DT Status | RTL Status | Lines to Implement |
|-----------|-----------|------------|-------------------|
| alpha-blend | Returns input unchanged | 4 blend modes, Q4.12 saturation | ~80 |
| dither | Direct Q4.12->RGB565 truncation | 16x16 Bayer matrix, per-channel offset | ~50 |
| stipple | Always passes fragment | Bitmask lookup + discard | ~20 |

**Impact:** Per-module Verilator verification against DT vectors is blocked for these three components.
Integration golden image tests still work because the test scenes may not exercise these features, or the DT's passthrough behavior coincidentally matches the rendering.

### 2.2 Fully Aligned

| Component | Notes |
|-----------|-------|
| rasterizer | DT mirrors RTL sub-module boundaries; DT-verified testbenches pass |
| color-combiner | Two-stage (A-B)*C+D logic matches; DT-verified testbenches pass |
| early-z | Both combinational; identical Z compare encodings |
| pixel-write | Excellent alignment; 8 DT unit tests |
| zbuf | Cache algorithm matches; RTL adds EBR timing details (appropriate) |
| texture (all subunits) | L1/L2 cache geometry, block decoder, bilinear filter all aligned |

### 2.3 Intentional Differences (Correct)

| Component | DT Scope | RTL Scope | Reason |
|-----------|----------|-----------|--------|
| display | Color grade + H-scale | + DVI/TMDS PHY | PHY not simulable in Rust |
| memory | Flat 32 MiB + tiled addressing | + SDRAM controller + arbiter | Timing is Verilator's job |
| spi | Register decode + vertex assembly | + SPI PHY + command FIFO | PHY is structural |

## 3. Recommended Actions

### Priority 1: Implement DT Stubs

1. **stipple** (~20 lines): `discard = stipple_en && !stipple_pattern[y[2:0] * 8 + x[2:0]]`
2. **dither** (~50 lines): Bayer matrix lookup, per-channel offset, add before truncation
3. **alpha-blend** (~80 lines): dst read from memory, RGB565->Q4.12 promotion, 4 blend modes

These unblock per-module verification for three pipeline stages.

### Priority 2: Strengthen Verilator Testbenches

Focus on the areas where the DT gave misleading expectations:
- **Sustained texture cache miss scenarios** — test sequences that thrash the L1/L2 caches
- **SDRAM arbitration under contention** — simultaneous display scanout + texture fills + Z-buffer evicts
- **Pipeline stall propagation end-to-end** — verify that backpressure correctly stalls the rasterizer under all combinations

### Priority 3: Keep DT and RTL in Sync

Establish a practice of updating both together.
When RTL adds a feature, add the corresponding DT logic (or at minimum update the TODO comment with what's missing).
