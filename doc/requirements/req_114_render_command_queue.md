# REQ-114: Render Command Queue

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

When the scene manager produces render commands for a frame, the system SHALL enqueue those commands into a SPSC render command queue and SHALL guarantee that the render executor dequeues and dispatches them in the same order they were enqueued, without dropping or reordering commands.

## Rationale

A SPSC render command queue decouples scene management (producer) from GPU submission (consumer), preserving command order and enabling pipelined execution without data races.

## Parent Requirements

REQ-TBD-SCENE-GRAPH (Scene Graph/ECS)

## Allocated To

- UNIT-026 (Inter-Core Queue)

## Interfaces

- INT-021 (Render Command Format)

## Verification Method

**Test:** Verify that a sequence of render commands enqueued by the scene manager is dequeued by the executor in the same order.
Verify that no commands are lost or reordered when the queue is at capacity (back-pressure is applied correctly).

## Notes

On the RP2350, the queue is a fixed-capacity SPSC queue (heapless) shared between Core 0 (producer) and Core 1 (consumer).
On the PC platform, commands are dispatched synchronously without a queue; the SPSC abstraction is satisfied by a direct call path.
The queue capacity is sufficient to hold all commands for one complete frame.
