# REQ-025: Framebuffer Format

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement framebuffer format as specified in the functional requirements.

## Rationale

This requirement defines the functional behavior of the framebuffer format subsystem.

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)
- UNIT-007 (SRAM Arbiter)
- UNIT-008 (Display Controller)

## Interfaces

- INT-011 (SRAM Memory Layout)

## Functional Requirements

### FR-025-1: Framebuffer Pixel Format

The framebuffer SHALL store pixels in RGB565 format within 16-bit words:

- `[15:11]` = R5 (5-bit red)
- `[10:5]` = G6 (6-bit green)
- `[4:0]` = B5 (5-bit blue)

Two pixels are packed per 32-bit SRAM word (even pixel in low 16 bits, odd pixel in high 16 bits).

### FR-025-2: Fragment to Framebuffer Conversion

The pixel pipeline SHALL convert 10.8 fixed-point fragment colors to RGB565 as follows:

1. Apply ordered dithering if enabled (REQ-132): add scaled dither value to fractional bits
2. Extract upper bits from 10-bit integer part: R[9:5]→R5, G[9:4]→G6, B[9:5]→B5
3. Pack into RGB565 format
4. Alpha channel is discarded (RGB565 has no alpha storage)

### FR-025-3: Framebuffer to Fragment Promotion

For alpha blending readback, the pixel pipeline SHALL promote RGB565 framebuffer pixels to 10.8 fixed-point:

- R5→R10: left shift 5, replicate top 5 bits to bottom 5 (`{R5, R5}`)
- G6→G10: left shift 4, replicate top 6 bits to bottom 4 (`{G6, G6[5:2]}`)
- B5→B10: left shift 5, replicate top 5 bits to bottom 5 (`{B5, B5}`)
- Alpha defaults to 1023 (fully opaque) since RGB565 has no alpha storage
- Fractional bits are zero after promotion

## Verification Method

**Test:** Execute relevant test suite for framebuffer format:

- [ ] RGB565 pixel packing matches format (R[15:11], G[10:5], B[4:0])
- [ ] Two pixels correctly packed per 32-bit SRAM word
- [ ] 10.8→RGB565 conversion with dithering produces correct output
- [ ] 10.8→RGB565 conversion without dithering truncates correctly
- [ ] RGB565→10.8 promotion for alpha blending readback produces correct values
- [ ] Alpha channel discarded on framebuffer write

## Notes

Functional requirements grouped from specification.

The framebuffer format remains RGB565 for SRAM efficiency. Internal pipeline processing uses 10.8 fixed-point (REQ-134) with ordered dithering (REQ-132) to minimize visible banding during the conversion to RGB565.
