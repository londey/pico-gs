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

- INT-010 (GPU Register Map) - TEXn_FMT.SWIZZLE field definition
- INT-014 (Texture Memory Layout) - Swizzle application order

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- [ ] Set TEXn_FMT.SWIZZLE to select channel ordering (INT-010)
- [ ] Swizzle applies after texture decode, before blending (INT-014)
- [ ] Support RGBA (identity, default)
- [ ] Support BGRA (swap red/blue)
- [ ] Support RRR1 (grayscale - replicate R to RGB, alpha=1)
- [ ] Support at least 13 predefined swizzle patterns (see INT-010)
- [ ] Undefined patterns default to RGBA
- [ ] Swizzle applies before texture blending
- [ ] Works correctly with both RGBA4444 and BC1 formats

---


## Notes

User Story: As a firmware developer, I want to reorder texture color channels, so that I can use grayscale textures efficiently and handle different texture formats
