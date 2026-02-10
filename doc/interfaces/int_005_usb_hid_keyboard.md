# INT-005: USB HID Keyboard

## Type

External Standard

## External Specification

- **Standard:** USB HID Keyboard
- **Reference:** USB HID specification for keyboard input.

## Parties

- **Provider:** External
- **Consumer:** UNIT-025 (USB Keyboard Handler)

## Referenced By

- REQ-103 (Unknown)

## Specification

### Overview

This project uses a subset of the USB HID Keyboard standard.

### Usage

USB HID specification for keyboard input.

## Project-Specific Usage

### HID Usage Page and Protocol

- **Usage Page:** 0x07 (Keyboard/Keypad)
- **Protocol:** Boot protocol -- the standard 8-byte HID keyboard report is expected.
- **Report Format:** Byte 0 = modifier keys, byte 1 = reserved, bytes 2-7 = keycodes. The firmware reads byte 2 (first keycode) from each report.

### Supported Keycodes

Only three keycodes are mapped to application actions (demo selection):

| Key   | HID Keycode | Constant     | Action                        |
|-------|-------------|--------------|-------------------------------|
| `1`   | `0x1E`      | `HID_KEY_1`  | Select Gouraud Triangle demo  |
| `2`   | `0x1F`      | `HID_KEY_2`  | Select Textured Triangle demo |
| `3`   | `0x20`      | `HID_KEY_3`  | Select Spinning Teapot demo   |

All other keycodes are silently ignored.

### USB Host Stack

- **Library:** TinyUSB (C FFI), integrated via the `usb-host` Cargo feature flag.
- **Polling:** `tuh_task()` is called each frame from `poll_keyboard()` on Core 0 to process USB host events.
- **Initialization:** `tuh_init(0)` is called once at startup on root hub port 0.
- **Callback:** `tuh_hid_report_received_cb` (exported as `#[no_mangle] extern "C"`) receives HID reports from TinyUSB and stores the latest keycode in a module-level static.

### Feature Gating

When the `usb-host` feature is disabled, all keyboard functions become no-ops and the system runs the default demo without input.

## Constraints

See external specification for full details.

## Notes

This is an external standard. Refer to the official specification for complete details.
