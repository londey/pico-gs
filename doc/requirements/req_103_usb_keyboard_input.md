# REQ-103: USB Keyboard Input

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement user input handling that polls for keypress events each frame and maps platform-specific input events to demo selection commands, conforming to the `InputSource` trait defined in INT-040. On the RP2350 platform, when the `usb-host` feature is enabled, the system SHALL initialize the TinyUSB host stack, process USB host events each poll cycle, and translate standard HID keyboard report keycodes (keys 1, 2, 3) to corresponding demo selections. When the `usb-host` feature is disabled, the input subsystem SHALL provide a no-op stub that returns no events. On the PC platform, the system SHALL accept keyboard input via the terminal and map keys 1, 2, 3 to corresponding demo selections.

## Rationale

User input provides the primary interaction mechanism for switching between demonstration scenes at runtime. The `InputSource` trait (INT-040) abstracts platform differences, allowing the same scene management logic to work with TinyUSB on RP2350 and terminal keyboard on PC. Feature-gating the USB host stack allows the RP2350 firmware to build and run without USB hardware during development and testing.

## Parent Requirements

None

## Allocated To

- UNIT-025 (USB Keyboard Handler)
- UNIT-027 (Demo State Machine)
- UNIT-036 (PC Input Handler)

## Interfaces

- INT-005 (USB HID Keyboard)
- INT-021 (Render Command Format)
- INT-040 (Host Platform HAL)

## Verification Method

**Test (RP2350):** Verify that HID keycodes 0x1E, 0x1F, and 0x20 (keys 1, 2, 3) map to GouraudTriangle, TexturedTriangle, and SpinningTeapot demo selections respectively, and that unmapped keycodes return no event. Verify that the no-op stub compiles and returns None when the usb-host feature is disabled.

**Test (PC):** Verify that terminal keyboard keys 1, 2, 3 map to corresponding demo selections.

## Notes

On RP2350, the implementation uses TinyUSB C FFI for the USB host stack. The HID report callback extracts the first keycode (byte offset 2) from the standard 8-byte keyboard report. Key state is stored in module-level statics accessed only from Core 0. On PC, the implementation uses the `crossterm` crate for non-blocking terminal keyboard input.
