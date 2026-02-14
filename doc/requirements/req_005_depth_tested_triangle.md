# REQ-005: Depth Tested Triangle

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

When the host sets Z_TEST=1 in the TRI_MODE register and a triangle is rasterized, the system SHALL read the Z-buffer value at each fragment position, compare the interpolated fragment depth against the stored depth using the configured comparison function, and discard fragments that fail the test.

When the host sets Z_WRITE=1 in the TRI_MODE register and a fragment passes the depth test, the system SHALL write the fragment's interpolated depth value to the Z-buffer at that position.

## Rationale

Depth testing ensures overlapping triangles render in correct depth order regardless of submission order.
Z-buffer read/write operations are performed by the pixel pipeline (UNIT-006) through the SRAM arbiter (UNIT-007), which operates in the unified 100 MHz clock domain shared by the GPU core and SRAM.
This eliminates CDC latency on Z-buffer access paths, improving effective throughput for depth-heavy scenes.

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

- [ ] Set TRI_MODE with Z_TEST=1, Z_WRITE=1
- [ ] Z-buffer stored in SRAM (separate from color buffer)
- [ ] Depth comparison is less-than-or-equal (closer pixels win)
- [ ] Z values interpolate correctly across triangle
- [ ] Z-buffer can be cleared independently of color buffer

---


## Notes

User Story: As a firmware developer, I want to enable Z-buffer testing, so that overlapping triangles render in correct depth order.

**Implementation note (early Z optimization):** When Z_TEST_EN=1 and Z_COMPARE is not ALWAYS, the Z-buffer read and comparison may be performed before texture fetch as an optimization (see REQ-014).
This does not change functional behavior — the same fragments pass or fail — but rejected fragments skip texture and blending stages, reducing SRAM bandwidth consumption.
The Z-buffer write remains at the end of the pipeline regardless of early Z status.

**Z-buffer timing**: Z-buffer reads and writes go through SRAM arbiter port 2 (UNIT-007).
With the GPU core and SRAM in the same 100 MHz clock domain, Z-buffer read-compare-write sequences incur no CDC synchronizer delays, enabling the pixel pipeline to sustain higher fragment throughput in depth-intensive scenes.
