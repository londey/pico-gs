# REQ-200: PNG Asset Processing

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL load PNG image files and convert them to RGBA8888 pixel data suitable for GPU texture upload. The system SHALL validate that texture dimensions are power-of-two, within the range 8x8 to 1024x1024, and reject inputs that violate these constraints with descriptive error messages. The system SHALL generate a sanitized Rust identifier from the source file path (including the immediate parent directory) to uniquely name each texture asset.

## Rationale

The GPU hardware requires power-of-two texture dimensions and imposes minimum (8x8) and maximum (1024x1024) size limits. Validating these constraints at build time prevents runtime failures on the embedded target. Converting all input images to a uniform RGBA8888 format ensures a consistent data layout for the GPU driver's texture upload path.

## Parent Requirements

None

## Allocated To

- UNIT-030 (PNG Decoder)

## Interfaces

- INT-003 (Texture Input Formats)
- INT-031 (Asset Binary Format)

## Verification Method

**Test:** Unit tests verify power-of-two validation accepts valid dimensions (8x8, 256x256, 1024x512) and rejects non-power-of-two, undersized, and oversized inputs. Integration tests confirm end-to-end PNG loading produces correct RGBA8888 byte output with expected data length (width * height * 4).

## Notes

The implementation uses the `image` crate to decode PNG files and convert to RGBA8 regardless of the source color format. Identifier generation includes the parent directory name to namespace textures (e.g., `textures/player.png` becomes `TEXTURES_PLAYER`), with collision detection across all assets in a build.
