# REQ-013: Alpha Blending

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the host sets the ALPHA_BLEND register to a non-DISABLED mode and submits a triangle for rendering, the system SHALL blend each output fragment color with the existing framebuffer pixel using the selected blend equation before writing the result to the framebuffer.

When the host sets ALPHA_BLEND=DISABLED, the system SHALL overwrite the destination framebuffer pixel with the source fragment color without reading the existing framebuffer contents.

When the host sets ALPHA_BLEND=ADD, the system SHALL add the source fragment color to the destination framebuffer color, saturating each component at the maximum representable value.

When the host sets ALPHA_BLEND=SUBTRACT, the system SHALL subtract the source fragment color from the destination framebuffer color, clamping each component to zero.

When the host sets ALPHA_BLEND=ALPHA_BLEND, the system SHALL apply standard Porter-Duff source-over blending per component (R, G, B, A).

## Rationale

Alpha blending enables rendering of transparent and semi-transparent objects by combining source fragment color with existing framebuffer content.
Supporting multiple blend modes (disabled, additive, subtractive, Porter-Duff) enables a range of visual effects without additional draw passes.

Alpha blending operations are performed in 10.8 fixed-point format.
Destination pixels are read from the RGB565 framebuffer and promoted to 10.8 format by left-shifting and replicating MSBs.
After blending, the result passes through ordered dithering (REQ-132) before RGB565 conversion.

## Parent Requirements

- REQ-TBD-BLEND-FRAMEBUFFER (Blend/Frame Buffer Store)

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)

## Verification Method

**Test:** Execute relevant test suite for alpha blending:

- [ ] Set ALPHA_BLEND register to select blend mode
- [ ] Support DISABLED mode (overwrite destination, no framebuffer read)
- [ ] Support ADD mode (source + destination, saturate per component)
- [ ] Support SUBTRACT mode (source - destination, clamp to zero per component)
- [ ] Support ALPHA_BLEND mode (standard Porter-Duff source-over)
- [ ] Alpha blend applies per-component (R, G, B, A)
- [ ] Framebuffer readback promotes RGB565 to 10.8 fixed-point before blending
- [ ] Disable Z_WRITE when rendering transparent objects (Z_TEST still enabled)
- [ ] Verify correct transparency with alpha=0, 0.5, and 1.0

---


## Notes

User Story: As a firmware developer, I want to blend rendered pixels with framebuffer content based on alpha, so that I can render transparent and semi-transparent objects.

**Early Z compatibility:** Transparent objects are rendered with Z_WRITE=0 (as noted above) but Z_TEST=1.
Early Z-test (REQ-014) is compatible with this usage: occluded transparent fragments are correctly rejected by early Z (they would have failed the depth test at any pipeline stage), saving texture and blending work.
Since there is no alpha test (alpha kill) in this pipeline, early Z never incorrectly discards a fragment that would have modified the framebuffer.

**REQ-028 retired:** REQ-028 was a duplicate functional-format counterpart of this requirement.
It has been retired; REQ-013 is now the single canonical alpha blending requirement.
