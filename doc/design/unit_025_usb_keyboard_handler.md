# UNIT-025: USB Keyboard Handler

## Purpose

USB HID keyboard input processing

## Implements Requirements

- REQ-103 (Unknown)
- REQ-113 (USB Keyboard Input)

## Interfaces

### Provides

None

### Consumes

- INT-005 (USB HID Keyboard)

### Internal Interfaces

- **UNIT-020 (Core 0 Scene Manager)**: Called from the Core 0 main loop via `input::init_keyboard()` (once at startup) and `input::poll_keyboard()` (each frame).
- **UNIT-027 (Demo State Machine)**: Returns `KeyEvent::SelectDemo(Demo)` which the scene manager uses to call `Scene::switch_demo()`.

## Design Description

### Inputs

- **TinyUSB HID reports** (when `usb-host` feature enabled): Raw USB HID keyboard reports received via `tuh_hid_report_received_cb()` C callback. Standard HID report format: byte 2 contains the first keycode.
- **`poll_keyboard()` call**: Invoked by Core 0 each frame iteration.

### Outputs

- **`poll_keyboard()` returns `Option<KeyEvent>`**: `Some(KeyEvent::SelectDemo(demo))` when a mapped key is pressed, `None` otherwise.
- **Key-to-demo mapping**: HID key 1 (0x1E) -> `GouraudTriangle`, key 2 (0x1F) -> `TexturedTriangle`, key 3 (0x20) -> `SpinningTeapot`.

### Internal State

- **`LAST_KEYCODE: u8`** (static mut): Most recently received HID keycode, written by the TinyUSB callback.
- **`KEY_PENDING: bool`** (static mut): Flag indicating an unread keycode is available, set by callback, cleared by `poll()`.
- Both statics are only accessed from Core 0 (single-threaded context).
- When `usb-host` feature is disabled, no internal state exists; all functions are no-ops.

### Algorithm / Behavior

1. **Initialization** (`init_keyboard()`):
   - With `usb-host` feature: calls `tuh_init(0)` to initialize TinyUSB host stack on USB port 0.
   - Without feature: logs that USB host is disabled; no-op.
2. **Polling** (`poll_keyboard()`):
   - With `usb-host` feature: calls `tuh_task()` to process pending USB events, then checks `KEY_PENDING`. If set, clears the flag, reads `LAST_KEYCODE`, and passes it to `map_keycode()`.
   - Without feature: always returns `None`.
3. **Keycode mapping** (`map_keycode()`): Matches HID keycodes to `KeyEvent::SelectDemo` variants. Unrecognized keycodes return `None`.
4. **HID callback** (`tuh_hid_report_received_cb()`): Called by TinyUSB when a HID report arrives. Extracts keycode from byte offset 2; if non-zero, stores it in `LAST_KEYCODE` and sets `KEY_PENDING`.

## Implementation

- `host_app/src/scene/input.rs`: Public API (`init_keyboard()`, `poll_keyboard()`), keycode mapping, `KeyEvent` type, TinyUSB FFI module

## Verification

- **Keycode mapping test**: Verify keys 1/2/3 map to `GouraudTriangle`/`TexturedTriangle`/`SpinningTeapot` respectively, and unrecognized keycodes return `None`.
- **Feature gate test**: Verify `poll_keyboard()` returns `None` when `usb-host` feature is disabled.
- **Callback test**: Verify `tuh_hid_report_received_cb()` correctly extracts keycode from byte 2 and sets `KEY_PENDING`.
- **No-double-read test**: Verify `poll()` clears `KEY_PENDING` so the same keypress is not returned twice.

## Design Notes

Migrated from speckit module specification.
