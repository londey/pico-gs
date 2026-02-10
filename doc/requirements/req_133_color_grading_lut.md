# REQ-133: Color Grading LUT

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The GPU SHALL support a color grading lookup table applied at display scanout, enabling real-time gamma correction, color temperature adjustment, and artistic color effects without re-rendering.

## Rationale

Post-processing effects like gamma correction and color grading are traditionally applied by re-rendering or using compute shaders. A hardware LUT at scanout provides real-time color transformation with no rendering performance overhead and no wasted work from overdraw.

## Parent Requirements

- REQ-007 (Display Output)

## Allocated To

- UNIT-008 (Display Controller)

## Interfaces

- INT-010 (GPU Register Map) — COLOR_GRADE_CTRL (0x44), COLOR_GRADE_LUT_ADDR (0x45), COLOR_GRADE_LUT_DATA (0x46)
- INT-020 (GPU Driver API) — `gpu_set_color_grade_enable()`, `gpu_upload_color_lut()`

## Functional Requirements

### FR-133-1: LUT Structure

The GPU SHALL implement three independent 1D LUTs for color grading, indexed by the RGB565 framebuffer components:

- **Red LUT:** 32 entries (indexed by R[4:0]), each entry is R5G5B5 (15 bits)
- **Green LUT:** 64 entries (indexed by G[5:0]), each entry is R5G5B5 (15 bits)
- **Blue LUT:** 32 entries (indexed by B[4:0]), each entry is R5G5B5 (15 bits)

Total storage: (32 + 64 + 32) x 15 bits = 1920 bits, fitting in 1 EBR block.

### FR-133-2: LUT Lookup Process

For each scanout pixel, the GPU SHALL:
1. Read RGB565 pixel from framebuffer
2. Extract components: `r5 = pixel[15:11]`, `g6 = pixel[10:5]`, `b5 = pixel[4:0]`
3. Lookup in parallel:
   - `lut_r_out = red_lut[r5]` (returns R5G5B5)
   - `lut_g_out = green_lut[g6]` (returns R5G5B5)
   - `lut_b_out = blue_lut[b5]` (returns R5G5B5)
4. Sum with saturation:
   - `final_r = saturate(lut_r_out[14:10] + lut_g_out[14:10] + lut_b_out[14:10], 5'h1F)`
   - `final_g = saturate(lut_r_out[9:5] + lut_g_out[9:5] + lut_b_out[9:5], 5'h1F)`
   - `final_b = saturate(lut_r_out[4:0] + lut_g_out[4:0] + lut_b_out[4:0], 5'h1F)`
5. Expand final RGB555 to RGB888 for DVI TMDS encoding

### FR-133-3: LUT Upload Protocol

The firmware SHALL upload LUT entries using the following protocol:
1. Write to `COLOR_GRADE_CTRL[2]` (RESET_ADDR) to reset LUT address pointer
2. For each entry:
   - Write to `COLOR_GRADE_LUT_ADDR` to select LUT (00=R, 01=G, 10=B) and entry index
   - Write to `COLOR_GRADE_LUT_DATA` to upload 15-bit entry data (R5G5B5 format)
3. Write to `COLOR_GRADE_CTRL[1]` (SWAP_BANKS) to activate new LUT at next vblank

### FR-133-4: Double-Buffering

The LUT SHALL use two banks:
- Firmware writes update the **inactive** bank
- `SWAP_BANKS` bit swaps banks during vertical blank interval
- Scanout always reads from the **active** bank

This ensures LUT updates do not cause tearing or artifacts during display refresh.

### FR-133-5: Bypass Mode

When `COLOR_GRADE_CTRL[0]` (ENABLE) is 0, the LUT SHALL be bypassed and framebuffer pixels SHALL pass directly to the DVI encoder with standard RGB565→RGB888 expansion. Default state is disabled (bypass).

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- [ ] Upload LUT data via COLOR_GRADE_LUT_ADDR and COLOR_GRADE_LUT_DATA registers
- [ ] Three 1D LUTs with correct entry counts (R:32, G:64, B:32)
- [ ] Each LUT entry is R5G5B5 format (15 bits)
- [ ] LUT lookup indexes by RGB565 component values (R5, G6, B5)
- [ ] LUT outputs are summed with saturation to produce final scanout color
- [ ] LUT applies at scanout (between framebuffer read and DVI encoder)
- [ ] LUT updates are double-buffered (swap during vblank, no tearing)
- [ ] Color grading can be enabled/disabled via COLOR_GRADE_CTRL register
- [ ] Verify identity LUT (each channel maps to itself) produces unchanged output
- [ ] Verify gamma correction curve produces visually correct result
- [ ] Verify color tinting (cross-channel LUT) works correctly
- [ ] Scanout timing unaffected (2 cycle LUT latency within pixel period)

## Notes

The LUT architecture uses three 1D LUTs with RGB outputs (rather than one 3D LUT or three independent per-channel LUTs) to balance flexibility and resource usage. This allows cross-channel effects (e.g., red input influencing green output for color tinting) while fitting in 1 EBR.

Common use cases: gamma correction (linear→sRGB), color temperature adjustment, brightness/contrast/saturation, artistic color grading, fade-to-black effects.

See DD-013 in design_decisions.md for architectural rationale.
