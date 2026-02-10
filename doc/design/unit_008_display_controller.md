# UNIT-008: Display Controller

## Purpose

Scanline FIFO and display pipeline

## Implements Requirements

- REQ-002 (Framebuffer Management)
- REQ-007 (Display Output)
- REQ-025 (Framebuffer Format)
- REQ-026 (Display Output Timing)
- REQ-133 (Color Grading LUT)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map) — COLOR_GRADE_CTRL, COLOR_GRADE_LUT_ADDR, COLOR_GRADE_LUT_DATA
- INT-011 (SRAM Memory Layout)

### Internal Interfaces

- Reads framebuffer pixels from SRAM via UNIT-007 (SRAM Arbiter) display port (highest priority)
- Receives display base address and buffer swap commands from UNIT-003 (Register File)
- Receives color grading LUT data and control from UNIT-003
- Drives UNIT-009 (DVI TMDS Encoder) with RGB888 pixel data and sync signals
- Generates vsync signal consumed by host firmware for frame synchronization

## Design Description

### Inputs

- Framebuffer pixel data (RGB565) from SRAM via scanline FIFO
- Register state: FB_DISPLAY, COLOR_GRADE_CTRL, COLOR_GRADE_LUT_ADDR, COLOR_GRADE_LUT_DATA
- Display timing signals (hsync, vsync, pixel clock at 25.175 MHz)

### Outputs

- RGB888 pixel data to UNIT-009 (DVI TMDS Encoder)
- Display sync signals (hsync, vsync, data enable)

### Internal State

- Scanline FIFO (prefetch buffer for display scanout)
- Color grading LUT: 3 sub-LUTs in 1 EBR block (512×36 configuration), double-buffered
  - Red LUT: 32 entries × 24 bits (RGB888)
  - Green LUT: 64 entries × 24 bits (RGB888)
  - Blue LUT: 32 entries × 24 bits (RGB888)
- LUT bank select (active/inactive for double-buffering)
- Display timing counters (h_count, v_count)

### Algorithm / Behavior

**Display Scanout Pipeline:**

1. **Framebuffer Read**: Fetch RGB565 pixels from SRAM at FB_DISPLAY address, buffered through scanline FIFO
2. **Color Grading LUT** (if COLOR_GRADE_CTRL.ENABLE=1):
   a. Extract RGB565 components: R5=pixel[15:11], G6=pixel[10:5], B5=pixel[4:0]
   b. Parallel LUT lookups (1 cycle EBR read):
      - `lut_r_out = red_lut[R5]` → RGB888
      - `lut_g_out = green_lut[G6]` → RGB888
      - `lut_b_out = blue_lut[B5]` → RGB888
   c. Sum with saturation (1 cycle combinational) to produce final RGB888:
      - `final_R8 = min(lut_r_out[23:16] + lut_g_out[23:16] + lut_b_out[23:16], 255)`
      - `final_G8 = min(lut_r_out[15:8] + lut_g_out[15:8] + lut_b_out[15:8], 255)`
      - `final_B8 = min(lut_r_out[7:0] + lut_g_out[7:0] + lut_b_out[7:0], 255)`
3. **Bypass Mode** (if COLOR_GRADE_CTRL.ENABLE=0):
   - Standard RGB565→RGB888 expansion: `R8 = {R5, R5[4:2]}`, `G8 = {G6, G6[5:4]}`, `B8 = {B5, B5[4:2]}`
4. **TMDS Output**: Send RGB888 to DVI encoder (UNIT-009)

**LUT Upload Protocol:**
1. Host writes COLOR_GRADE_CTRL[2] (RESET_ADDR)
2. Host writes COLOR_GRADE_LUT_ADDR to select LUT and entry
3. Host writes COLOR_GRADE_LUT_DATA with RGB888 value → written to inactive bank
4. Repeat for all entries
5. Host writes COLOR_GRADE_CTRL[1] (SWAP_BANKS) → banks swap at next vblank

**Double-Buffering:**
- Two banks of LUT storage (active and inactive)
- Firmware writes always go to inactive bank
- SWAP_BANKS triggers bank swap during vertical blanking interval
- Scanout always reads from active bank
- Prevents tearing or artifacts during LUT updates

**Timing Budget:**
- At 25.175 MHz pixel clock, each pixel period is ~39.7 ns
- SRAM clock at 100 MHz provides 4 cycles per pixel period
- LUT adds 2 pipeline cycles (1 EBR read + 1 sum) — fits within pixel period

## Implementation

- `spi_gpu/src/display/display_controller.sv`: Main implementation
- `spi_gpu/src/display/color_grade_lut.sv`: Color grading LUT module (REQ-133)

## Verification

- Testbench for color grading LUT: verify identity LUT produces unchanged output
- Testbench for LUT upload protocol: verify correct write to inactive bank
- Testbench for bank swapping: verify swap occurs at vblank without tearing
- Testbench for LUT bypass: verify unchanged RGB565→RGB888 when disabled
- Testbench for cross-channel effects: verify R→G color tinting works correctly
- Testbench for saturation: verify summed outputs clamp to 8-bit max (255)
- Timing verification: LUT adds ≤2 cycles, within pixel period

**Estimated FPGA Resources:**
- Color grading LUT: 1 EBR block (dual-bank, 128 entries × 24 bits per bank, 512×36 EBR config)
- Summation + saturation logic: ~230 LUTs
- Control FSM (upload, bank swap): ~100 FFs

## Design Notes

Migrated from speckit module specification. Updated for color grading LUT (REQ-133, v5.0).
