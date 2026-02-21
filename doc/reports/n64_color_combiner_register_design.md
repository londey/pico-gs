# Redesigning the GPU Color Combiner to Match the N64 RDP Fixed-Function Fragment Pipeline

## Technical Report: Register Layout and Pipeline Analysis

---

## 1. N64 RDP Color Combiner Deep Dive

### 1.1 The Core Equation

The N64 Reality Display Processor (RDP) color combiner implements the equation:

```
RGB_out = (A_rgb - B_rgb) * C_rgb + D_rgb
Alpha_out = (A_alpha - B_alpha) * C_alpha + D_alpha
```

RGB and alpha are computed independently with **separate input source muxes** for each of A, B, C, D.
This single equation is deceptively powerful: by choosing the right inputs, it can express multiply, add, subtract, linear interpolation (lerp), fog, modulation, and multi-texture blending.

### 1.2 RGB Combiner Input Sources

Each slot (A, B, C, D) for the **RGB** combiner has a **different set** of available inputs.
This is a critical detail the N64 exploits for bit-packing efficiency:

**RGB A (4-bit field, values 0-7, 8+ = 0):**

| Value | Source | Description |
|-------|--------|-------------|
| 0 | COMBINED | Output of cycle 0 (2-cycle mode only) |
| 1 | TEX0 | Texture 0 color |
| 2 | TEX1 | Texture 1 color |
| 3 | PRIMITIVE | Primitive color register (constant per-primitive) |
| 4 | SHADE | Interpolated per-vertex shade color |
| 5 | ENVIRONMENT | Environment color register (constant) |
| 6 | 1 | Constant 1.0 |
| 7 | NOISE | Per-pixel random noise |
| 8-15 | 0 | Constant 0.0 |

**RGB B (4-bit field, values 0-7, 8+ = 0):**

| Value | Source | Description |
|-------|--------|-------------|
| 0 | COMBINED | Output of cycle 0 |
| 1 | TEX0 | Texture 0 color |
| 2 | TEX1 | Texture 1 color |
| 3 | PRIMITIVE | Primitive color register |
| 4 | SHADE | Shade color |
| 5 | ENVIRONMENT | Environment color register |
| 6 | CENTER | Chroma key center |
| 7 | K4 | YUV conversion constant |
| 8-15 | 0 | Constant 0.0 |

**RGB C (5-bit field, values 0-15, 16+ = 0):**

| Value | Source | Description |
|-------|--------|-------------|
| 0 | COMBINED | Output of cycle 0 |
| 1 | TEX0 | Texture 0 color |
| 2 | TEX1 | Texture 1 color |
| 3 | PRIMITIVE | Primitive color register |
| 4 | SHADE | Shade color |
| 5 | ENVIRONMENT | Environment color register |
| 6 | SCALE | Chroma key scale |
| 7 | COMBINED_ALPHA | Combined alpha (scalar) broadcast to RGB |
| 8 | TEX0_ALPHA | Texture 0 alpha broadcast to RGB |
| 9 | TEX1_ALPHA | Texture 1 alpha broadcast to RGB |
| 10 | PRIMITIVE_ALPHA | Primitive alpha broadcast to RGB |
| 11 | SHADE_ALPHA | Shade alpha broadcast to RGB |
| 12 | ENV_ALPHA | Environment alpha broadcast to RGB |
| 13 | LOD_FRACTION | Computed LOD fraction (for mipmap blending) |
| 14 | PRIM_LOD_FRAC | Primitive LOD fraction (software-controlled) |
| 15 | K5 | YUV conversion constant |
| 16-31 | 0 | Constant 0.0 |

The C slot (the multiplier input) has the widest selection because it is the "blending factor" -- it needs access to all the alpha channels as scalar blend factors, plus LOD fractions for mipmap interpolation.

**RGB D (3-bit field, values 0-6, 7 = 0):**

| Value | Source | Description |
|-------|--------|-------------|
| 0 | COMBINED | Output of cycle 0 |
| 1 | TEX0 | Texture 0 color |
| 2 | TEX1 | Texture 1 color |
| 3 | PRIMITIVE | Primitive color register |
| 4 | SHADE | Shade color |
| 5 | ENVIRONMENT | Environment color register |
| 6 | 1 | Constant 1.0 |
| 7 | 0 | Constant 0.0 |

### 1.3 Alpha Combiner Input Sources

The alpha combiner has a **more restricted** set of inputs (no NOISE, no chroma key, no alpha-broadcast-to-alpha, no K4/K5):

**Alpha A (3-bit field):**

| Value | Source |
|-------|--------|
| 0 | COMBINED |
| 1 | TEX0 |
| 2 | TEX1 |
| 3 | PRIMITIVE |
| 4 | SHADE |
| 5 | ENVIRONMENT |
| 6 | 1 |
| 7 | 0 |

**Alpha B (3-bit field):** Same as Alpha A.

**Alpha C (3-bit field):**

| Value | Source |
|-------|--------|
| 0 | LOD_FRACTION |
| 1 | TEX0 |
| 2 | TEX1 |
| 3 | PRIMITIVE |
| 4 | SHADE |
| 5 | ENVIRONMENT |
| 6 | PRIM_LOD_FRAC |
| 7 | 0 |

Note: Alpha C slot 0 is LOD_FRACTION (not COMBINED), and slot 6 is PRIM_LOD_FRAC (not 1).
This is deliberately different from the RGB C slot.

**Alpha D (3-bit field):** Same as Alpha A.

### 1.4 N64 SET_COMBINE_MODE Bit Packing

The N64 packs **both cycles** of the combiner into a single 64-bit command word.
The field widths are non-uniform because different slots have different numbers of valid sources:

```
Word 0 (bits 63:32):
  [55:52] RGB_A_0     (4 bits)  -- Cycle 0 RGB A
  [51:47] RGB_C_0     (5 bits)  -- Cycle 0 RGB C
  [46:44] ALPHA_A_0   (3 bits)  -- Cycle 0 Alpha A
  [43:41] ALPHA_C_0   (3 bits)  -- Cycle 0 Alpha C
  [40:37] RGB_A_1     (4 bits)  -- Cycle 1 RGB A
  [36:32] RGB_C_1     (5 bits)  -- Cycle 1 RGB C

Word 1 (bits 31:0):
  [31:28] RGB_B_0     (4 bits)  -- Cycle 0 RGB B
  [27:24] RGB_B_1     (4 bits)  -- Cycle 1 RGB B
  [23:21] ALPHA_A_1   (3 bits)  -- Cycle 1 Alpha A
  [20:18] ALPHA_C_1   (3 bits)  -- Cycle 1 Alpha C
  [17:15] RGB_D_0     (3 bits)  -- Cycle 0 RGB D
  [14:12] ALPHA_B_0   (3 bits)  -- Cycle 0 Alpha B
  [11:9]  ALPHA_D_0   (3 bits)  -- Cycle 0 Alpha D
  [8:6]   RGB_D_1     (3 bits)  -- Cycle 1 RGB D
  [5:3]   ALPHA_B_1   (3 bits)  -- Cycle 1 Alpha B
  [2:0]   ALPHA_D_1   (3 bits)  -- Cycle 1 Alpha D
```

**Total bits consumed**: 4+5+3+3+4+5 + 4+4+3+3+3+3+3+3+3+3 = 24 + 32 = **56 bits** for both cycles.
The N64 manages to pack two full combiner configurations into 56 bits by exploiting the asymmetric source counts per slot.

### 1.5 One-Cycle vs Two-Cycle Mode

**1-Cycle Mode**: The pipeline processes one pixel per clock at 62.5 MHz.
Only the **cycle 1** (second cycle) combiner settings are used.
The COMBINED input is ill-defined (reads previous pixel's output).
The software SDK macro `gDPSetCombineMode(mode1, mode2)` sets both cycle 0 and cycle 1, and in 1-cycle mode, both should be set to the same value.

**2-Cycle Mode**: The pipeline processes one pixel per **two** clocks at 62.5 MHz (effectively 31.25 Mpix/s).
Both combiner stages execute sequentially:
- **Cycle 0**: Computes an intermediate result. COMBINED input reads the previous pixel's output (effectively zero/undefined for the first pixel).
- **Cycle 1**: Computes the final result. The COMBINED input now reads the output of **cycle 0 for the same pixel**.

Common 2-cycle patterns:
- **Mipmap LOD blend**: Cycle 0 blends TEX0 and TEX1 using LOD_FRACTION as C; Cycle 1 modulates the COMBINED result with SHADE.
- **Fog**: Cycle 0 computes lit/textured color; Cycle 1 blends COMBINED toward FOG_COLOR using a fog factor.
- **Highlight/specular**: Cycle 0 computes diffuse; Cycle 1 adds specular from ENVIRONMENT.

---

## 2. Two-Cycle Mode Pipelining Analysis

### 2.1 The Data Dependency Problem

In 2-cycle mode, cycle 1 can read COMBINED, which is the output of cycle 0 **for the same pixel**.
This creates a true read-after-write (RAW) data dependency:

```
Cycle 0 (pixel N):   result_0 = (A0 - B0) * C0 + D0
Cycle 1 (pixel N):   result_1 = (A1 - B1) * C1 + D1
                                  ^-- A1 or B1 or C1 or D1 may be COMBINED = result_0
```

### 2.2 Can It Be Pipelined to 1 Pixel/Clock?

**Yes, with pipeline forwarding.**
The key insight is that the (A-B)*C+D equation, when implemented in hardware, decomposes into:

```
Stage 1 (1 clock): sub_result = A - B          (subtraction, free in fabric)
Stage 2 (1 clock): mul_result = sub_result * C  (DSP multiply)
Stage 3 (1 clock): final      = mul_result + D  (post-adder, absorbed into DSP)
```

In a **physically pipelined** implementation with two combiner units:

```
Clock N:     Combiner0 processes pixel N (stage 1: A0-B0)
Clock N+1:   Combiner0 completes pixel N (stage 2-3: *C0+D0, output = COMBINED_N)
             Combiner1 needs COMBINED_N for pixel N (stage 1: A1-B1, may need COMBINED_N)
```

**The dependency is on the COMBINED output from combiner 0, which feeds into the A, B, C, or D mux of combiner 1 for the same pixel.**
If combiner 0 takes 1 clock to produce its result (sub+mul+add in a single DSP pipeline stage), then combiner 1 can begin on the **next** clock with the forwarded value.
This achieves **1 pixel per clock** with a pipeline depth of 2.

However, there is a subtlety: if the DSP multiply itself requires multiple pipeline stages for timing closure at the target frequency, the forwarding path gets longer.

### 2.3 ECP5 DSP Pipeline Timing

Each ECP5 MULT18X18D has optional input and output pipeline registers.
At a typical GPU clock of 25-50 MHz on ECP5-25K:

- **At 25 MHz** (pixel clock for 640x480): An 18x18 multiply completes combinationally within one clock period, or with a single output register.
  The (A-B)*C+D can be computed in **1 clock** using the DSP's pre-adder for (A-B) and the post-adder for +D.
- **At 50 MHz**: May need 1 pipeline register in the DSP, meaning the multiply takes 2 clocks.
  Forwarding still works but requires 2-stage pipeline per combiner.

### 2.4 Recommended Pipeline Architecture

For a hobby GPU targeting 25 MHz pixel clock:

```
             Clock N          Clock N+1         Clock N+2
Combiner 0:  pixel N          pixel N+1         pixel N+2
             (A0-B0)*C0+D0    (A0-B0)*C0+D0     ...
                    |
                    v (forward COMBINED)
Combiner 1:                   pixel N            pixel N+1
                              (A1-B1)*C1+D1      ...
```

**Result**: 1 pixel/clock throughput, 2-clock latency.
The forwarding path from combiner 0's output register directly feeds combiner 1's input mux.
No pipeline bubble.

**Critical requirement**: The COMBINED mux input to combiner 1 must be wired to the registered output of combiner 0, not a feedback from combiner 1's own output (which would create a combinational loop).

### 2.5 Simplified Alternative: Time-Multiplexed Single Combiner

Instead of two physical combiners, a single combiner could execute both cycles sequentially at **2 clocks per pixel** by latching the cycle 0 result and reconfiguring the mux selects:

```
Clock N:     Single combiner processes cycle 0 for pixel N
Clock N+1:   Single combiner processes cycle 1 for pixel N (reads latched COMBINED)
```

**Tradeoff**: Half the pixel throughput but half the DSP usage (4 DSPs instead of 8).
For a 640x480@60 GPU at 25 MHz with ~20,000 clocks per scanline, this may still be adequate depending on fill rate requirements.

---

## 3. DSP Budget Analysis for ECP5-25K

### 3.1 Available Resources

The ECP5-25K (LFE5U-25F) contains:
- **28 sysDSP slices**, each containing **2 MULT18X18D** primitives
- **56 total 18x18 multipliers**
- Each slice supports: one 18x36, two 18x18, or four 9x9 multiplies
- Each MULT18X18D has optional input registers, output register, and can be cascaded

### 3.2 Current Rasterizer DSP Usage

From `/workspaces/pico-gs/spi_gpu/src/render/rasterizer.sv` (lines 11-15):

```
// Setup uses a shared pair of 11x11 multipliers, sequenced over 6 cycles
// (edge C coefficients + initial edge evaluation). Per-pixel interpolation
// uses 15 dedicated multipliers (3 bary weights + 9 color + 3 Z).
// Total: 2 (shared setup) + 15 (per-pixel) = 17 MULT18X18D.
```

Breakdown:
- **Setup phase** (shared, time-multiplexed): 2 MULT18X18D for edge function C coefficients
- **Barycentric weight computation**: 3 MULT18X18D (w0, w1, w2 = edge * inv_area)
- **Color interpolation**: 9 MULT18X18D (3 channels x 3 weights: w0*r0, w1*r1, w2*r2, etc.)
- **Z interpolation**: 3 MULT18X18D (w0*z0 + w1*z1 + w2*z2)
- **Current total**: 17 MULT18X18D

### 3.3 Full Pipeline DSP Budget Estimate

| Pipeline Stage | DSPs (MULT18X18D) | Notes |
|---|---|---|
| **Rasterizer (current)** | 17 | Edge setup (2 shared) + barycentric (3) + color interp (9) + Z interp (3) |
| **Texture sampling (bilinear)** | 0-8 | Bilinear: 4 lerps/channel, but can use 9x9 mode or LUT. Point sampling: 0 |
| **Color combiner (1-cycle)** | 4 | R, G, B, A: each needs 1 multiply for (A-B)*C |
| **Color combiner (2-cycle pipelined)** | 8 | Two physical combiners x 4 channels |
| **Alpha blending** | 4 | src*alpha + dst*(1-alpha): 4 channels x 1 multiply each |
| **TOTAL (1-cycle combiner)** | 25-33 | Fits in 28 slices (56 multipliers) |
| **TOTAL (2-cycle combiner)** | 29-37 | Fits in 28 slices (56 multipliers) |

### 3.4 Budget Assessment

With **56 available MULT18X18D** primitives:

- **1-cycle combiner (4 DSPs)**: Total pipeline ~25-33 DSPs. Comfortable margin of 23-31 DSPs remaining.
  **Recommended for initial implementation.**
- **2-cycle pipelined combiner (8 DSPs)**: Total pipeline ~29-37 DSPs.
  Still fits with 19-27 DSPs remaining for future features.
- **Texture bilinear filtering** may use 9x9 mode (packing 2 lerps per MULT18X18D) or shift-and-add for 8-bit channels, potentially requiring fewer DSPs than the worst case.

**Conclusion**: Both 1-cycle and 2-cycle combiner implementations fit within the ECP5-25K DSP budget.
The 2-cycle pipelined approach consumes only 4 additional DSPs over the 1-cycle design while doubling combiner flexibility.

### 3.5 Optimization: DSP Absorption of Sub and Add

The ECP5 MULT18X18D can absorb the pre-subtraction (A-B) and post-addition (+D) into the DSP fabric when properly configured:

- **Pre-adder**: (A-B) computed inside the DSP slice, saving fabric LUTs
- **Post-adder**: +D computed using the DSP accumulator or cascade output
- **Net effect**: Each combiner channel uses exactly 1 MULT18X18D, no additional fabric resources for the arithmetic

This means the (A-B)*C+D equation maps **perfectly** to one DSP per channel.

---

## 4. Proposed Register Layout

### 4.1 Design Decisions for the Hobby GPU

Before defining the register layout, several simplifications relative to the full N64 are warranted:

**Sources to keep** (8 sources, fits in 3 bits):

| Value | Source | N64 Equivalent | Justification |
|-------|--------|----------------|---------------|
| 0 | COMBINED | COMBINED | Essential for 2-cycle mode |
| 1 | TEX0 | TEXEL0 | Primary texture |
| 2 | TEX1 | TEXEL1 | Secondary texture / lightmap |
| 3 | SHADE | SHADE | Interpolated vertex color (Gouraud) |
| 4 | MAT_COLOR0 | PRIMITIVE | Per-draw-call constant color |
| 5 | MAT_COLOR1 | ENVIRONMENT | Second constant color |
| 6 | ONE | 1 | Constant 1.0 |
| 7 | ZERO | 0 | Constant 0.0 |

**Sources to drop**:
- **NOISE**: Requires a per-pixel PRNG; niche use case. Can be emulated in software via a noise texture.
- **CENTER, SCALE** (chroma key): Very N64-specific. Not needed for a hobby GPU.
- **K4, K5** (YUV conversion): The hobby GPU uses RGB textures. Not needed.
- **LOD_FRACTION**: Would require automatic LOD computation in the rasterizer. Can add later.
- **PRIM_LOD_FRAC**: Software-set LOD fraction. Can be folded into MAT_COLOR1 alpha.

**Additional RGB C sources** (extended set for the multiply/blend factor slot):

| Value | Source | Justification |
|-------|--------|---------------|
| 8 | TEX0_ALPHA | Texture alpha as blend factor (common: alpha-test decals) |
| 9 | TEX1_ALPHA | Lightmap alpha as blend factor |
| 10 | SHADE_ALPHA | Vertex alpha as blend factor (per-vertex fog, transparency) |
| 11 | MAT_COLOR0_ALPHA | Material alpha as blend factor |
| 12 | COMBINED_ALPHA | Cycle 0 alpha as RGB blend factor |
| 13-15 | ZERO | Reserved / zero |

This requires 4 bits for the C slot's RGB source.
All other slots fit in 3 bits.

### 4.2 Proposed Register: Single 64-bit CC_MODE (Both Cycles)

Both cycles packed into a single 64-bit register (Option A, recommended):

```
CC_MODE (index 0x18, 64 bits):

  --- Cycle 0 (bits [25:0]) ---
  [2:0]    C0_RGB_A      3 bits
  [5:3]    C0_RGB_B      3 bits
  [9:6]    C0_RGB_C      4 bits
  [12:10]  C0_RGB_D      3 bits
  [15:13]  C0_ALPHA_A    3 bits
  [18:16]  C0_ALPHA_B    3 bits
  [21:19]  C0_ALPHA_C    3 bits
  [24:22]  C0_ALPHA_D    3 bits
  [25]     TWO_CYCLE     1 bit

  --- Cycle 1 (bits [51:26]) ---
  [28:26]  C1_RGB_A      3 bits
  [31:29]  C1_RGB_B      3 bits
  [35:32]  C1_RGB_C      4 bits
  [38:36]  C1_RGB_D      3 bits
  [41:39]  C1_ALPHA_A    3 bits
  [44:42]  C1_ALPHA_B    3 bits
  [47:45]  C1_ALPHA_C    3 bits
  [50:48]  C1_ALPHA_D    3 bits

  [63:51]  RESERVED      13 bits

Total: 51 active bits (26 per cycle + TWO_CYCLE flag - 1 shared bit).
```

This fits within a single 64-bit register.

### 4.3 Proposed SystemRDL

```systemrdl
// Color combiner input sources (RGB A, B, D and all Alpha slots)
enum cc_source_e {
    CC_COMBINED    = 3'd0 { desc = "Cycle 0 output (2-cycle mode); previous pixel (1-cycle)"; };
    CC_TEX0        = 3'd1 { desc = "Texture unit 0 color/alpha"; };
    CC_TEX1        = 3'd2 { desc = "Texture unit 1 color/alpha"; };
    CC_SHADE       = 3'd3 { desc = "Interpolated vertex color/alpha (Gouraud)"; };
    CC_MAT_COLOR0  = 3'd4 { desc = "Material color 0 register"; };
    CC_MAT_COLOR1  = 3'd5 { desc = "Material color 1 register"; };
    CC_ONE         = 3'd6 { desc = "Constant 1.0"; };
    CC_ZERO        = 3'd7 { desc = "Constant 0.0"; };
};

// Extended sources for RGB C slot (blend/multiply factor)
enum cc_rgb_c_source_e {
    CC_C_COMBINED       = 4'd0  { desc = "Cycle 0 RGB output"; };
    CC_C_TEX0           = 4'd1  { desc = "Texture 0 RGB"; };
    CC_C_TEX1           = 4'd2  { desc = "Texture 1 RGB"; };
    CC_C_SHADE          = 4'd3  { desc = "Shade RGB"; };
    CC_C_MAT_COLOR0     = 4'd4  { desc = "Material color 0 RGB"; };
    CC_C_MAT_COLOR1     = 4'd5  { desc = "Material color 1 RGB"; };
    CC_C_ONE            = 4'd6  { desc = "Constant 1.0"; };
    CC_C_ZERO_7         = 4'd7  { desc = "Constant 0.0"; };
    CC_C_TEX0_ALPHA     = 4'd8  { desc = "Texture 0 alpha broadcast to RGB"; };
    CC_C_TEX1_ALPHA     = 4'd9  { desc = "Texture 1 alpha broadcast to RGB"; };
    CC_C_SHADE_ALPHA    = 4'd10 { desc = "Shade alpha broadcast to RGB"; };
    CC_C_MAT0_ALPHA     = 4'd11 { desc = "Material color 0 alpha broadcast to RGB"; };
    CC_C_COMBINED_ALPHA = 4'd12 { desc = "Cycle 0 alpha broadcast to RGB"; };
    CC_C_RSVD_13        = 4'd13 { desc = "Reserved (reads as 0)"; };
    CC_C_RSVD_14        = 4'd14 { desc = "Reserved (reads as 0)"; };
    CC_C_ZERO_15        = 4'd15 { desc = "Constant 0.0"; };
};

reg cc_mode_reg {
    name = "CC_MODE";
    desc = "Color combiner mode: equation (A-B)*C+D, independent RGB and Alpha.
           Supports 1-cycle and 2-cycle modes. In 1-cycle mode, only cycle 0
           fields are used. In 2-cycle mode, cycle 0 output (COMBINED) feeds
           as an input source to cycle 1.";

    // Cycle 0
    field { encode = cc_source_e; }       C0_RGB_A[2:0]     = 0;
    field { encode = cc_source_e; }       C0_RGB_B[5:3]     = 0;
    field { encode = cc_rgb_c_source_e; } C0_RGB_C[9:6]     = 0;
    field { encode = cc_source_e; }       C0_RGB_D[12:10]   = 0;
    field { encode = cc_source_e; }       C0_ALPHA_A[15:13] = 0;
    field { encode = cc_source_e; }       C0_ALPHA_B[18:16] = 0;
    field { encode = cc_source_e; }       C0_ALPHA_C[21:19] = 0;
    field { encode = cc_source_e; }       C0_ALPHA_D[24:22] = 0;
    field {} TWO_CYCLE[25:25] = 0;

    // Cycle 1
    field { encode = cc_source_e; }       C1_RGB_A[28:26]   = 0;
    field { encode = cc_source_e; }       C1_RGB_B[31:29]   = 0;
    field { encode = cc_rgb_c_source_e; } C1_RGB_C[35:32]   = 0;
    field { encode = cc_source_e; }       C1_RGB_D[38:36]   = 0;
    field { encode = cc_source_e; }       C1_ALPHA_A[41:39] = 0;
    field { encode = cc_source_e; }       C1_ALPHA_B[44:42] = 0;
    field { encode = cc_source_e; }       C1_ALPHA_C[47:45] = 0;
    field { encode = cc_source_e; }       C1_ALPHA_D[50:48] = 0;

    field {} RSVD[63:51] = 0;
};
cc_mode_reg CC_MODE @ 0x0C0;  // index 0x18
```

### 4.4 Common Combiner Presets

To validate the register design, here are common rendering modes expressed as register values:

| Effect | C0_RGB (A,B,C,D) | C0_ALPHA (A,B,C,D) | Notes |
|--------|-------------------|---------------------|-------|
| **Textured Gouraud** | TEX0, ZERO, SHADE, ZERO | TEX0, ZERO, SHADE, ZERO | `TEX0 * SHADE` |
| **Solid color** | MAT0, ZERO, ONE, ZERO | MAT0, ZERO, ONE, ZERO | `MAT_COLOR0` |
| **Decal texture** | TEX0, ZERO, ONE, ZERO | TEX0, ZERO, ONE, ZERO | `TEX0` |
| **Texture modulate** | TEX0, ZERO, SHADE, ZERO | TEX0, ZERO, SHADE, ZERO | `TEX0 * SHADE` |
| **Lerp TEX0/TEX1** | TEX0, TEX1, TEX0_ALPHA, TEX1 | TEX0, TEX1, TEX0, TEX1 | `(TEX0-TEX1)*TEX0.a + TEX1` = lerp |
| **Lightmap** | TEX0, ZERO, TEX1, ZERO | TEX0, ZERO, TEX1, ZERO | `TEX0 * TEX1` |
| **Vertex color only** | SHADE, ZERO, ONE, ZERO | SHADE, ZERO, ONE, ZERO | `SHADE` |
| **Fog (2-cycle)** | C0: TEX0,Z,SHADE,Z; C1: COMBINED,MAT1,SHADE_A,MAT1 | ... | Cycle 0: lit; Cycle 1: fog blend |

---

## 5. Comparison with Current Design

### 5.1 Current CC_MODE Register Analysis

The current register at `/workspaces/pico-gs/registers/rdl/gpu_regs.rdl` (lines 176-188):

```systemrdl
reg cc_mode_reg {
    name = "CC_MODE";
    desc = "Color combiner mode: equation (A-B)*C+D, independent RGB and Alpha";
    field {} CC_ALPHA_A[3:0]   = 0;   // 4 bits
    field {} CC_ALPHA_B[7:4]   = 0;   // 4 bits
    field {} CC_ALPHA_C[11:8]  = 0;   // 4 bits
    field {} CC_ALPHA_D[15:12] = 0;   // 4 bits
    field {} CC_A_SOURCE[19:16] = 0;  // 4 bits -- RGB A
    field {} CC_B_SOURCE[23:20] = 0;  // 4 bits -- RGB B
    field {} CC_C_SOURCE[27:24] = 0;  // 4 bits -- RGB C
    field {} CC_D_SOURCE[31:28] = 0;  // 4 bits -- RGB D
    field {} RSVD[63:32]       = 0;
};
```

**Issues with the current design:**

1. **No 2-cycle mode support**: Only 32 bits used, all for a single cycle.
   The reserved upper 32 bits could hold cycle 1, but there is no TWO_CYCLE enable bit.

2. **Uniform 4-bit fields**: All 8 source selectors are 4 bits each.
   This wastes bits on the alpha side (where 3 bits suffice for 8 sources) and is marginally insufficient for the RGB C slot (where the N64 uses 5 bits for 16 sources).
   The 4-bit fields support up to 16 sources, which is actually adequate for the reduced source set proposed in Section 4.1.

3. **No alpha-to-RGB broadcast sources**: The current design lacks the ability to use an alpha channel (e.g., TEX0_ALPHA) as a multiplier for the RGB C slot.
   This is essential for transparency effects, texture alpha masking, and per-vertex alpha fading.

4. **Naming confusion**: The fields are named `CC_A_SOURCE` through `CC_D_SOURCE` (which sound like they could be alpha) alongside `CC_ALPHA_A` through `CC_ALPHA_D`.
   The proposed naming `C0_RGB_A`, `C0_ALPHA_A` is clearer.

5. **No enumeration types**: The current fields lack `encode = ...` type annotations, so the valid source encodings exist only in documentation, not in the RDL itself.

### 5.2 What the N64 Combiner Can Do That the Current Design Cannot

| Capability | N64 RDP | Current pico-gs | Proposed Design |
|-----------|---------|-----------------|-----------------|
| (A-B)*C+D equation | Yes | Yes | Yes |
| Independent RGB/Alpha sources | Yes (different source sets per slot) | Partially (same 4-bit encoding) | Yes (3-bit alpha, 4-bit RGB C) |
| 2-cycle mode | Yes | No | Yes |
| COMBINED feedback | Yes | No | Yes |
| Alpha-to-RGB broadcast (C slot) | Yes (5 sources) | No | Yes (5 sources) |
| NOISE source | Yes | No | No (dropped intentionally) |
| Chroma key (CENTER, SCALE) | Yes | No | No (dropped intentionally) |
| LOD_FRACTION | Yes | No | No (can add later to reserved slots) |
| YUV constants (K4, K5) | Yes | No | No (RGB-only GPU) |

### 5.3 Simplifications Appropriate for This Hobby GPU

1. **Drop NOISE**: Replace with a noise texture if needed. Saves a per-pixel PRNG circuit.
2. **Drop chroma key (CENTER, SCALE)**: N64-specific feature for sprite keying. Modern approach: use alpha testing.
3. **Drop K4, K5 (YUV constants)**: The hobby GPU uses RGB textures natively. No YUV decode path.
4. **Drop LOD_FRACTION initially**: Requires LOD computation in the rasterizer. Reserve encoding slots 13-14 in `cc_rgb_c_source_e` for future LOD_FRACTION and PRIM_LOD_FRAC support.
5. **Unify alpha source sets**: Unlike the N64 where Alpha C slot 0 = LOD_FRACTION (not COMBINED), use the same 8-source encoding for all alpha slots. This simplifies the mux and driver.
6. **8 unified base sources**: The 3-bit `cc_source_e` enum covers COMBINED, TEX0, TEX1, SHADE, MAT_COLOR0, MAT_COLOR1, ONE, ZERO. This is sufficient for the vast majority of N64 combiner modes.

### 5.4 Migration Path

The transition from the current register layout to the proposed one:

1. **Register address unchanged**: CC_MODE stays at index 0x18.
2. **MAT_COLOR0, MAT_COLOR1, FOG_COLOR unchanged**: Indices 0x19, 0x1A, 0x1B remain as-is. MAT_COLOR0 serves the role of N64's PRIMITIVE color; MAT_COLOR1 serves as ENVIRONMENT color.
3. **Breaking change**: The bit field layout changes completely. The driver (`registers/src/lib.rs`) and any consuming RTL must be updated simultaneously.
4. **Backward compatibility**: Not possible without a version bit. Recommend a clean break at the next register map version.

---

## Summary of Recommendations

1. **Adopt the proposed `cc_mode_reg`** with 51 active bits in a single 64-bit register, supporting both 1-cycle and 2-cycle modes with N64-inspired source selection.

2. **Start with 1-cycle combiner in RTL** (4 DSPs).
   This is the most practical first step and covers 90% of rendering use cases (textured Gouraud, modulate, decal, lightmapping, solid color).

3. **Design the RTL with 2-cycle forwarding in mind** so that adding a second physical combiner later requires only instantiating a second combiner unit and wiring the forwarding path.

4. **Budget 4-8 DSPs for the color combiner** out of 56 available MULT18X18D.
   Combined with the rasterizer's 17 DSPs, this leaves 31-35 DSPs for texture filtering and alpha blending.

5. **Reserve `cc_rgb_c_source_e` slots 13-14** for future LOD_FRACTION and PRIM_LOD_FRAC if mipmap LOD computation is added to the rasterizer.

---

## Sources

- [N64brew Wiki: Reality Display Processor Commands (SET_COMBINE_MODE)](https://n64brew.dev/wiki/Reality_Display_Processor/Commands)
- [N64brew Wiki: Reality Display Processor Pipeline](https://n64brew.dev/wiki/Reality_Display_Processor/Pipeline)
- [N64 Programming Manual Chapter 12.6: CC - Color Combiner](https://ultra64.ca/files/documentation/online-manuals/man/pro-man/pro12/index12.6.html)
- [N64 Programming Manual Chapter 12.7: BL - Blender](https://ultra64.ca/files/documentation/online-manuals/man/pro-man/pro12/12-07.html)
- [The RDP as I understand it (Paris Oplopoios)](https://offtkp.github.io/RDP/)
- [Project F: Multiplication with FPGA DSPs (ECP5 details)](https://projectf.io/posts/multiplication-fpga-dsps/)
- [FPGAkey: LFE5U-25F-6BG256C specifications](https://www.fpgakey.com/lattice-parts/lfe5u-25f-6bg256c)
- [Lattice ECP5 and ECP5-5G sysDSP Usage Guide](https://www.latticesemi.com/~/media/LatticeSemi/Documents/ApplicationNotes/EH/TN1267.pdf?document_id=50469)
- [Nintendo 64 Architecture (Copetti)](https://www.copetti.org/writings/consoles/nintendo-64/)
