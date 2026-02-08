# UNIT-006: Pixel Pipeline

## Purpose

Texture sampling, blending, z-test, framebuffer write

## Implements Requirements

- REQ-003 (Flat Shaded Triangle)
- REQ-004 (Gouraud Shaded Triangle)
- REQ-005 (Depth Tested Triangle)
- REQ-006 (Textured Triangle)
- REQ-008 (Multi-Texture Rendering)
- REQ-009 (Texture Blend Modes)
- REQ-010 (Compressed Textures)
- REQ-011 (Swizzle Patterns)
- REQ-012 (UV Wrapping Modes)
- REQ-013 (Alpha Blending)
- REQ-014 (Enhanced Z-Buffer)
- REQ-016 (Triangle-Based Clearing)
- REQ-024 (Texture Sampling)
- REQ-027 (Z-Buffer Operations)
- REQ-028 (Alpha Blending)

## Interfaces

### Provides

None

### Consumes

- INT-010 (GPU Register Map)
- INT-011 (SRAM Memory Layout)

### Internal Interfaces

TBD

## Design Description

### Inputs

TBD

### Outputs

TBD

### Internal State

TBD

### Algorithm / Behavior

TBD

## Implementation

- `spi_gpu/src/render/pixel_pipeline.sv`: Main implementation

## Verification

TBD

## Design Notes

Migrated from speckit module specification.
