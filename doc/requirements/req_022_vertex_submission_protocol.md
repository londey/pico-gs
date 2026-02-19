# REQ-022: Vertex Submission Protocol

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement vertex submission protocol as specified in the functional requirements.

## Rationale

This requirement defines the functional behavior of the vertex submission protocol subsystem.

## Parent Requirements

- REQ-TBD-SPI-CONTROLLER (GPU SPI Controller)

## Allocated To

- UNIT-003 (Register File)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Test:** Execute relevant test suite for vertex submission protocol.

## Notes

Functional requirements grouped from specification.

The vertex submission sequence writes COLOR, UV0, and VERTEX registers per INT-010.
With the dual-texture architecture, the UV2_UV3 register is removed; only UV0 (containing UV coordinates for texture units 0 and 1) is written per vertex.
When the color combiner requires a second interpolated vertex color (VER_COLOR1), an additional COLOR1 register write may be included in the submission sequence per INT-010.
