# UNIT-003: Register File

## Purpose

Stores GPU state and vertex data

## Implements Requirements

- REQ-001 (Basic Host Communication)
- REQ-015 (Memory Upload Interface)
- REQ-022 (Vertex Submission Protocol)
- REQ-029 (Memory Upload Interface)

## Interfaces

### Provides

- INT-010 (GPU Register Map)

### Consumes

None

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

- `spi_gpu/src/spi/register_file.sv`: Main implementation

## Verification

TBD

## Design Notes

Migrated from speckit module specification.

New registers added in INT-010 v5.0: DITHER_MODE (0x32), COLOR_GRADE_CTRL (0x44), COLOR_GRADE_LUT_ADDR (0x45), COLOR_GRADE_LUT_DATA (0x46). Register file must store and decode these addresses. DITHER_MODE outputs to UNIT-006 (Pixel Pipeline). COLOR_GRADE registers output to UNIT-008 (Display Controller).
