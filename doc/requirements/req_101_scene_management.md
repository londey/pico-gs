# REQ-101: Scene Management

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement a scene management subsystem on Core 0 that maintains the active demo state, supports switching between multiple demonstration scenes via user input, and generates per-frame render commands appropriate to the currently active demo. The scene manager SHALL track whether a newly selected demo requires one-time initialization (such as texture uploads or state resets) and execute that initialization before rendering the first frame of the new demo.

## Rationale

A centralized scene manager decouples the demo selection logic and per-demo initialization from the render pipeline, allowing new demos to be added without modifying the core rendering or input systems.

## Parent Requirements

None

## Allocated To

- UNIT-020 (Core 0 Scene Manager)
- UNIT-027 (Demo State Machine)

## Interfaces

- INT-021 (Render Command Format)

## Verification Method

**Test:** Verify that switching demos updates the active demo state, triggers one-time initialization on first frame, and generates the correct sequence of render commands (clear, set mode, submit triangles, vsync) for each demo type.

## Notes

The scene graph tracks an active demo enum (GouraudTriangle, TexturedTriangle, SpinningTeapot) and a `needs_init` flag. Demo-specific assets (vertex data, mesh geometry, lighting parameters) are pre-generated at startup and reused across frames. The default demo on boot is GouraudTriangle.
