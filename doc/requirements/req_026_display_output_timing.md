# REQ-026: Display Output Timing

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirements

### REQ-026.1: Pixel Clock Frequency

When the PLL has achieved lock after power-on, the system SHALL generate a 25.000 MHz pixel clock (clk_pixel) derived as an integer 4:1 division of the 100 MHz core clock (clk_core).

### REQ-026.2: Horizontal Timing

When the display controller is active, the system SHALL produce horizontal timing with 640 active pixels, 16 front porch pixels, 96 sync pulse pixels, and 48 back porch pixels (800 total pixel clocks per line), as specified in INT-002.

### REQ-026.3: Vertical Timing

When the display controller is active, the system SHALL produce vertical timing with 480 active lines, 10 front porch lines, 2 sync pulse lines, and 33 back porch lines (525 total lines per frame), as specified in INT-002.

### REQ-026.4: Frame Rate

When the display controller is generating timing at the 25.000 MHz pixel clock, the system SHALL produce a frame rate of approximately 59.52 Hz (25,000,000 / (800 x 525)).

### REQ-026.5: TMDS Bit Clock

When the display controller is outputting pixel data, the TMDS encoder SHALL serialize each 10-bit symbol at a 250.0 MHz bit clock (10x the pixel clock), as specified in INT-002.

### REQ-026.6: Sync Polarity

When the display controller generates horizontal and vertical sync pulses, the sync signals SHALL be active-low (logic 0 during the sync pulse, logic 1 otherwise).

## Rationale

This requirement defines the functional behavior of the display output timing subsystem.
The 25.000 MHz pixel clock is derived as clk_core / 4 from the unified 100 MHz GPU/SRAM clock, giving a synchronous 4:1 relationship that eliminates async CDC between the GPU core and display domains.
The 0.7% deviation from the 25.175 MHz VGA standard pixel clock is within the tolerance of virtually all monitors.

## Parent Requirements

None

## Allocated To

- UNIT-008 (Display Controller)
- UNIT-009 (DVI TMDS Encoder)

## Interfaces

- INT-002 (DVI TMDS Output)
- INT-010 (GPU Register Map)

## Verification Method

**Test:** For each requirement:
- REQ-026.1: Measure pixel clock output frequency; confirm 25.000 MHz +/- 0.01%.
- REQ-026.2: Count pixel clocks per line in simulation; confirm H_TOTAL = 800 with correct active/porch/sync breakdown.
- REQ-026.3: Count lines per frame in simulation; confirm V_TOTAL = 525 with correct active/porch/sync breakdown.
- REQ-026.4: Measure frame period in simulation; confirm approximately 59.52 Hz (16.8 ms per frame).
- REQ-026.5: Measure TMDS serialization clock; confirm 250.0 MHz and 10 bits per pixel clock period.
- REQ-026.6: Observe sync signal levels during sync pulse intervals; confirm active-low polarity.

## Notes

The pixel clock frequency changed from 25.175 MHz to 25.000 MHz as part of the unified 100 MHz clock domain architecture.
This enables a synchronous 4:1 relationship between clk_core and clk_pixel, simplifying the display controller's scanline FIFO CDC.
