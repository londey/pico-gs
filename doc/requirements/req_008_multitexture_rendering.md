# REQ-008: Multi-Texture Rendering

## Classification

- **Priority:** Important
- **Stability:** Draft
- **Verification:** Demonstration

## Requirement

When the firmware configures two texture units (TEX0 and TEX1) with valid base addresses and formats, the system SHALL sample both textures during rasterization and provide both texture colors (TEX_COLOR0, TEX_COLOR1) as inputs to the color combiner stage.

## Rationale

Dual-texture rendering enables common multi-texture effects such as diffuse + lightmap, base texture + detail map, or environment mapping + diffuse in a single rendering pass.
This aligns with N64/GeForce2 MX-era dual-texture capabilities.
Effects requiring more than two textures (e.g., diffuse + lightmap + specular + detail) are achievable via multi-pass rendering.

## Parent Requirements

REQ-TBD-TEXTURE-SAMPLERS

## Allocated To

- UNIT-006 (Pixel Pipeline)

## Interfaces

- INT-010 (GPU Register Map)
- INT-014 (Texture Memory Layout)

## Functional Requirements

### FR-008-1: Dual Texture Unit Support

When the firmware enables texture mapping (TRI_MODE TEXTURED=1), the system SHALL support up to 2 independent texture units (TEX0 and TEX1), each with its own base address, format, dimensions, and UV coordinate registers (UV0, UV1).

### FR-008-2: Independent Texture Configuration

When a texture unit is configured, each unit SHALL independently specify:
- Base address in SDRAM (TEXn_BASE register)
- Texture format and dimensions (TEXn_FMT register)
- UV wrapping mode (TEXn_WRAP register)
- UV coordinates per vertex (UV0, UV1 registers)

### FR-008-3: Color Combiner Input

When both texture units are enabled, the system SHALL provide both sampled texture colors (TEX_COLOR0 from TEX0, TEX_COLOR1 from TEX1) as inputs to the color combiner stage (REQ-009).

### FR-008-4: Single Texture Fallback

When only TEX0 is enabled (TEX1 disabled), the system SHALL provide TEX_COLOR0 to the color combiner and treat TEX_COLOR1 as a neutral value (implementation-defined, typically white RGBA=1,1,1,1).

## Verification Method

**Demonstration:** The system SHALL meet the following acceptance criteria:

- [ ] Configure 2 independent texture units (TEX0, TEX1)
- [ ] Each texture unit has its own UV coordinate register (UV0, UV1)
- [ ] Set UV0 and UV1 registers before each VERTEX write
- [ ] Both enabled textures sample in a single draw call
- [ ] Textures can have different dimensions (e.g., 256x256 diffuse, 64x64 lightmap)
- [ ] Each texture unit has independent base address and format configuration
- [ ] Single-texture mode works correctly when only TEX0 is enabled
- [ ] See INT-010 (GPU Register Map) for register details

## Notes

This requirement supersedes the previous 4-texture-unit specification.
The reduction from 4 to 2 texture units per pass enables larger per-unit texture caches (REQ-131) and simplifies the pipeline while maintaining sufficient capability for common multi-texture effects.
Effects previously requiring 4 simultaneous textures can be achieved through multi-pass rendering combined with the color combiner (REQ-009).
