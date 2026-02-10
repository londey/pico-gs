# REQ-028: Alpha Blending

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement alpha blending as specified in the functional requirements.

## Rationale

This requirement defines the functional behavior of the alpha blending subsystem.

## Parent Requirements

- REQ-013 (Alpha Blending — user story and detailed acceptance criteria)

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Test:** Execute relevant test suite for alpha blending. See REQ-013 for detailed acceptance criteria.

## Notes

This is the functional-format counterpart of REQ-013. See REQ-013 for the full user story and acceptance criteria.

Alpha blending operations are performed in 10.8 fixed-point format (10 integer bits, 8 fractional bits). Destination pixels are read from the RGB565 framebuffer and promoted to 10.8 format by left-shifting and replicating MSBs. After blending, the result passes through ordered dithering (REQ-132) before RGB565 conversion.
