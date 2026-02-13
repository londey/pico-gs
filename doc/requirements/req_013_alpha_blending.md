# REQ-013: Alpha Blending

## Classification

- **Priority:** Important
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

The system SHALL support the following capability: As a firmware developer, I want to blend rendered pixels with framebuffer content based on alpha, so that I can render transparent and semi-transparent objects

## Rationale

This requirement enables the user story described above.

## Parent Requirements

None

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- [ ] Set ALPHA_BLEND register to select blend mode
- [ ] Support DISABLED mode (overwrite destination)
- [ ] Support ADD mode (source + destination, saturate)
- [ ] Support SUBTRACT mode (source - destination, saturate)
- [ ] Support ALPHA_BLEND mode (standard Porter-Duff source-over)
- [ ] Alpha blend applies per-component (R, G, B, A)
- [ ] Framebuffer readback promotes RGB565 to 10.8 fixed-point before blending
- [ ] Disable Z_WRITE when rendering transparent objects (Z_TEST still enabled)
- [ ] Verify correct transparency with alpha=0, 0.5, and 1.0

---


## Notes

User Story: As a firmware developer, I want to blend rendered pixels with framebuffer content based on alpha, so that I can render transparent and semi-transparent objects

Alpha blending operations are performed in 10.8 fixed-point format. Destination pixels are read from the RGB565 framebuffer and promoted to 10.8 format by left-shifting and replicating MSBs. After blending, the result passes through ordered dithering (REQ-132) before RGB565 conversion.

**Early Z compatibility:** Transparent objects are rendered with Z_WRITE=0 (as noted above) but Z_TEST=1.
Early Z-test (REQ-014) is compatible with this usage: occluded transparent fragments are correctly rejected by early Z (they would have failed the depth test at any pipeline stage), saving texture and blending work.
Since there is no alpha test (alpha kill) in this pipeline, early Z never incorrectly discards a fragment that would have modified the framebuffer.
