# UNIT-036: PC Input Handler

## Parent Area

10. GPU Debug GUI (Pico Software)

## Purpose

Terminal keyboard input handling for the PC debug host platform.

## Implements Requirements

- REQ-009.01 (USB Keyboard Input) — canonical requirement (covers both RP2350 USB HID and PC terminal); parent area 9 (Keyboard and Controller Input)
- REQ-010.01 (PC Debug Host) — parent area 10 (GPU Debug GUI)

## Interfaces

### Provides

- INT-040 (Host Platform HAL) -- `InputSource` implementation

### Internal Interfaces

- **UNIT-022 (GPU Driver Layer)**: Scene management uses input events to switch demos and control rendering parameters.

## Design Description

### Inputs

- Terminal keyboard events (via `crossterm` crate raw mode)

### Outputs

- `InputSource` trait implementation for terminal environments
- `InputEvent` values mapped from keyboard keys

### Internal State

- **`TerminalInput`** struct:
  - Terminal raw mode handle (via `crossterm`)
  - Key mapping configuration

### Algorithm / Behavior

1. **init()**: Enable `crossterm` raw mode on the terminal. This captures keypresses directly without waiting for Enter.
2. **poll()**: Non-blocking poll for keyboard events using `crossterm::event::poll()`. If a key event is available, map it to an `InputEvent`:
   - Number keys `1`-`9` map to `InputEvent::SelectDemo(n)` for demo scene selection.
   - `q` / `Esc` maps to a quit signal (handled by main loop).
3. **Drop**: Restore terminal to normal mode on cleanup.

### Key Mapping

| Key | Action |
|-----|--------|
| `1`-`9` | Select demo scene by index |
| `q` / `Esc` | Quit application |

## Implementation

- `crates/pico-gs-pc/src/input.rs`: Terminal keyboard input handler

## Verification

- **Key mapping**: Verify number keys produce correct `InputEvent::SelectDemo` values
- **Non-blocking**: Verify `poll()` returns `None` immediately when no keys are pressed
- **Raw mode**: Verify terminal is set to raw mode on init and restored on drop

## Design Notes

The PC input handler mirrors the RP2350 USB keyboard handler (UNIT-025) in functionality but uses terminal keyboard input instead of USB HID. Both produce the same `InputEvent` types, allowing the scene management code in pico-gs-core to work identically on both platforms.
