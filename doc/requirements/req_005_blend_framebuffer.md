# REQ-005: Blend / Frame Buffer Store

## Requirement

The system SHALL manage framebuffer and depth buffer storage, supporting alpha blending, depth testing, double-buffered rendering, pixel format conversion, ordered dithering, and buffer clearing.

## Rationale

The blend/framebuffer store area groups all requirements related to the final stage of the pixel pipeline where processed fragments are written to (or discarded from) the framebuffer and depth buffer.
This includes blending modes, Z-buffer operations, framebuffer format, clearing, and double-buffering.

## Parent Requirements

None (top-level area)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SDRAM Memory Layout)

## Verification Method

**Inspection:** Verify that framebuffer SDRAM write paths originate from UNIT-013 (Color Tile Cache) and Z-buffer SDRAM write paths originate from UNIT-012 (Z-buffer Tile Cache), and that neither write path originates from UNIT-005 (Rasterizer).
Child requirements carry individual Test-level verification via VER-002 (early Z), VER-011 (depth-tested triangles), and VER-013/VER-014 (blend and full pipeline golden image tests).

## Notes

This is one of 13 top-level requirement areas organizing the specification hierarchy.
UNIT-005 (Rasterizer) emits fragments to UNIT-006 via a valid/ready handshake bus; it does not perform direct framebuffer or Z-buffer writes.
SDRAM framebuffer writes and reads for this requirement area are owned by UNIT-013 (Color Tile Cache) through SDRAM arbiter port 1 (see UNIT-007).
SDRAM Z-buffer writes are owned by UNIT-012 (Z-buffer Tile Cache) through SDRAM arbiter port 2 (see UNIT-007).
Port 1 issues burst tile reads on cache miss when alpha blending is enabled (see REQ-005.03 and UNIT-013).
Software must issue FB_CACHE_CTRL.FLUSH_TRIGGER before presenting a completed frame via FB_DISPLAY (see REQ-005.09).
