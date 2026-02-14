# REQ-002: Framebuffer Management

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

When the host writes a 4K-aligned SRAM address to the FB_DRAW register, the system SHALL direct all subsequent triangle rasterization output to that framebuffer base address.

When the host writes a 4K-aligned SRAM address to the FB_DISPLAY register, the system SHALL begin scanning out from that framebuffer base address at the next VSYNC boundary.

When the host issues a CLEAR command, the system SHALL fill the current FB_DRAW framebuffer region with the CLEAR_COLOR value using full available SRAM write bandwidth.

## Rationale

Separate draw and display framebuffer pointers enable double-buffering, which prevents visible tearing by ensuring the display controller reads from a completed frame while the rasterizer writes to a different buffer.
The SRAM arbiter (UNIT-007) manages concurrent access from the display controller and rasterizer in the unified 100 MHz clock domain, with no CDC overhead between requestors and the SRAM interface (see INT-011).

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

- [ ] FB_DRAW register sets where triangles render
- [ ] FB_DISPLAY register sets which buffer is scanned out
- [ ] Buffer swap (changing FB_DISPLAY) takes effect at next VSYNC
- [ ] CLEAR command fills FB_DRAW with CLEAR_COLOR at full bandwidth
- [ ] 4K-aligned addresses allow multiple buffers in 32MB SRAM

---


## Notes

User Story: As a firmware developer, I want to configure draw target and display source addresses, so that I can implement double-buffering without tearing.

Framebuffer registers (FB_DRAW, FB_DISPLAY) may also be configured autonomously by the FPGA boot sequence (REQ-021) via pre-populated command FIFO entries, prior to any host SPI communication.
The host initialization (REQ-110) will overwrite these boot-time values with its own framebuffer configuration.
Boot sequence framebuffer addresses must conform to the alignment and address range constraints defined in INT-011 (SRAM Memory Layout).

**Arbitration timing**: The SRAM arbiter (UNIT-007) operates in the unified 100 MHz clock domain shared by the GPU core and SRAM.
Display scanout (highest priority) and rasterizer writes (lower priority) are arbitrated without CDC overhead, enabling back-to-back SRAM grants on consecutive clock cycles.
See INT-011 for bandwidth budget details.
