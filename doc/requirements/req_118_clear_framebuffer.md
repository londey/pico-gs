# REQ-118: Clear Framebuffer

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the host issues a clear-framebuffer command via INT-020, the system SHALL write the specified fill color to every pixel location of the active back-buffer in SRAM before any geometry commands for that frame are submitted, leaving the depth buffer in a fully reset state.

## Rationale

A framebuffer clear establishes a known starting state before geometry is rendered each frame.
Without clearing, residual pixel data and depth values from the previous frame produce visual corruption.
Clearing the back-buffer (not the displayed front-buffer) prevents visible tearing during the clear operation.

## Parent Requirements

- REQ-TBD-BLEND-FRAMEBUFFER-STORE (Blend/Frame Buffer Store)

## Allocated To

- UNIT-022 (GPU Driver Layer)

## Interfaces

- INT-020 (GPU Driver API)
- INT-010 (GPU Register Map)

## Verification Method

**Test:** Issue a clear command with a known fill color.
Read back all pixels of the cleared buffer and verify every pixel matches the specified fill color.
Verify that the depth buffer is also reset to the maximum depth value.
Verify that the displayed front-buffer is unmodified during the clear operation.

## Notes

Previously allocated to UNIT-021 (Core 1 Render Executor); UNIT-021 reference removed pending single-threaded architecture consolidation.
