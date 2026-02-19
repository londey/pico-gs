# REQ-002: Framebuffer Management

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

When the host writes a 4K-aligned SDRAM address to the FB_DRAW register, the system SHALL direct all subsequent triangle rasterization output to that framebuffer base address.

When the host writes a 4K-aligned SDRAM address to the FB_DISPLAY register, the system SHALL begin scanning out from that framebuffer base address at the next VSYNC boundary.

When the host issues a CLEAR command, the system SHALL fill the current FB_DRAW framebuffer region with the CLEAR_COLOR value using full available SDRAM write bandwidth.

## Rationale

Separate draw and display framebuffer pointers enable double-buffering, which prevents visible tearing by ensuring the display controller reads from a completed frame while the rasterizer writes to a different buffer.
The SDRAM arbiter (UNIT-007) manages concurrent access from the display controller and rasterizer in the unified 100 MHz clock domain, with no CDC overhead between requestors and the SDRAM interface (see INT-011).

## Parent Requirements

- REQ-TBD-BLEND-FRAMEBUFFER (Blend/Frame Buffer Store)

## Allocated To

- UNIT-007 (Memory Arbiter)
- UNIT-008 (Display Controller)

## Interfaces

- INT-011 (SDRAM Memory Layout)
- INT-010 (GPU Register Map)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- [ ] FB_DRAW register sets where triangles render
- [ ] FB_DISPLAY register sets which buffer is scanned out
- [ ] Buffer swap (changing FB_DISPLAY) takes effect at next VSYNC
- [ ] CLEAR command fills FB_DRAW with CLEAR_COLOR at full bandwidth
- [ ] 4K-aligned addresses allow multiple buffers in 32MB SDRAM

---


## Notes

User Story: As a firmware developer, I want to configure draw target and display source addresses, so that I can implement double-buffering without tearing.

Framebuffer registers (FB_DRAW, FB_DISPLAY) may be configured autonomously by the FPGA boot sequence (REQ-021) via pre-populated command FIFO entries, prior to any host SPI communication.
Host software will configure framebuffer addresses during initialization, which must conform to the alignment and address range constraints defined in INT-011 (SDRAM Memory Layout).

**Arbitration timing**: The SDRAM arbiter (UNIT-007) operates in the unified 100 MHz clock domain shared by the GPU core and SDRAM.
Display scanout (highest priority) and rasterizer writes (lower priority) are arbitrated without CDC overhead, enabling back-to-back SDRAM grants on consecutive clock cycles.
See INT-011 for bandwidth budget details.

**SDRAM Burst Read/Write Impact:**
SDRAM burst mode improves concurrent access efficiency for both display reads and framebuffer writes.
Display scanout burst reads reduce the number of arbitration cycles consumed by display prefetch, freeing more SDRAM grant opportunities for the rasterizer's framebuffer writes on arbiter port 1.
Row locality is beneficial for framebuffer operations because sequential scanline pixels map to consecutive SDRAM addresses within the same row, allowing burst transfers without repeated row activation overhead.
See UNIT-008 for display burst prefetch and INT-011 for the updated bandwidth model.
