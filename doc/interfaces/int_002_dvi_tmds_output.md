# INT-002: DVI TMDS Output

## Type

External Standard

## External Specification

- **Standard:** DVI TMDS Output
- **Reference:** DVI 1.0 specification for TMDS encoding at 640×480@60Hz.

## Parties

- **Provider:** External
- **Consumer:** UNIT-009 (DVI TMDS Encoder)

## Referenced By

- REQ-007 (Display Output)

## Specification

### Overview

This project uses a subset of the DVI TMDS Output standard.

### Usage

DVI 1.0 specification for TMDS encoding at 640×480@60Hz.

## Project-Specific Usage

### Resolution and Timing

- **Resolution:** 640x480 @ 60 Hz (CEA-861 / standard VGA)
- **Pixel Clock:** 25.175 MHz
- **TMDS Bit Clock:** 251.75 MHz (10x pixel clock)

### Horizontal Timing (in pixel clocks)

| Parameter     | Value | Description          |
|---------------|-------|----------------------|
| H_DISPLAY     | 640   | Active video pixels  |
| H_FRONT       | 16    | Front porch          |
| H_SYNC        | 96    | Sync pulse width     |
| H_BACK        | 48    | Back porch           |
| H_TOTAL       | 800   | Total line period     |

### Vertical Timing (in lines)

| Parameter     | Value | Description          |
|---------------|-------|----------------------|
| V_DISPLAY     | 480   | Active video lines   |
| V_FRONT       | 10    | Front porch          |
| V_SYNC        | 2     | Sync pulse width     |
| V_BACK        | 33    | Back porch           |
| V_TOTAL       | 525   | Total frame period    |

### Sync Polarity

Both HSYNC and VSYNC are **active-low** (logic 0 during the sync pulse, logic 1 otherwise).

### TMDS Channel Assignment

Four differential pairs are output via the ECP5 FPGA:

| Pair          | Content                                  |
|---------------|------------------------------------------|
| `tmds_clk`    | Serialized pixel clock                   |
| `tmds_blue`   | Blue channel + HSYNC/VSYNC control bits  |
| `tmds_green`  | Green channel                            |
| `tmds_red`    | Red channel                              |

Each color channel is TMDS-encoded (8b/10b) and serialized 10:1 at the TMDS bit clock. HSYNC and VSYNC are embedded in the blue channel's control period during blanking intervals.

## Constraints

See external specification for full details.

## Notes

This is an external standard. Refer to the official specification for complete details.
