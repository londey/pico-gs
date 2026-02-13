# REQ-005: Depth Tested Triangle

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to enable Z-buffer testing, so that overlapping triangles render in correct depth order

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-005 (Rasterizer)
- UNIT-006 (Pixel Pipeline)
- UNIT-007 (SRAM Arbiter)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] Set TRI_MODE with Z_TEST=1, Z_WRITE=1
- [ ] Z-buffer stored in SRAM (separate from color buffer)
- [ ] Depth comparison is less-than-or-equal (closer pixels win)
- [ ] Z values interpolate correctly across triangle
- [ ] Z-buffer can be cleared independently of color buffer

---


## Notes

User Story: As a firmware developer, I want to enable Z-buffer testing, so that overlapping triangles render in correct depth order

**Implementation note (early Z optimization):** When Z_TEST_EN=1 and Z_COMPARE is not ALWAYS, the Z-buffer read and comparison may be performed before texture fetch as an optimization (see REQ-014).
This does not change functional behavior — the same fragments pass or fail — but rejected fragments skip texture and blending stages, reducing SRAM bandwidth consumption.
The Z-buffer write remains at the end of the pipeline regardless of early Z status.
