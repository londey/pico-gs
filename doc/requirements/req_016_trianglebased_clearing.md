# REQ-016: Triangle-Based Clearing

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

When the host submits two screen-covering triangles with a solid vertex color and Z_COMPARE=ALWAYS, the system SHALL overwrite every pixel in the framebuffer with that color and write the far-plane depth to the Z-buffer, achieving a full-screen clear in under 5 ms at 640x480 resolution.

## Rationale

This requirement enables the user story described above.

## Parent Requirements

- REQ-TBD-BLEND-FRAMEBUFFER (Blend/Frame Buffer Store)

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] CLEAR_COLOR, CLEAR, CLEAR_Z registers removed from register map
- [ ] Clear color buffer by rendering two triangles covering viewport
- [ ] Clear z-buffer by rendering triangles with Z_COMPARE=ALWAYS and Z=far_plane
- [ ] Achieve similar clear performance as dedicated hardware clear (<5ms)
- [ ] Support partial clears by drawing smaller triangles
- [ ] Support pattern/gradient fills by varying vertex colors

---


## Notes

User Story: As a firmware developer, I want to clear framebuffer and z-buffer by rendering full-screen triangles, so that I have more flexible clearing with pattern fills and partial clears.

**Burst mode benefit for clears**: Full-screen triangle clears produce maximally sequential framebuffer and Z-buffer writes (entire scanlines of constant-color pixels).
This is the ideal access pattern for SDRAM burst write mode (see UNIT-007): each scanline produces 640 consecutive 16-bit framebuffer writes and 640 consecutive 16-bit Z-buffer writes.
When burst mode is available, clear throughput improves because each burst transfer amortizes SDRAM row activation and CAS latency overhead across multiple words, reducing the total time for a full-screen clear.
