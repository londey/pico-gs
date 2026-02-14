# REQ-023: Rasterization Algorithm

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When a triangle is submitted via the vertex registers and TRI_DRAW is written, the system SHALL compute edge function coefficients and a screen-clamped bounding box (UNIT-004), then iterate over all pixels within the bounding box using edge walking (UNIT-005), emitting fragments for pixels that pass the edge function inside test.

When the rasterizer emits fragments at the 100 MHz core clock rate, the system SHALL sustain a peak throughput of one fragment evaluation per clock cycle, yielding up to 100 million fragment evaluations per second.

## Rationale

Edge-function rasterization with scanline-order edge walking provides deterministic traversal of the triangle bounding box.
Operating at 100 MHz (unified GPU core clock), the rasterizer achieves double the throughput compared to a 50 MHz design, enabling higher fill rates for complex scenes.
See UNIT-004 (Triangle Setup) and UNIT-005 (Rasterizer) for implementation details.

## Parent Requirements

None

## Allocated To

- UNIT-004 (Triangle Setup)
- UNIT-005 (Rasterizer)

## Interfaces

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

## Verification Method

**Test:** Execute relevant test suite for rasterization algorithm.

## Notes

Functional requirements grouped from specification.

**Throughput**: At 100 MHz core clock, the rasterizer (UNIT-005) evaluates one pixel per cycle in the inner loop.
Effective fill rate is limited by SRAM bandwidth contention with display scanout and Z-buffer operations (see INT-011 bandwidth budget).
The theoretical peak of 100 Mpixels/sec evaluations translates to approximately 25 Mpixels/sec sustained write throughput after arbitration overhead.

**Burst-friendly output**: The edge-walking algorithm produces fragments in scanline order (left-to-right), which generates sequential SRAM addresses for framebuffer writes and Z-buffer accesses.
When SRAM burst mode is available (see UNIT-007), runs of horizontally adjacent fragments can be written in burst transfers, reducing per-pixel SRAM arbitration overhead and improving effective fill rate beyond the single-word-access baseline.
