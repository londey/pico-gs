# REQ-027: Z-Buffer Operations

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement z-buffer operations including depth comparison, depth range clipping, and conditional Z-buffer writes as specified in the functional requirements.

## Rationale

This requirement defines the functional behavior of the z-buffer operations subsystem, including depth range clipping and Z-buffer write control.

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)
- UNIT-007 (SRAM Arbiter)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

## Verification Method

**Test:** Execute relevant test suite for z-buffer operations.

- [ ] Depth comparison produces correct pass/fail results for all 8 compare functions (LESS, LEQUAL, EQUAL, GEQUAL, GREATER, NOTEQUAL, ALWAYS, NEVER)
- [ ] When Z_WRITE_EN=1, passing fragments update the Z-buffer with the new depth value
- [ ] When Z_WRITE_EN=0, the Z-buffer is not modified regardless of depth test result
- [ ] When Z_RANGE is configured to a sub-range, fragments outside [Z_RANGE_MIN, Z_RANGE_MAX] are discarded before depth test
- [ ] When Z_RANGE_MIN=0x0000 and Z_RANGE_MAX=0xFFFF, all fragments proceed to depth test (full range passthrough)

## Notes

Functional requirements grouped from specification.

Cross-references: REQ-014 (Enhanced Z-Buffer) defines the configurable compare functions, depth range clipping, and early Z-test optimization.
See REQ-014 for detailed acceptance criteria for each sub-feature.
