# REQ-113: USB Keyboard Input (RETIRED)

## Classification

- **Priority:** Essential
- **Stability:** Retired
- **Verification:** N/A

## Status

**RETIRED** — This requirement is superseded by REQ-103 (USB Keyboard Input).
REQ-113 was a stub duplicate of REQ-103 and carried no unique content.
All references to REQ-113 should be updated to REQ-103.

## Retirement Rationale

REQ-103 and REQ-113 both specified USB keyboard input behavior.
REQ-103 contains the fuller, cross-platform specification covering RP2350 (TinyUSB HID), the no-op stub build variant, and the PC terminal input path.
REQ-113 was a minimal stub with no additional requirements beyond what REQ-103 already captures.
Retaining both would create a maintenance burden and risk divergence; REQ-103 is the canonical requirement.

## Previously Allocated To

- UNIT-025 (USB Keyboard Handler) — now references REQ-103 only

## Previously Referenced Interfaces

- INT-005 (USB HID Keyboard) — now referenced from REQ-103 only

## Superseded By

- REQ-103 (USB Keyboard Input)
