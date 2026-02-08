# REQ-014: Enhanced Z-Buffer

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to configure z-buffer compare functions, so that I can control depth testing behavior (reverse Z, equal test, always pass, etc.)

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)
- UNIT-007 (SRAM Arbiter)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] Set FB_ZBUFFER register with base address and compare function
- [ ] Support LESS compare (incoming < zbuffer)
- [ ] Support LEQUAL compare (incoming ≤ zbuffer)
- [ ] Support EQUAL compare (incoming = zbuffer)
- [ ] Support GEQUAL compare (incoming ≥ zbuffer)
- [ ] Support GREATER compare (incoming > zbuffer)
- [ ] Support NOTEQUAL compare (incoming ≠ zbuffer)
- [ ] Support ALWAYS compare (always pass)
- [ ] Support NEVER compare (always fail)
- [ ] Space reserved in register for future stencil operations

---


## Notes

User Story: As a firmware developer, I want to configure z-buffer compare functions, so that I can control depth testing behavior (reverse Z, equal test, always pass, etc.)
