# REQ-011: Swizzle Patterns

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to reorder texture color channels, so that I can use grayscale textures efficiently and handle different texture formats

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

- - [ ] Set TEXn_FMT.SWIZZLE to select channel ordering
- [ ] Support RGBA (identity, default)
- [ ] Support BGRA (swap red/blue)
- [ ] Support RRR1 (grayscale - replicate R to RGB, alpha=1)
- [ ] Support at least 13 predefined swizzle patterns
- [ ] Undefined patterns default to RGBA
- [ ] Swizzle applies before texture blending

---


## Notes

User Story: As a firmware developer, I want to reorder texture color channels, so that I can use grayscale textures efficiently and handle different texture formats
