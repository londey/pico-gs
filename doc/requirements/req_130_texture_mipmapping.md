# REQ-130: Texture Mipmapping

## Type

Functional

## Priority

Medium

## Classification

- **Priority:** Medium
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

When a texture unit is configured with a mipmap chain (MIP_LEVELS > 1) and mipmapping is enabled, the system SHALL select and sample the appropriate mipmap level based on the screen-space rate of change of texture coordinates, enabling proper filtering of textured surfaces at varying distances from the camera.

## Functional Requirements

### FR-130-1: Mipmap Chain Storage

**Description**: The GPU SHALL support textures with mipmap chains consisting of the base level plus progressively downsampled levels down to 1x1 pixels.

**Details**:
- Mipmap levels stored sequentially in memory (base first, smallest last)
- Each level dimensions = max(base_dimension >> level, 1)
- For BC1 textures, minimum dimension per level is 4 pixels (BC1 block minimum)
- Maximum mipmap levels: 11 (for 1024×1024 down to 1×1)

**Acceptance Criteria**:
- Textures with 1-11 mipmap levels can be uploaded to GPU SDRAM
- Memory layout follows sequential organization per INT-014
- Firmware API supports mipmap count specification

### FR-130-2: LOD Selection

**Description**: The GPU SHALL automatically select the appropriate mipmap level (LOD - Level of Detail) based on screen-space texture coordinate derivatives.

**Details**:
- LOD = log₂(max(|du/dx|, |dv/dx|, |du/dy|, |dv/dy|))
- LOD clamped to range [0, mip_levels-1]
- LOD bias adjustable per texture unit (TEX0, TEX1) via TEXn_MIP_BIAS register

**Acceptance Criteria**:
- LOD calculated per pixel based on derivatives
- LOD selection completes within 2 clock cycles (20 ns at 100 MHz `clk_core`)
- LOD bias shifts selection by -4.0 to +3.99 levels

### FR-130-3: Mipmap Addressing

**Description**: The GPU SHALL calculate the correct memory address for the selected mipmap level.

**Details**:
- Base address from TEXn_BASE register
- Mipmap level address = base + sum of sizes of all previous levels
- Size calculation accounts for block-compressed formats (BC1)

**Acceptance Criteria**:
- Address calculation hardware implemented in pixel pipeline
- Supports both RGBA4444 and BC1 formats
- No visual artifacts from incorrect addressing

### FR-130-4: Texture Filtering Modes

**Description**: The GPU SHALL support nearest-mip sampling (single mipmap level sampled with bilinear filtering).

**Details**:
- LOD rounded to nearest integer (nearest mip)
- Bilinear filtering within selected mip level
- Trilinear filtering (blend between mip levels) is future work

**Acceptance Criteria**:
- Nearest-mip mode produces artifact-free rendering
- Transition between mip levels occurs at LOD=N.5

## Performance Targets

| Metric | Target |
|--------|--------|
| LOD calculation latency | <2 cycles (20 ns at 100 MHz) |
| Mipmap address calculation | <1 cycle (10 ns at 100 MHz) |
| Memory overhead | ~33% per texture |

## Parent Requirements

REQ-TBD-TEXTURE-SAMPLERS

## Dependencies

- **INT-010**: GPU Register Map (MIP_LEVELS, MIP_BIAS registers)
- **INT-014**: Texture Memory Layout (mipmap chain specification)
- **INT-020**: GPU Driver API (mipmap upload functions)
- **UNIT-006**: Pixel Pipeline (LOD calculator, mipmap addressing logic)

## Notes

Mipmaps improve both visual quality (reduced aliasing) and performance (better cache locality for distant objects). The ~33% memory overhead is standard in GPU texturing.

Mipmapping applies to both texture units (TEX0 and TEX1) in the dual-texture architecture.
The larger per-unit texture cache (16K texels per sampler) improves mipmap cache locality since multiple mip levels for the same texture are more likely to remain resident.
