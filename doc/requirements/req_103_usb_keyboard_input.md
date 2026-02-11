# REQ-103: USB Keyboard Input

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement USB HID keyboard input handling on Core 0 that polls for keypress events each frame and maps specific HID keycodes to demo selection commands. When the `usb-host` feature is enabled, the system SHALL initialize the TinyUSB host stack, process USB host events each poll cycle, and translate standard HID keyboard report keycodes (keys 1, 2, 3) to corresponding demo selections. When the `usb-host` feature is disabled, the input subsystem SHALL provide a no-op stub that returns no events.

## Rationale

USB keyboard input provides the primary user interaction mechanism for switching between demonstration scenes at runtime. Feature-gating the USB host stack allows the firmware to build and run without USB hardware during development and testing.

## Parent Requirements

None

## Allocated To

- UNIT-025 (USB Keyboard Handler)
- UNIT-027 (Demo State Machine)

## Interfaces

- INT-005 (USB HID Keyboard)
- INT-021 (Render Command Format)

## Verification Method

**Test:** Verify that HID keycodes 0x1E, 0x1F, and 0x20 (keys 1, 2, 3) map to GouraudTriangle, TexturedTriangle, and SpinningTeapot demo selections respectively, and that unmapped keycodes return no event. Verify that the no-op stub compiles and returns None when the usb-host feature is disabled.

## Notes

The implementation uses TinyUSB C FFI for the USB host stack. The HID report callback extracts the first keycode (byte offset 2) from the standard 8-byte keyboard report. Key state is stored in module-level statics accessed only from Core 0.
