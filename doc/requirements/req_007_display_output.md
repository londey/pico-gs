# REQ-007: Display Output

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a user, I want to the GPU to output video to a standard monitor, so that I can see the rendered graphics

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-008 (Display Controller)
- UNIT-009 (DVI TMDS Encoder)

## Interfaces

- INT-002 (DVI TMDS Output)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- [ ] 640×480 @ 60Hz resolution via DVI/HDMI
- [ ] TMDS encoding using ECP5 SERDES blocks
- [ ] Stable sync signals (no rolling, tearing, or flicker)
- [ ] Display refresh never stalls regardless of draw load
- [ ] Color grading LUT applies correctly at scanout when enabled
- [ ] LUT updates complete within one frame without tearing

---


## Notes

User Story: As a user, I want to the GPU to output video to a standard monitor, so that I can see the rendered graphics

**SRAM Burst Read Impact:**
Display scanout is the highest-priority SRAM consumer at 74 MB/s (INT-011).
UNIT-008 uses burst reads for sequential scanline prefetch, reducing per-word arbitration overhead and freeing SRAM bandwidth for lower-priority rendering operations (framebuffer writes, Z-buffer access, texture fetches).
This improves display refresh stability under heavy draw load by reducing the fraction of SRAM time consumed by display reads.
