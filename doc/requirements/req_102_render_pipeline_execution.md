# REQ-102: Render Pipeline Execution

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement a render command execution pipeline on Core 1 that dequeues render commands from the inter-core SPSC queue and dispatches each command to the GPU driver. The pipeline SHALL support the following command types: framebuffer clear (with optional depth clear), triangle rendering mode configuration, screen-space triangle submission, texture upload, and vsync synchronization with framebuffer swap. Frame boundaries SHALL be delineated by WaitVsync commands.

## Rationale

Centralizing render command execution on a dedicated core ensures deterministic GPU communication timing and allows the command dispatch logic to be extended with new command types without affecting scene management on Core 0.

## Parent Requirements

None

## Allocated To

- UNIT-021 (Core 1 Render Executor)
- UNIT-020 (Core 0 Scene Manager)
- UNIT-023 (Transformation Pipeline)
- UNIT-022 (GPU Driver Layer)
- UNIT-024 (Lighting Calculator)

## Interfaces

- INT-020 (GPU Driver API)
- INT-021 (Render Command Format)

## Verification Method

**Test:** Verify that each render command type (ClearFramebuffer, SetTriMode, SubmitScreenTriangle, UploadTexture, WaitVsync) is correctly dispatched to the corresponding GPU driver operation, and that frame statistics (command count, idle spins) are tracked per frame.

## Notes

The executor runs in an infinite loop on Core 1, spinning with NOP when the queue is empty. Framebuffer clear is implemented by rendering two full-viewport triangles (color clear) plus two additional far-plane triangles when depth clear is requested. Performance counters are logged every 120 frames via defmt.
