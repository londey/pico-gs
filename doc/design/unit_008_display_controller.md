# UNIT-008: Display Controller

## Purpose

Scanline FIFO and display pipeline

## Implements Requirements

- REQ-005.01 (Framebuffer Management) — area 5: Blend/Frame Buffer Store
- REQ-006.01 (Display Output) — area 6: Screen Scan Out
- REQ-005.06 (Framebuffer Format) — area 5: Blend/Frame Buffer Store
- REQ-006.02 (Display Output Timing) — area 6: Screen Scan Out
- REQ-006.03 (Color Grading LUT) — area 6: Screen Scan Out

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map) — FB_DISPLAY, FB_DISPLAY_SYNC
- INT-011 (SDRAM Memory Layout) — Framebuffer data, Color grading LUT data

### Internal Interfaces

- Reads framebuffer pixels from SDRAM via UNIT-007 (Memory Arbiter) display port (highest priority), using burst requests for sequential scanline reads
- Receives display base address and buffer swap commands from UNIT-003 (Register File)
- Receives color grading LUT data and control from UNIT-003
- Drives UNIT-009 (DVI TMDS Encoder) with RGB888 pixel data and sync signals
- Generates vsync signal consumed by host firmware for frame synchronization

## Design Description

### Inputs

- Framebuffer pixel data (RGB565) from SDRAM via scanline FIFO
- Register state: FB_DISPLAY (includes framebuffer address, LUT address, color grading enable)
- LUT data from SDRAM (384 bytes via DMA at vsync trigger)
- Display timing signals (hsync, vsync, pixel clock at 25.000 MHz)

### Outputs

- RGB888 pixel data to UNIT-009 (DVI TMDS Encoder)
- Display sync signals (hsync, vsync, data enable)

### Internal State

- Scanline FIFO (prefetch buffer for display scanout)
- Scanline prefetch FSM state (PREFETCH_IDLE, PREFETCH_BURST, PREFETCH_DONE)
- Burst read address register (auto-incrementing within scanline)
- Burst remaining counter (16-bit words remaining in current burst)
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

1. **Framebuffer Read**: Fetch RGB565 pixels from SDRAM at FB_DISPLAY address via burst reads, buffered through scanline FIFO
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

**Scanline Prefetch with Burst Reads (v11.0):**

The scanline prefetch FSM reads framebuffer data from SDRAM into the scanline FIFO.
Each scanline of 640 RGB565 pixels requires 1280 bytes (640 × 16-bit words).
The prefetch FSM issues burst read requests to UNIT-007 (Memory Arbiter) to read multiple sequential 16-bit words per arbiter grant, reducing arbitration overhead.

Prefetch FSM states:
```
PREFETCH_IDLE:
  - Wait for scanline FIFO to fall below the refill threshold
  - Latch next read address from current framebuffer base + scanline offset
  - Transition to PREFETCH_BURST

PREFETCH_BURST:
  - Assert port0_req with port0_burst_len set to burst length (number of sequential 16-bit words)
  - Address auto-increments within the SDRAM controller for each beat of the burst
  - On each port0_ack: push received data into scanline FIFO, decrement remaining burst count
  - When burst completes (remaining count == 0):
    * If scanline FIFO is full or scanline read complete: transition to PREFETCH_IDLE
    * If more data needed and FIFO has space: issue next burst (remain in PREFETCH_BURST)

PREFETCH_DONE:
  - All pixels for current scanline have been prefetched
  - Wait for next scanline boundary, then transition to PREFETCH_IDLE
```

The burst length is determined by the memory arbiter's maximum burst length (defined in UNIT-007 and INT-011).
Because the display port has the highest arbiter priority, burst requests are never preempted mid-burst.
The scanline FIFO depth must accommodate at least one full burst plus SDRAM access latency (row activate + CAS delay) to prevent underrun; the synchronous 4:1 clock relationship between clk_core and clk_pixel provides 4 SDRAM cycles per pixel consumed, giving substantial prefetch margin even with SDRAM latency.

**Burst vs. Single-Word Comparison:**
- Single-word mode: each SDRAM read requires a full arbitration cycle (request, grant, row activate + CAS latency, ack) — higher overhead per word than burst mode
- Burst mode: first word has the same setup cost, but subsequent words in the burst require only 1 cycle each (address auto-increments, no re-arbitration)
- For a burst of N 16-bit words: burst mode completes in approximately (row activate + CAS latency + N) cycles vs. single-word mode requiring full access setup per word
- Display scanout at 640 pixels per line benefits substantially because the entire scanline is a sequential address range

**LUT DMA Burst Support (v11.0):**

The LUT DMA controller also uses burst reads when loading 384 bytes from SDRAM during vblank.
The 192 sequential 16-bit SDRAM reads are issued as burst requests, reducing the DMA transfer time compared to single-word mode, though the practical impact is minimal since the vblank period is ~1.43 ms.

**LUT Auto-Load Protocol (v9.0):**
1. Host prepares LUT data in SDRAM (384 bytes at 4KiB-aligned address)
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
     - Request SDRAM reads from LUT base address (MEDIUM priority)
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
- At 25.000 MHz pixel clock, each pixel period is 40.0 ns
- The unified 100 MHz GPU core/SDRAM clock (`clk_core`) provides exactly 4 cycles per pixel period (synchronous 4:1 ratio)
- The scanline FIFO between the memory arbiter (clk_core domain) and display output (clk_pixel domain) uses a **synchronous 4:1 clock domain crossing** rather than an asynchronous FIFO, since clk_pixel = clk_core / 4 (derived by integer division)
- This synchronous relationship eliminates gray-code pointer CDC logic and simplifies timing closure
- Burst reads reduce the average SDRAM cycles per pixel for display scanout, freeing more bandwidth for rendering (framebuffer writes, Z-buffer access, texture fetches) on lower-priority arbiter ports
- LUT adds 2 pipeline cycles (1 EBR read + 1 sum) — fits within pixel period

## Implementation

- `spi_gpu/src/display/display_controller.sv`: Main implementation
- `spi_gpu/src/display/color_grade_lut.sv`: Color grading LUT module (REQ-006.03)

## Verification

- Testbench for color grading LUT: verify identity LUT produces unchanged output
- **Testbench for LUT DMA auto-load** (v9.0):
  - Verify 384-byte transfer from SDRAM to inactive EBR bank
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
- **DMA priority verification** (v9.0): Verify memory arbiter grants MEDIUM priority to LUT DMA
- **Scanline burst read verification** (v11.0):
  - Verify prefetch FSM issues burst requests to memory arbiter port 0
  - Verify address auto-increments correctly within burst (sequential 16-bit words)
  - Verify burst read data is correctly pushed into scanline FIFO in order
  - Verify prefetch FSM transitions to PREFETCH_IDLE when FIFO is full
  - Verify no FIFO underrun during active display with burst reads enabled
  - Verify burst reads do not cross scanline address boundaries
- **LUT DMA burst read verification** (v11.0):
  - Verify LUT DMA uses burst requests for the 192 sequential 16-bit SDRAM reads
  - Verify LUT DMA burst completes within vblank period

**Estimated FPGA Resources (v11.0):**
- Color grading LUT: 1 EBR block (dual-bank, 128 entries × 24 bits per bank, 512×36 EBR config)
- Summation + saturation logic: ~230 LUTs
- **LUT DMA Controller** (v9.0):
  - DMA state machine: ~80 FFs
  - Address counters + byte alignment: ~60 LUTs
  - SDRAM request logic: ~40 LUTs
  - Total DMA addition: ~180 LUTs, ~80 FFs
- **Scanline prefetch burst support** (v11.0):
  - Prefetch FSM state register: ~10 FFs
  - Burst address counter: ~30 FFs
  - Burst remaining counter: ~10 FFs
  - Burst request logic: ~20 LUTs
  - Total burst addition: ~70 LUTs, ~50 FFs
- Scanline FIFO: 1 EBR block (1024×16, inferred as DP16KD)
- **Total (v11.0)**: 2 EBR, ~520 LUTs, ~230 FFs

## Design Notes

Migrated from speckit module specification.

**Boot Screen Interaction (DD-019):**
The display controller begins scanout immediately after PLL lock and reset release.
The pre-populated command FIFO boot sequence (UNIT-002) sets FB_DISPLAY to Framebuffer A as its final command, completing in ~0.18 us at 100 MHz.
Since the display controller's first full frame scanout begins after PLL lock and VGA timing initialization (~16.7 ms for the first vsync), the boot screen rendering completes well before the first frame is scanned out.
This ensures the display shows the boot screen (black background with RGB triangle) rather than uninitialized SDRAM contents.
Note: the boot sequence rasterization of the screen-clear and RGB triangle takes additional time beyond the FIFO drain (dependent on triangle pixel count), but still completes within the first frame period.

**Clock Domain Architecture:**
The display controller operates across two synchronous clock domains:
- `clk_core` (100 MHz): SDRAM reads, scanline prefetch, LUT DMA, register interface
- `clk_pixel` (25 MHz): VGA timing generation, pixel output to TMDS encoder (UNIT-009)

Since clk_pixel = clk_core / 4 (synchronous integer division from the same PLL), the scanline FIFO uses a synchronous 4:1 clock domain crossing.
This is simpler and more reliable than the asynchronous CDC that would be required if the clocks were from independent sources.

**Version History:**
- v5.0: Added color grading LUT with register-based upload (REQ-006.03)
- v9.0: Replaced register-based LUT upload with memory-based auto-load DMA
  - Reduces SPI traffic from 128+ register writes to 1 register write
  - Enables atomic framebuffer + LUT switch
  - LUT DMA completes in ~2µs during 1.43ms vblank period
  - See DD-014 for rationale
- v10.0: Documented boot screen timing interaction with pre-populated FIFO (DD-019)
- v11.0: Added burst read support for scanline prefetch and LUT DMA
  - Scanline prefetch FSM issues burst requests to memory arbiter for sequential pixel reads
  - Reduces display scanout SDRAM bandwidth consumption by eliminating per-word re-arbitration overhead
  - Frees SDRAM bandwidth for rendering operations on lower-priority arbiter ports
  - LUT DMA also uses burst reads for reduced transfer time
  - See INT-011 for burst timing model and UNIT-007 for arbiter burst grant protocol
- v12.0: Updated all references from async SRAM to SDRAM (W9825G6KH)
  - Scanline FIFO depth guidance updated to account for SDRAM access latency (row activate + CAS delay)
  - Burst timing descriptions updated for SDRAM characteristics
