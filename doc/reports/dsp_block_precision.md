# ECP5-25K DSP Architecture and Fragment Pipeline Fixed-Point Precision

## Technical Report for pico-gs GPU Project

---

## 1. ECP5 DSP Block Architecture: Can a Single Block Perform Dual 9x9 Multiplications?

### Hardware Architecture

The ECP5 sysDSP architecture is documented in Lattice's [FPGA-TN-02205 (sysDSP User Guide)](https://labfiles.zubax.com/lattice/FPGA-TN-02205-1-3-ECP5-and-ECP5-5G-sysDSP-User-Guide.pdf) and the [ECP5 Family Data Sheet (DS1044 / FPGA-DS-02012)](https://www.latticesemi.com/-/media/LatticeSemi/Documents/DataSheets/ECP5/FPGA-DS-02012-3-4-ECP5-ECP5G-Family-Data-Sheet.ashx?document_id=50461).

Each ECP5 **sysDSP slice** contains:
- Two 18-bit pre-adders with registers
- **Two 18-bit multipliers** (the MULT18X18D primitives)
- Input registers and pipeline registers
- One **ALU54B** (54-bit ternary adder/subtractor)
- Output registers

Each slice supports three operating modes:

| Mode | Multiplications per Slice | Total Operand Bits |
|------|--------------------------|-------------------|
| 18x36 | 1 (one wide multiply) | Uses both multipliers cascaded |
| **18x18** | **2 independent** | Each multiplier handles one 18x18 |
| **9x9** | **4 independent** | Each 18x18 multiplier splits into two 9x9 |

**The answer to the primary question is yes**: a single ECP5 DSP slice can perform **four independent 9x9 signed multiplications simultaneously** -- two per physical 18x18 multiplier.
This is a native hardware capability, not a software trick.
Lattice provides the `MULT9X9C` and `MULT9X9D` primitives for direct instantiation of this mode.

The 9x9 mode works by splitting each 18-bit multiplier input into two 9-bit halves.
The 18x18 multiplier can be configured so that its upper and lower 9-bit input/output paths operate independently, producing two separate 18-bit products from two separate 9x9 multiplications.

For 8x8 unsigned multiplications: an 8-bit unsigned value fits within a 9-bit signed container (zero-extend to 9 bits), so **two independent 8x8 unsigned multiplies also pack into a single 18x18 multiplier**, with the 9x9 mode having one spare bit per operand.

### Corrected Resource Count for ECP5-25K

**Important correction**: The user's question states "28 DSP blocks" -- the ECP5-25K (LFE5U-25F) has 28 **sysDSP slices** (one row of DSP).
Each slice contains **two** 18x18 multipliers, giving:

| Mode | Available Multiplications |
|------|--------------------------|
| 18x18 | 28 slices x 2 = **56 multipliers** |
| 9x9 | 28 slices x 4 = **112 multipliers** |
| Mixed | Any combination proportional to above |

This is significantly more DSP resource than the "28 multipliers" assumed in the question.
The existing rasterizer uses 17 MULT18X18D (per the comment in `/workspaces/pico-gs/spi_gpu/src/render/rasterizer.sv`, line 15), which consumes approximately 9 DSP slices (17 multipliers across 9 slices, since each slice provides 2).

### Toolchain Considerations

The open-source toolchain (Yosys + nextpnr) currently infers `MULT18X18D` for multiplications but does **not** automatically pack smaller multiplications into 9x9 mode.
According to the [nextpnr ECP5 primitives documentation](https://github.com/YosysHQ/nextpnr/blob/master/ecp5/docs/primitives.md), only MULT18X18D is listed as supported, and cascade functionality is noted as unsupported.

To use 9x9 mode in the open-source flow, you would need to **manually instantiate** the `MULT9X9D` primitive or use specific Yosys/nextpnr configurations.
Lattice Diamond supports MULT9X9C/MULT9X9D natively.
This is a practical limitation that affects the design choice.

---

## 2. Fixed-Point Format Comparison

### Format Options Analyzed

| Format | Total Bits | Integer | Fraction | Fits in 18x18? | Fits in 9x9? | Notes |
|--------|-----------|---------|----------|----------------|---------------|-------|
| **10.8** | 18 | 10 (0-1023) | 8 (1/256) | Yes, exactly | No | Current design. 2-bit headroom above 255 |
| **9.9** | 18 | 9 (0-511) | 9 (1/512) | Yes, exactly | No | More fractional precision, less headroom |
| **8.8** | 16 | 8 (0-255) | 8 (1/256) | Yes (2 bits spare) | No (needs 16 bits, 9x9 gives 9) | No overflow headroom |
| **1.8** | 9 | 1 (0-1) | 8 (1/256) | Two per multiplier | **Yes, fits 9x9** | Normalized [0,1] only |
| **0.8** | 8 | 0 | 8 (1/256) | Two per multiplier | Yes (1 bit spare) | Unsigned fraction only |
| **1.7** | 8 | 1 (0-1) | 7 (1/128) | Two per multiplier | Yes (1 bit spare) | Normalized, less precision |

### Key Insight: 9x9 Mode is for Normalized [0,1] Arithmetic

The 9x9 mode accommodates **9-bit signed** values, which means a range of [-256, +255] or, more usefully for graphics, an **unsigned 8-bit value** (0-255) zero-extended to 9 bits.
This maps naturally to **normalized color values** in [0, 255] or fractional weights in [0.0, 1.0) with 8 fractional bits.

The critical realization is:
- **Colors** (R, G, B, A) are inherently 8-bit unsigned values (0-255) at their source and destination
- **Blend factors** (alpha, interpolation weights) are 8-bit fractions representing [0.0, 1.0)
- A 9-bit signed container holds an unsigned 8-bit value perfectly: `{1'b0, value[7:0]}`

So the question is really about whether the **intermediate** precision of 10.8 (with its 2-bit overflow headroom) is necessary, or whether 8-bit integers with 8-bit fractional precision suffice.

---

## 3. Impact on Color Precision

### The Destination: RGB565

The framebuffer is RGB565 with per-channel precision of:
- Red: 5 bits (32 levels)
- Green: 6 bits (64 levels)
- Blue: 5 bits (32 levels)

After the pipeline, the 10.8 values are truncated to R5G6B5 (as seen in `/workspaces/pico-gs/spi_gpu/src/render/rasterizer.sv`, lines 637-640):

```systemverilog
fb_wdata <= {16'h0000,
             interp_r[7:3],    // R5
             interp_g[7:2],    // G6
             interp_b[7:3]};   // B5
```

### Precision Analysis for (A-B)*C+D

The color combiner equation is `(A - B) * C + D` applied per channel.
Let us trace the precision requirements:

**Step 1: Subtraction (A - B)**
- If A and B are 8-bit unsigned [0, 255], then (A - B) ranges from [-255, +255], which is a 9-bit signed value.
- In 10.8 format: 18-bit signed subtraction, result is 18-bit signed. No precision loss.

**Step 2: Multiplication by C**
- C is a blend factor, also a color value in [0, 255] representing [0.0, 1.0) where 255 = ~1.0.
- `(A - B) * C` where both are 9-bit signed values: the product is 18-bit signed.
- In 10.8 format: 18-bit x 18-bit = 36-bit product. Shift right by 8 to normalize, giving a 28-bit result that must be clamped back to 18 bits.

The multiply is where precision matters.
Consider the worst case:
- A=255, B=0, C=128 (half intensity): `255 * 128 = 32640`. Shifted right by 8: `127.5`. At 8-bit fraction, this is exactly representable. At 7-bit fraction, the 0.5 would be rounded.

**Step 3: Addition of D**
- Adding a second color value. The sum can overflow the 8-bit integer range (max 510 for two max values), requiring either a 9-bit result or saturation.

### Banding Analysis

The question is whether 8-bit fractional precision introduces visible banding when the output is only RGB565.

**8 fractional bits** provide 256 sub-levels between each integer step.
When truncating to 5-bit output (32 levels from 256 input levels), each output step spans 8 input levels.
The 8-bit fraction gives 256 sub-positions within each input integer, meaning the effective interpolation precision is 8 + 8 = 16 bits mapping to 5-6 output bits.
This is more than sufficient.

**Comparison**: The Nintendo 64 RDP uses **9-bit signed** intermediate precision for its identical `(A-B)*C+D` color combiner, as documented in the [Angrylion RDP reference implementation](https://emudev.org/2021/09/21/Angrylion_RDP_Comments.html).
The N64 outputs to a 16-bit framebuffer (RGBA5551) -- very close to this project's RGB565.
The N64's 9-bit signed precision is considered sufficient for its visual quality, and the pico-gs pipeline targets a similar output format.

**With ordered dithering** (which this pipeline includes per UNIT-006 Stage 6), even fewer intermediate bits would suffice.
Dithering distributes quantization error spatially, effectively adding ~1-2 bits of perceived precision.
This means even 6-7 fractional bits would produce visually acceptable results with dithering enabled.

**Conclusion**: 8 fractional bits are more than adequate for RGB565 output with dithering.
The N64 proved this with a nearly identical architecture.
Going to 9 fractional bits provides no visible benefit for this output format.

---

## 4. DSP Budget Analysis

### Current Rasterizer DSP Usage

From `/workspaces/pico-gs/spi_gpu/src/render/rasterizer.sv` (lines 11-15):

```
// Multiplier strategy:
//   Setup uses a shared pair of 11x11 multipliers, sequenced over 6 cycles
//   (edge C coefficients + initial edge evaluation). Per-pixel interpolation
//   uses 15 dedicated multipliers (3 bary weights + 9 color + 3 Z).
//   Total: 2 (shared setup) + 15 (per-pixel) = 17 MULT18X18D.
```

Breakdown:
- **2 MULT18X18D** (shared, time-multiplexed): Edge function C coefficients and initial edge evaluation (11x11 signed, fits in 18x18)
- **3 MULT18X18D**: Barycentric weight computation (`e * inv_area`, 16x16 unsigned)
- **9 MULT18X18D**: Color interpolation (`weight * color`, 17x8, three channels x three vertices)
- **3 MULT18X18D**: Z interpolation (`weight * depth`, 17x16)
- **Total**: 17 MULT18X18D = approximately **9 DSP slices** (17 multipliers, 2 per slice, so 9 slices with one multiplier unused)

### Projected Full Pipeline DSP Budget

| Pipeline Stage | Operation | Multiplications | Size | DSP Slices (18x18 mode) | DSP Slices (9x9 mode) |
|---------------|-----------|----------------|------|------------------------|----------------------|
| **Rasterizer** | Edge setup (shared) | 2 | 11x11 | 1 | 1 (could use 9x9 but 11>9) |
| **Rasterizer** | Barycentric weights | 3 | 16x16 | 2 | 2 (needs 18x18) |
| **Rasterizer** | Color interpolation | 9 | 17x8 | 5 | 3 (if 9x9: 8-bit color x 8-bit weight portion) |
| **Rasterizer** | Z interpolation | 3 | 17x16 | 2 | 2 (needs 18x18) |
| **Bilinear filter** (x2 samplers) | Weighted average (4 taps x RGBA x 2) | 32 | 8x8 or 9x8 | 16 | 4 (nine 8x8 per slice!) |
| **Color combiner** | (A-B)*C per RGBA | 4 | 9x9 signed | 2 | 1 |
| **Alpha blend** | src*a + dst*(1-a) per RGB | 6 | 9x8 | 3 | 2 |
| **Total** | | | | **~31 slices** | **~15 slices** |

### Analysis: 18x18 Mode Only

With 28 DSP slices (56 MULT18X18D), an 18x18-only approach gives 56 multipliers.
The estimated ~31 slices (62 multipliers) for the full pipeline would be tight -- consuming essentially all DSP resources with very little margin.
However, not all these multiplies happen simultaneously in a pipelined design; some stages can time-share multipliers since they operate on different clock cycles.

### Analysis: 9x9 Mode for Fragment Processing

The 9x9 mode provides enormous savings for **color-channel operations** where operands are 8 bits or less:

**Bilinear texture filtering** is the biggest beneficiary.
A bilinear filter computes:
```
result = (1-fx)*(1-fy)*T00 + fx*(1-fy)*T10 + (1-fx)*fy*T01 + fx*fy*T11
```
Each multiplication is `weight[7:0] * texel_channel[7:0]` -- a pure 8x8 unsigned multiply.
With 4 taps, 4 channels (RGBA), and 2 samplers, that is 32 multiplications.
In 18x18 mode, this requires 16 DSP slices.
In 9x9 mode (4 multiplies per slice), it requires only **8 slices** -- or even fewer if the bilinear is computed sequentially per channel.

**Color combiner** `(A-B)*C`: The subtraction produces a 9-bit signed value, and C is 8-bit unsigned (9-bit signed container).
This is a 9x9 signed multiply -- **perfect for the 9x9 DSP mode**.
Four channels (RGBA) need 4 multiplies = **1 DSP slice**.

**Alpha blending** `src*alpha + dst*(1-alpha)`: Six 9x8 multiplies.
These fit in 9x9 mode.
6 multiplies = **2 DSP slices** (with 2 multiplies spare).

### Budget Summary with Mixed Mode

| Component | DSP Slices (mixed 18x18 + 9x9) |
|-----------|-------------------------------|
| Rasterizer setup (11x11) | 1 (18x18 mode) |
| Barycentric weights (16x16) | 2 (18x18 mode) |
| Color interpolation (17x8) | 5 (18x18; could be reduced) |
| Z interpolation (17x16) | 2 (18x18 mode) |
| Bilinear filter x2 (8x8) | 4-8 (9x9 mode) |
| Color combiner (9x9) | 1 (9x9 mode) |
| Alpha blend (9x8) | 2 (9x9 mode) |
| **Total** | **17-21 of 28 slices** |

This leaves **7-11 DSP slices** free for future features (DOT3 bump mapping, UV coordinate transforms, etc.) or for reducing pipeline latency by parallelizing currently time-shared operations.

---

## 5. Recommendation

### Keep 10.8 Fixed-Point as the Pipeline-Wide Format

The current 10.8 (18-bit) format should be **retained** as the primary pipeline format for these reasons:

1. **It exactly fills the 18x18 DSP multiplier.** Using a smaller format like 8.8 (16 bits) does not save DSP resources in 18x18 mode -- you still consume one MULT18X18D per multiplication. You would just waste 2 bits of each operand.

2. **The 2-bit integer headroom is valuable.** The combiner equation `(A-B)*C+D` can produce intermediate values above 255 (e.g., `(255-0)*1.0 + 255 = 510`). With 10 integer bits (range 0-1023), the pipeline can defer saturation to the final output stage rather than clamping at every intermediate step. This avoids cumulative clamping artifacts that degrade visual quality.

3. **10.8 is the natural N64-style choice.** The project's architecture is explicitly inspired by the N64 RDP. The N64 uses 9-bit signed intermediates for its combiner, which is functionally equivalent to 10.8 unsigned with a sign bit. The 10.8 format maps directly to the same precision class.

### Use 9x9 Mode for Color-Only DSP Operations

For pipeline stages that operate exclusively on 8-bit color channels, **manually instantiate 9x9 DSP mode** to maximize resource utilization:

- **Bilinear texture filtering**: All operands are 8-bit (texel channels and fractional UV weights). Pack 4 multiplies per slice. This is the single largest DSP savings.
- **Color combiner multiply**: `(A-B)` is 9-bit signed, `C` is 8-bit unsigned in 9-bit signed container. Perfect 9x9 fit.
- **Alpha blending multiplies**: 8-bit color times 8-bit alpha. Perfect 9x9 fit.

### Do Not Change to 9.9 or 8.8

- **9.9** sacrifices 1 bit of integer headroom (range 0-511 instead of 0-1023) for 1 extra fractional bit that provides zero visible benefit at RGB565 output. The existing 8 fractional bits already provide 256 sub-steps per integer level, which is far more than the 32-64 output levels can reveal.

- **8.8** eliminates all overflow headroom, forcing immediate saturation after every addition. This is acceptable for simple modulate (`TEX * COLOR`) but causes quality loss in chained operations and add-specular (`TEX * VER_COLOR0 + VER_COLOR1`). The N64 deliberately chose wider-than-8-bit intermediates for this reason.

### Practical Implementation Strategy

1. **Rasterizer (UNIT-005)**: Keep current 18x18 multipliers. The 17-bit barycentric weights and 16-bit Z values require the full 18x18 width. The 11x11 edge setup multipliers already fit. No changes needed.

2. **Bilinear texture filter (new, in UNIT-006)**: Use MULT9X9D primitives. Four taps times 4 channels = 16 multiplies. At 4 per slice, this is 4 DSP slices for one sampler, 8 for two. If pipelined across 2 cycles (2 taps per cycle), halve to 4 slices total.

3. **Color combiner (UNIT-010)**: Use MULT9X9D for the `(A-B)*C` multiply. The subtraction and addition are in LUT logic. 4 channels = 4 multiplies = 1 DSP slice.

4. **Alpha blender**: Use MULT9X9D. 6 multiplies (3 channels x 2 terms) = 2 DSP slices.

5. **Keep 10.8 on the datapath wires between stages**: All inter-stage signals remain 18-bit (10.8). The 9x9 multiplies operate on the lower 9 bits of each 18-bit operand; the result is extended back to 18 bits before passing downstream. This avoids format conversion overhead while exploiting the 9x9 DSP packing where it fits.

### Important Toolchain Caveat

The Yosys open-source synthesis tool currently infers only MULT18X18D for ECP5.
To use 9x9 mode, you must **manually instantiate** MULT9X9D primitives in the RTL.
This trades portability for resource efficiency.
Given that this project already targets a specific FPGA (ECP5-25K on ICEpi Zero v1.3) and is unlikely to be ported to another architecture, manual instantiation is a reasonable trade-off.

If using Lattice Diamond, the MULT9X9C and MULT9X9D primitives are fully supported and can be instantiated or inferred normally.

### Summary Table

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pipeline format | **10.8 fixed-point (18-bit)** | Exact DSP width match, overflow headroom, N64-proven |
| Fractional bits | **8** | Exceeds RGB565 output needs, sufficient for (A-B)*C+D |
| Rasterizer DSPs | 18x18 mode | Operands exceed 9 bits (17-bit weights, 16-bit Z) |
| Bilinear filter DSPs | **9x9 mode** | 8-bit texels x 8-bit weights, 4x packing benefit |
| Combiner multiply DSPs | **9x9 mode** | 9-bit signed x 9-bit signed, perfect fit |
| Alpha blend DSPs | **9x9 mode** | 8-bit color x 8-bit alpha |
| Estimated total DSP slices | **17-21 of 28** | Leaves 25-39% headroom for future features |

---

## Sources

- [ECP5 and ECP5-5G sysDSP User Guide (FPGA-TN-02205-1.3)](https://labfiles.zubax.com/lattice/FPGA-TN-02205-1-3-ECP5-and-ECP5-5G-sysDSP-User-Guide.pdf)
- [ECP5 and ECP5-5G Family Data Sheet (FPGA-DS-02012-3.4)](https://www.latticesemi.com/-/media/LatticeSemi/Documents/DataSheets/ECP5/FPGA-DS-02012-3-4-ECP5-ECP5G-Family-Data-Sheet.ashx?document_id=50461)
- [ECP5 Family Data Sheet (DS1044, preliminary)](https://www.mouser.com/catalog/specsheets/lattice_ECP5.pdf)
- [Multiplication with FPGA DSPs - Project F](https://projectf.io/posts/multiplication-fpga-dsps/)
- [nextpnr ECP5 Primitives Documentation](https://github.com/YosysHQ/nextpnr/blob/master/ecp5/docs/primitives.md)
- [Yosys MULT18X18D/ALU54B Parameter Fix PR #2730](https://github.com/YosysHQ/yosys/pull/2730)
- [Angrylion RDP Comments - N64 Color Combiner Precision](https://emudev.org/2021/09/21/Angrylion_RDP_Comments.html)
- [N64brew Wiki - Reality Coprocessor](https://n64brew.dev/wiki/Reality_Coprocessor)
- [Lattice ECP5 Family Overview - FPGAkey](https://www.fpgakey.com/lattice-family/ecp5-family)
- [LFE5U-25F-6BG256C Specifications - FPGAkey](https://www.fpgakey.com/lattice-parts/lfe5u-25f-6bg256c)
