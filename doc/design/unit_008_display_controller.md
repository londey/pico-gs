# UNIT-008: Display Controller

## Purpose

Scanline FIFO and display pipeline

## Implements Requirements

- REQ-005.01 (Framebuffer Management) — area 5: Blend/Frame Buffer Store
- REQ-005.06 (Framebuffer Format) — area 5: Blend/Frame Buffer Store
- REQ-005.09 (Double-Buffered Rendering) — scanout address switches at vsync via FB_DISPLAY
- REQ-006.01 (Display Output) — area 6: Screen Scan Out
- REQ-006.02 (Display Output Timing) — area 6: Screen Scan Out
- REQ-006.03 (Color Grading LUT) — area 6: Screen Scan Out
- REQ-011.01 (Performance Targets) — pixel clock and scanout timing are performance-critical
- REQ-005 (Blend / Frame Buffer Store)
- REQ-006 (Screen Scan Out)

## Interfaces

### Provides

- INT-002 (DVI TMDS Output)

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
- Register state: FB_DISPLAY (includes framebuffer address, LUT address, color grading enable, FB_DISPLAY.FB_WIDTH_LOG2, FB_DISPLAY.LINE_DOUBLE)
- LUT data from SDRAM (384 bytes via DMA at vsync trigger)
- Display timing signals (hsync, vsync, pixel clock at 25.000 MHz)

### Outputs

- RGB888 pixel data to UNIT-009 (DVI TMDS Encoder)
- Display sync signals (hsync, vsync, data enable)

**Simulation-observable pixel tap signals (gpu_top.sv, after the horizontal resize stage):**

| Signal | Width | Description |
|--------|-------|-------------|
| `disp_pixel_red` | 8 | Red channel (RGB888) at display controller output |
| `disp_pixel_green` | 8 | Green channel (RGB888) at display controller output |
| `disp_pixel_blue` | 8 | Blue channel (RGB888) at display controller output |
| `disp_enable` | 1 | Data enable — high during active display region |
| `disp_vsync_out` | 1 | Vertical sync output — rising edge marks frame start |

These signals are the post-LUT, post-color-grading RGB888 values driven into UNIT-009 in hardware.
In the Verilator interactive simulator (UNIT-037), the SDL3 display window reads these signals directly, bypassing UNIT-009 entirely.
UNIT-009 need not be instantiated in the simulation top-level wrapper.

### Internal State

- Scanline FIFO (prefetch buffer for display scanout; depth sized for one full source scanline at maximum FB_WIDTH_LOG2=9, i.e. 512 RGB565 words)
- Scanline prefetch FSM state (PREFETCH_IDLE, PREFETCH_BURST, PREFETCH_DONE)
- Burst read address register (auto-incrementing within source scanline)
- Burst remaining counter (16-bit words remaining in current burst)
- **Horizontal scaler state** (Bresenham accumulator):
  - `h_accum` [9:0]: Bresenham accumulator; initialized to `source_width / 2` at scanline start
  - `h_src_pos` [8:0]: Current source pixel index within scanline FIFO (0 to source_width-1)
  - Scaler advances `h_src_pos` by 1 whenever `h_accum >= 640`; `h_accum` wraps modulo 640 and adds `source_width` on each output pixel
  - `source_width` = `1 << FB_DISPLAY.FB_WIDTH_LOG2`
- **Line doubling state** (LINE_DOUBLE):
  - `line_double_second` [0]: 0 = first emission of source row, 1 = second emission (repeat)
  - When `FB_DISPLAY.LINE_DOUBLE=1`: source row index `v_src = v_count >> 1`; `line_double_second` toggles each output row; source scanline is re-read from FIFO (or from a line buffer) on the repeated row
- Color grading LUT: 3 sub-LUTs in 1 EBR block (512×36 configuration), double-buffered
  - Red LUT: 32 entries × 24 bits (RGB888)
  - Green LUT: 64 entries × 24 bits (RGB888)
  - Blue LUT: 32 entries × 24 bits (RGB888)
- LUT bank select (active/inactive for double-buffering)
- **LUT DMA Controller**:
  - DMA state machine (IDLE, LOAD_LUT, SWAP_BANK)
  - LUT base address (from FB_DISPLAY[18:6])
  - Byte counter (384 bytes total)
  - EBR write address (0-127 entries)
- Display timing counters (h_count, v_count)

### Algorithm / Behavior

**Display Scanout Pipeline:**

1. **Framebuffer Read**: Fetch `1 << FB_DISPLAY.FB_WIDTH_LOG2` RGB565 source pixels per source scanline from SDRAM via burst reads, buffered through scanline FIFO.
   - When `LINE_DOUBLE=0`: source scanline `s = v_count` (480 unique source rows for a 480-line surface, or a subset of the surface for shorter surfaces)
   - When `LINE_DOUBLE=1`: source scanline `s = v_count >> 1` (240 unique source rows; each row is emitted twice to fill 480 display lines without re-reading SDRAM)
2. **Horizontal Scaling** (Bresenham nearest-neighbor, always active):
   - Source width: `source_width = 1 << FB_DISPLAY.FB_WIDTH_LOG2` (e.g. 512 for WIDTH_LOG2=9, 256 for WIDTH_LOG2=8)
   - Output width: always 640 pixels (DVI output requirement, INT-002)
   - Bresenham accumulator: `accum` initialized to `source_width >> 1` at scanline start; each output pixel: emit FIFO[h_src_pos], add `source_width` to `accum`; when `accum >= 640`, advance `h_src_pos` by 1 and subtract 640 from `accum`
   - When `source_width == 640`: scaler passes through 1:1 with no stretching (accumulator always increments h_src_pos by 1)
3. **Color Grading LUT** (if FB_DISPLAY[0] COLOR_GRADE_ENABLE=1):
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

**Scanline Prefetch with Burst Reads:**

The scanline prefetch FSM reads framebuffer data from SDRAM into the scanline FIFO.
Each source scanline consists of `1 << FB_DISPLAY.FB_WIDTH_LOG2` RGB565 pixels (`source_width * 2` bytes).
The prefetch FSM issues burst read requests to UNIT-007 (Memory Arbiter) to read multiple sequential 16-bit words per arbiter grant, reducing arbitration overhead.
When `LINE_DOUBLE=1`, a source scanline is prefetched once and its FIFO contents are used for both the first and second output rows; SDRAM is not re-read for the repeated row.

Prefetch FSM states:
```
PREFETCH_IDLE:
  - Wait for scanline FIFO to fall below the refill threshold
  - If LINE_DOUBLE=1 and line_double_second=1: reuse FIFO contents (no SDRAM read), skip to PREFETCH_DONE
  - Otherwise: latch next read address from framebuffer base + (source_row × source_width tiles)
    where source_row = v_count >> LINE_DOUBLE (shift by 1 if LINE_DOUBLE, else v_count directly)
  - Transition to PREFETCH_BURST

PREFETCH_BURST:
  - Assert port0_req with port0_burst_len set to burst length (number of sequential 16-bit words)
  - Address auto-increments within the SDRAM controller for each beat of the burst
  - On each port0_ack: push received data into scanline FIFO, decrement remaining burst count
  - Total words to fetch per source scanline = source_width = 1 << FB_DISPLAY.FB_WIDTH_LOG2
  - When burst completes (remaining count == 0):
    * If scanline FIFO is full or scanline read complete: transition to PREFETCH_IDLE
    * If more data needed and FIFO has space: issue next burst (remain in PREFETCH_BURST)

PREFETCH_DONE:
  - All pixels for current source scanline have been prefetched
  - Wait for next scanline boundary, then transition to PREFETCH_IDLE
```

The burst length is determined by the memory arbiter's maximum burst length (defined in UNIT-007 and INT-011).
Because the display port has the highest arbiter priority, burst requests are never preempted mid-burst.
The scanline FIFO depth must accommodate at least one full burst plus SDRAM access latency (row activate + CAS delay) to prevent underrun; the synchronous 4:1 clock relationship between clk_core and clk_pixel provides 4 SDRAM cycles per pixel consumed, giving substantial prefetch margin even with SDRAM latency.

**Burst vs. Single-Word Comparison:**
- Single-word mode: each SDRAM read requires a full arbitration cycle (request, grant, row activate + CAS latency, ack) — higher overhead per word than burst mode
- Burst mode: first word has the same setup cost, but subsequent words in the burst require only 1 cycle each (address auto-increments, no re-arbitration)
- For a burst of N 16-bit words: burst mode completes in approximately (row activate + CAS latency + N) cycles vs. single-word mode requiring full access setup per word
- Display scanout per source scanline benefits substantially because all `source_width` pixels are a sequential address range in the 4×4 block-tiled layout; the entire scanline is fetched with a small number of 16-word tile bursts
- With `LINE_DOUBLE=1`, each source scanline is read only once from SDRAM regardless of the doubled output, halving display bandwidth compared to LINE_DOUBLE=0 at the same source height

**LUT DMA Burst Support:**

The LUT DMA controller also uses burst reads when loading 384 bytes from SDRAM during vblank.
The 192 sequential 16-bit SDRAM reads are issued as burst requests, reducing the DMA transfer time compared to single-word mode, though the practical impact is minimal since the vblank period is ~1.43 ms.

**LUT Auto-Load Protocol:**
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

**Double-Buffering (Auto-Swap):**
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
- **Testbench for LUT DMA auto-load**:
  - Verify 384-byte transfer from SDRAM to inactive EBR bank
  - Verify correct LUT format parsing (Red[96B] + Green[192B] + Blue[96B])
  - Verify DMA completes within vblank period (~2µs of 1.43ms)
  - Verify LUT_ADDR=0 skips auto-load
- **Testbench for bank swapping**:
  - Verify automatic bank swap after DMA completion
  - Verify swap occurs atomically with framebuffer switch
  - Verify no tearing during LUT transition
- Testbench for LUT bypass: verify unchanged RGB565→RGB888 when disabled
- Testbench for cross-channel effects: verify R→G color tinting works correctly
- Testbench for saturation: verify summed outputs clamp to 8-bit max (255)
- Timing verification: LUT adds ≤2 cycles scanout latency, within pixel period
- **DMA priority verification**: Verify memory arbiter grants MEDIUM priority to LUT DMA
- **Scanline burst read verification**:
  - Verify prefetch FSM issues burst requests to memory arbiter port 0
  - Verify address auto-increments correctly within burst (sequential 16-bit words)
  - Verify burst read data is correctly pushed into scanline FIFO in order
  - Verify prefetch FSM transitions to PREFETCH_IDLE when FIFO is full
  - Verify no FIFO underrun during active display with burst reads enabled
  - Verify burst reads do not cross scanline address boundaries
  - Verify source scanline length equals `1 << FB_DISPLAY.FB_WIDTH_LOG2` (not a hardcoded 640)
- **Horizontal scaler verification** (Bresenham nearest-neighbor):
  - Verify 512→640 scaling: output 640 pixels from a 512-pixel source; check pixel 0, 127, 319, 511, 639 map to correct source positions
  - Verify 256→640 scaling: output 640 pixels from a 256-pixel source; confirm no missing or duplicated source pixels relative to expected Bresenham positions
  - Verify 640→640 passthrough: scaler produces 1:1 copy without artifact
  - Verify accumulator initialised to `source_width >> 1` at scanline start (mid-point bias)
- **LINE_DOUBLE verification**:
  - Verify when LINE_DOUBLE=1: source scanline `s` used for output rows `2s` and `2s+1`
  - Verify no SDRAM re-read for the second output row (SDRAM read count halved vs LINE_DOUBLE=0)
  - Verify when LINE_DOUBLE=0: each output row reads a unique source row
- **LUT DMA burst read verification**:
  - Verify LUT DMA uses burst requests for the 192 sequential 16-bit SDRAM reads
  - Verify LUT DMA burst completes within vblank period

**Estimated FPGA Resources:**
- Color grading LUT: 1 EBR block (dual-bank, 128 entries × 24 bits per bank, 512×36 EBR config)
- Summation + saturation logic: ~230 LUTs
- **LUT DMA Controller**:
  - DMA state machine: ~80 FFs
  - Address counters + byte alignment: ~60 LUTs
  - SDRAM request logic: ~40 LUTs
  - Total DMA addition: ~180 LUTs, ~80 FFs
- **Scanline prefetch burst support**:
  - Prefetch FSM state register: ~10 FFs
  - Burst address counter: ~30 FFs
  - Burst remaining counter: ~10 FFs
  - Burst request logic: ~20 LUTs
  - Total burst addition: ~70 LUTs, ~50 FFs
- **Horizontal scaler (Bresenham)**:
  - Accumulator register + comparator: ~20 FFs, ~30 LUTs
  - Source pixel index counter: ~10 FFs
  - Total scaler addition: ~30 LUTs, ~30 FFs
- **LINE_DOUBLE control**:
  - Row-repeat flag + source-row address mux: ~10 FFs, ~10 LUTs
- Scanline FIFO: 1 EBR block (1024×16, inferred as DP16KD)
- **Total**: 2 EBR, ~570 LUTs, ~270 FFs

## Design Notes

Migrated from speckit module specification.

**Horizontal Scaling and LINE_DOUBLE:**
The display controller always outputs 640 pixels per active scanline to meet the DVI timing requirement (INT-002, REQ-006.01).
The source framebuffer width `1 << FB_DISPLAY.FB_WIDTH_LOG2` can be smaller than 640 (e.g. 512 for WIDTH_LOG2=9, 256 for WIDTH_LOG2=8).
A Bresenham nearest-neighbor accumulator maps 640 output pixel positions to source FIFO positions without any multiply hardware.
The accumulator is initialised to `source_width >> 1` (mid-point bias) at the start of each scanline, which ensures symmetric rounding of the scaling ratio.

When `FB_DISPLAY.LINE_DOUBLE=1`, only 240 source rows are read (source row `s = v_count >> 1`).
The scanline FIFO contents are reused for both output rows `2s` and `2s+1`; the SDRAM read for row `2s+1` is skipped entirely.
This halves the display scanout SDRAM bandwidth compared to a full-height surface, freeing more arbiter time for triangle rendering.

The scaler and LINE_DOUBLE control operate in the `clk_pixel` domain (25 MHz), downstream of the scanline FIFO.
The FIFO crossing and burst prefetch operate in `clk_core` (100 MHz) as before.

**SDRAM Behavioral Model (Verilator Simulation):**
In the Verilator interactive simulator (UNIT-037), the physical W9825G6KH SDRAM is replaced by a C++ behavioral model.
The model presents the same mem_req/mem_we/mem_addr/mem_wdata/mem_rdata/mem_ack/mem_ready/mem_burst_* handshake interface to UNIT-007 (Memory Arbiter).
To ensure the prefetch FSM and LUT DMA controller behave correctly, the model must replicate CAS latency CL=3, row activation timing (tRCD), auto-refresh blocking periods, and burst completion sequencing as specified in UNIT-007's SDRAM interface notes.
A model that omits these timing behaviors will cause FIFO underruns or incorrect LUT loads during interactive simulation.
When testing LINE_DOUBLE behavior, the behavioral model must track whether the second output row correctly avoids issuing SDRAM reads.

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

