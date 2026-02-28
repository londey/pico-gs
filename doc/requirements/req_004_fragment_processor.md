# REQ-004: Fragment Processor / Color Combiner

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Inspection

## Requirement

The system SHALL process rasterized fragments through a programmable color combiner stage, combining texture samples, vertex colors, and constant colors using configurable blend equations at extended internal precision.

## Rationale

The fragment processor area groups requirements for the programmable color combination stage that sits between texture sampling and framebuffer write.
This includes the color combiner modes and the internal precision format used for intermediate calculations.

## Parent Requirements

None (top-level area)

## Child Requirements

- REQ-004.01 (Color Combiner)
- REQ-004.02 (Extended Precision Fragment Processing)

## Allocated To

- UNIT-006 (Pixel Pipeline)
- UNIT-010 (Color Combiner)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Inspection:** Verify that UNIT-010 (Color Combiner) is instantiated within UNIT-006 (Pixel Pipeline) with live connections from the `cc_mode` and `const_color` register file outputs.
Child requirements REQ-004.01 and REQ-004.02 carry individual Test-level verification via VER-004 (color combiner unit test) and VER-013/VER-014 (golden image integration tests).

## Notes

This is one of 13 top-level requirement areas organizing the specification hierarchy.
UNIT-010 implements the color combiner; its `cc_mode` and `const_color` inputs are wired live from UNIT-003 (Register File) through UNIT-006 (Pixel Pipeline).
