# REQ-009: Keyboard and Controller Input

## Classification

- **Priority:** Important
- **Stability:** Draft
- **Verification:** Inspection

## Requirement

The system SHALL accept user input from USB keyboards (on RP2350) and terminal keyboards (on PC) to control demo selection and scene parameters.

## Rationale

The input area groups all requirements related to receiving and processing user input across platforms.
Currently this covers USB HID keyboard input on RP2350 and terminal key input on the PC debug host.

## Parent Requirements

None (top-level area)

## Child Requirements

- REQ-009.01 (USB Keyboard Input)
- REQ-009.02 (Gamepad Input)

## Allocated To

- UNIT-025 (USB Keyboard Handler)
- UNIT-036 (PC Input Handler)

## Notes

This is one of the top-level requirement areas organizing the specification hierarchy.
