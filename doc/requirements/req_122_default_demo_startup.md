# REQ-122: Default Demo Startup

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the system completes hardware initialization without receiving any user input, the system SHALL automatically launch the default demo scene within one second of power-on, rendering at least one complete frame to the display via INT-020 before waiting for input.

## Rationale

Requiring an explicit user action to start any rendering would leave the display blank after power-on, which is undesirable for a demonstration device.
A default demo startup ensures the hardware is exercised immediately and gives the user a visual confirmation that the system is operational.

## Parent Requirements

- REQ-TBD-SCENE-GRAPH (Scene Graph/ECS)

## Allocated To

- UNIT-027 (Demo State Machine)

## Interfaces

- INT-020 (GPU Driver API)

## Verification Method

**Test:** Power on the system without providing any keyboard input.
Verify that a complete frame is rendered and displayed within one second of power-on.
Verify that the rendered scene matches the designated default demo.

## Notes

The default demo is the first entry in the demo selection list (demo index 0).
The one-second deadline covers GPU initialization, asset loading, and the first frame submission.
