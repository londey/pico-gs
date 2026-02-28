# REQ-005: Blend / Frame Buffer Store

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Inspection

## Requirement

The system SHALL manage framebuffer and depth buffer storage, supporting alpha blending, depth testing, double-buffered rendering, pixel format conversion, ordered dithering, and buffer clearing.

## Rationale

The blend/framebuffer store area groups all requirements related to the final stage of the pixel pipeline where processed fragments are written to (or discarded from) the framebuffer and depth buffer.
This includes blending modes, Z-buffer operations, framebuffer format, clearing, and double-buffering.

## Parent Requirements

None (top-level area)

## Child Requirements

- REQ-005.01 (Framebuffer Management)
- REQ-005.02 (Depth Tested Triangle)
- REQ-005.03 (Alpha Blending)
- REQ-005.04 (Enhanced Z-Buffer)
- REQ-005.05 (Triangle-Based Clearing)
- REQ-005.06 (Framebuffer Format)
- REQ-005.07 (Z-Buffer Operations)
- REQ-005.08 (Clear Framebuffer)
- REQ-005.09 (Double-Buffered Rendering)
- REQ-005.10 (Ordered Dithering)

## Allocated To

- UNIT-006 (Pixel Pipeline) — alpha blending, depth test, dithering, framebuffer and Z-buffer SDRAM writes
- UNIT-007 (Memory Arbiter) — SDRAM arbitration for framebuffer and Z-buffer ports
- UNIT-008 (Display Controller) — double-buffer flip and display scanout

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)

## Verification Method

**Inspection:** Verify that framebuffer and Z-buffer SDRAM write paths originate from UNIT-006 (Pixel Pipeline) and not from UNIT-005 (Rasterizer).
Child requirements carry individual Test-level verification via VER-002 (early Z), VER-011 (depth-tested triangles), and VER-013/VER-014 (blend and full pipeline golden image tests).

## Notes

This is one of 13 top-level requirement areas organizing the specification hierarchy.
UNIT-005 (Rasterizer) emits fragments to UNIT-006 via a valid/ready handshake bus; it does not perform direct framebuffer or Z-buffer writes.
All SDRAM writes for this requirement area are owned by UNIT-006 through SDRAM arbiter ports 1 (framebuffer) and 2 (Z-buffer) (see UNIT-007).
