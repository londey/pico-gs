# REQ-102: Render Pipeline Execution

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

The system SHALL implement a render command execution pipeline on Core 1 that dequeues render commands from the inter-core SPSC queue and dispatches each command to the GPU driver. The pipeline SHALL support the following command types: framebuffer clear (with optional depth clear), triangle rendering mode configuration (including per-material color write enable and color combiner mode), mesh patch rendering (vertex transformation, lighting, culling, clipping, and GPU submission), screen-space triangle submission (for simple demos), texture upload, color combiner configuration (combiner mode, material colors, fog parameters), and vsync synchronization with framebuffer swap. The primary per-frame command type SHALL be RenderMeshPatch. Frame boundaries SHALL be delineated by WaitVsync commands.

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

**Test:** Verify that each render command type (ClearFramebuffer, SetTriMode, SetColorCombiner, SubmitScreenTriangle, UploadTexture, WaitVsync) is correctly dispatched to the corresponding GPU driver operation, and that frame statistics (command count, idle spins) are tracked per frame.

## Notes

On the RP2350 platform, the executor runs in an infinite loop on Core 1, spinning with NOP when the queue is empty. On the PC platform, commands are executed synchronously in the main loop (no queue). The command dispatch logic is platform-agnostic and shared. See REQ-100 for the multi-platform architecture.

Framebuffer clear is implemented by rendering two full-viewport triangles (color clear) plus two additional far-plane triangles when depth clear is requested. Performance counters are logged every 120 frames via defmt (RP2350) or tracing (PC).

**Z-prepass rendering pattern:** The per-material color write enable (COLOR_WRITE_EN in RENDER_MODE) supports a Z-prepass workflow: first render all opaque geometry with COLOR_WRITE_EN=0 and Z_WRITE_EN=1 to populate the Z-buffer, then re-render with COLOR_WRITE_EN=1 and Z_WRITE_EN=0 using EQUAL depth compare.
Combined with early Z rejection (REQ-014), this eliminates overdraw cost for the color pass since every fragment either passes (exact depth match) or is rejected early.

**Color combiner configuration:** Material state now includes the color combiner mode in addition to existing RENDER_MODE flags.
The color combiner mode, material colors (MAT_COLOR0, MAT_COLOR1), and fog parameters are configured per-material via dedicated GPU registers (see INT-010) and may be set as part of the SetTriMode or a separate SetColorCombiner command.
