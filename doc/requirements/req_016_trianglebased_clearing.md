# REQ-016: Triangle-Based Clearing

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to clear framebuffer and z-buffer by rendering full-screen triangles, so that I have more flexible clearing with pattern fills and partial clears

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

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

User Story: As a firmware developer, I want to clear framebuffer and z-buffer by rendering full-screen triangles, so that I have more flexible clearing with pattern fills and partial clears
