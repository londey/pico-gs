# REQ-110: GPU Initialization

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the host firmware powers on, the system SHALL initialize the GPU by: (1) detecting GPU presence via SPI transaction, (2) configuring default register state (framebuffer addresses, display mode, rendering config), and (3) verifying GPU readiness via status register polling, completing the entire sequence within 100ms.

## Rationale

Deterministic initialization ensures the GPU is in a known state before rendering begins. The 100ms timeout provides sufficient margin for SPI transactions while keeping startup latency imperceptible to users (<1 frame at 10 FPS). Default configuration prevents undefined behavior if firmware attempts to render before explicit setup.

## Parent Requirements

None

## Allocated To

- UNIT-022 (GPU Driver Layer)

## Interfaces

- INT-010 (GPU Register Map)
- INT-020 (GPU Driver API)

## Verification Method

**Test:** Verify initialization sequence meets the following criteria:

- [ ] GPU presence detection succeeds (valid response to SPI transaction)
- [ ] Default framebuffer addresses configured (FB_DRAW, FB_DISPLAY, FB_ZBUFFER)
- [ ] Default display mode configured (640×480 @ 60 Hz)
- [ ] Default rendering config set (Z-test enabled, alpha blend disabled, flat shading, color write enabled)
- [ ] Default Z_RANGE register configured (Z_RANGE_MIN=0x0000, Z_RANGE_MAX=0xFFFF = full range)
- [ ] Status register polling confirms GPU ready
- [ ] Entire initialization sequence completes within 100ms from power-on
- [ ] GPU accepts rendering commands immediately after initialization

## Notes

Initialization is performed by UNIT-022 (GPU Driver Layer) during firmware startup. The sequence is documented in [concept_of_execution.md](../design/concept_of_execution.md).

Default register state additions: Z_RANGE is initialized to full range (Z_RANGE_MIN=0x0000, Z_RANGE_MAX=0xFFFF) so that depth range clipping is effectively disabled until explicitly configured.
RENDER_MODE is initialized with COLOR_WRITE_EN=1 ensuring color output is enabled by default.
