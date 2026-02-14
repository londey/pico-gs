# REQ-002: Framebuffer Management

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to configure draw target and display source addresses, so that I can implement double-buffering without tearing

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-007 (SRAM Arbiter)
- UNIT-008 (Display Controller)

## Interfaces

- INT-011 (SRAM Memory Layout)
- INT-010 (GPU Register Map)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- - [ ] FB_DRAW register sets where triangles render
- [ ] FB_DISPLAY register sets which buffer is scanned out
- [ ] Buffer swap (changing FB_DISPLAY) takes effect at next VSYNC
- [ ] CLEAR command fills FB_DRAW with CLEAR_COLOR at full bandwidth
- [ ] 4K-aligned addresses allow multiple buffers in 32MB SRAM

---


## Notes

User Story: As a firmware developer, I want to configure draw target and display source addresses, so that I can implement double-buffering without tearing

Framebuffer registers (FB_DRAW, FB_DISPLAY) may also be configured autonomously by the FPGA boot sequence (REQ-021) via pre-populated command FIFO entries, prior to any host SPI communication.
The host initialization (REQ-110) will overwrite these boot-time values with its own framebuffer configuration.
Boot sequence framebuffer addresses must conform to the alignment and address range constraints defined in INT-011 (SRAM Memory Layout).
