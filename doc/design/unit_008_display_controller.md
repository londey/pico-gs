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

- INT-010 (GPU Register Map) — FB_DISPLAY, FB_DISPLAY_SYNC
- INT-011 (SRAM Memory Layout) — Framebuffer data, Color grading LUT data

### Internal Interfaces

- Reads framebuffer pixels from SRAM via UNIT-007 (SRAM Arbiter) display port (highest priority)
- Receives display base address and buffer swap commands from UNIT-003 (Register File)
- Receives color grading LUT data and control from UNIT-003
- Drives UNIT-009 (DVI TMDS Encoder) with RGB888 pixel data and sync signals
- Generates vsync signal consumed by host firmware for frame synchronization

## Design Description

### Inputs

- Framebuffer pixel data (RGB565) from SRAM via scanline FIFO
- Register state: FB_DISPLAY (includes framebuffer address, LUT address, color grading enable)
- LUT data from SRAM (384 bytes via DMA at vsync trigger)
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
- **LUT DMA Controller** (v9.0):
  - DMA state machine (IDLE, LOAD_LUT, SWAP_BANK)
  - LUT base address (from FB_DISPLAY[18:6])
  - Byte counter (384 bytes total)
  - EBR write address (0-127 entries)
- Display timing counters (h_count, v_count)

### Algorithm / Behavior

**Display Scanout Pipeline:**

1. **Framebuffer Read**: Fetch RGB565 pixels from SRAM at FB_DISPLAY address, buffered through scanline FIFO
2. **Color Grading LUT** (if FB_DISPLAY[0] COLOR_GRADE_ENABLE=1):
   a. Extract RGB565 components: R5=pixel[15:11], G6=pixel[10:5], B5=pixel[4:0]
   b. Parallel LUT lookups (1 cycle EBR read):
      - `lut_r_out = red_lut[R5]` → RGB888
      - `lut_g_out = green_lut[G6]` → RGB888
      - `lut_b_out = blue_lut[B5]` → RGB888
   c. Sum with saturation (1 cycle combinational) to produce final RGB888:
      - `final_R8 = min(lut_r_out[23:16] + lut_g_out[23:16] + lut_b_out[23:16], 255)`
      - `final_G8 = min(lut_r_out[15:8] + lut_g_out[15:8] + lut_b_out[15:8], 255)`
      - `final_B8 = min(lut_r_out[7:0] + lut_g_out[7:0] + lut_b_out[7:0], 255)`
3. **Bypass Mode** (if FB_DISPLAY[0] COLOR_GRADE_ENABLE=0):
   - Standard RGB565→RGB888 expansion: `R8 = {R5, R5[4:2]}`, `G8 = {G6, G6[5:4]}`, `B8 = {B5, B5[4:2]}`
4. **TMDS Output**: Send RGB888 to DVI encoder (UNIT-009)

**LUT Auto-Load Protocol (v9.0):**
1. Host prepares LUT data in SRAM (384 bytes at 4KiB-aligned address)
2. Host writes FB_DISPLAY or FB_DISPLAY_SYNC with framebuffer address, LUT address, enable flag
3. At vsync edge:
   - If `LUT_ADDR != 0`: Trigger LUT DMA controller
   - If `LUT_ADDR == 0`: Skip LUT load, only switch framebuffer
4. **LUT DMA State Machine:**
   ```
   IDLE:
     - Wait for vsync edge and LUT_ADDR != 0
     - Latch LUT base address from FB_DISPLAY[18:6] << 12
     - Transition to LOAD_LUT

   LOAD_LUT:
     - Request SRAM reads from LUT base address (MEDIUM priority)
     - Read 384 bytes (192 × 16-bit words) sequentially
     - Write to inactive EBR bank:
       * Offsets 0x000-0x05D → Red LUT entries 0-31
       * Offsets 0x060-0x11D → Green LUT entries 0-63
       * Offsets 0x120-0x17D → Blue LUT entries 0-31
     - Each entry: 3 bytes (R[7:0], G[7:0], B[7:0]) packed to RGB888
     - Transfer time: ~1.92µs (192 reads @ 100MHz)
     - Transition to SWAP_BANK when complete

   SWAP_BANK:
     - Swap active/inactive banks atomically
     - Scanout uses newly loaded LUT immediately
     - Transition to IDLE
   ```

**Double-Buffering (Auto-Swap, v9.0):**
- Two banks of LUT storage in EBR (active and inactive)
- DMA writes always go to inactive bank
- Bank swap is automatic after LUT DMA completes
- Scanout always reads from active bank
- Prevents tearing or artifacts during LUT updates
- No explicit SWAP_BANKS control needed (implicit with auto-load)

**Timing Budget:**
- At 25.175 MHz pixel clock, each pixel period is ~39.7 ns
- SRAM clock at 100 MHz provides 4 cycles per pixel period
- LUT adds 2 pipeline cycles (1 EBR read + 1 sum) — fits within pixel period

## Implementation

- `spi_gpu/src/display/display_controller.sv`: Main implementation
- `spi_gpu/src/display/color_grade_lut.sv`: Color grading LUT module (REQ-133)

## Verification

- Testbench for color grading LUT: verify identity LUT produces unchanged output
- **Testbench for LUT DMA auto-load** (v9.0):
  - Verify 384-byte transfer from SRAM to inactive EBR bank
  - Verify correct LUT format parsing (Red[96B] + Green[192B] + Blue[96B])
  - Verify DMA completes within vblank period (~2µs of 1.43ms)
  - Verify LUT_ADDR=0 skips auto-load
- **Testbench for bank swapping** (v9.0):
  - Verify automatic bank swap after DMA completion
  - Verify swap occurs atomically with framebuffer switch
  - Verify no tearing during LUT transition
- Testbench for LUT bypass: verify unchanged RGB565→RGB888 when disabled
- Testbench for cross-channel effects: verify R→G color tinting works correctly
- Testbench for saturation: verify summed outputs clamp to 8-bit max (255)
- Timing verification: LUT adds ≤2 cycles scanout latency, within pixel period
- **DMA priority verification** (v9.0): Verify SRAM arbiter grants MEDIUM priority to LUT DMA

**Estimated FPGA Resources (v9.0):**
- Color grading LUT: 1 EBR block (dual-bank, 128 entries × 24 bits per bank, 512×36 EBR config)
- Summation + saturation logic: ~230 LUTs
- **LUT DMA Controller** (v9.0):
  - DMA state machine: ~80 FFs
  - Address counters + byte alignment: ~60 LUTs
  - SRAM request logic: ~40 LUTs
  - Total DMA addition: ~180 LUTs, ~80 FFs
- **Total (v9.0)**: 1 EBR, ~450 LUTs, ~180 FFs

## Design Notes

Migrated from speckit module specification.

**Version History:**
- v5.0: Added color grading LUT with register-based upload (REQ-133)
- v9.0: Replaced register-based LUT upload with SRAM-based auto-load DMA
  - Reduces SPI traffic from 128+ register writes to 1 register write
  - Enables atomic framebuffer + LUT switch
  - LUT DMA completes in ~2µs during 1.43ms vblank period
  - See DD-014 for rationale
