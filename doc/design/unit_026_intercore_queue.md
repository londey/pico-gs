# UNIT-026: Inter-Core Queue

## Parent Area

8. Scene Graph/ECS (Pico Software)

## Purpose

SPSC queue for render command dispatch (Core 0→Core 1 on RP2350; single-threaded equivalent on other platforms)

## Implements Requirements

- REQ-007.01 (Matrix Transformation Pipeline) — parent area 7 (Vertex Transformation)
- REQ-008.04 (Render Command Queue) — parent area 8 (Scene Graph/ECS)

## Interfaces

### Provides

- INT-021 (Render Command Format)

### Consumes

- INT-031 (Asset Binary Format) — `RenderMeshPatch` carries a `&'static MeshPatchDescriptor` whose SoA vertex blob follows the INT-031 binary layout

### Internal Interfaces

- **UNIT-020 (Core 0 Scene Manager)**: Core 0 owns the `CommandProducer<'static>` and enqueues `RenderCommand` variants via `enqueue_blocking()`.
- **UNIT-021 (Core 1 Render Executor)**: Core 1 owns the `CommandConsumer<'static>` and dequeues commands in its render loop.

## Design Description

### Inputs

- **Producer side** (`CommandProducer::enqueue()`): Accepts a `RenderCommand` value. Returns `Ok(())` on success or `Err(cmd)` when the queue is full (returning the command for retry).
- **Queue split** (`COMMAND_QUEUE.split()`): Called once in `main()` before Core 1 is spawned, producing `(CommandProducer, CommandConsumer)` pair.

### Outputs

- **Consumer side** (`CommandConsumer::dequeue()`): Returns `Option<RenderCommand>` -- `Some(cmd)` if a command is available, `None` if the queue is empty.

### Internal State

- **`COMMAND_QUEUE: CommandQueue`** (static mut): A `heapless::spsc::Queue<RenderCommand, 64>` allocated in BSS. Capacity of 64 entries (~16.5 KB SRAM at ~264 bytes per largest variant `RenderMeshPatch`).
- **Type aliases** defined in `render/mod.rs`:
  - `CommandQueue = spsc::Queue<RenderCommand, QUEUE_CAPACITY>`
  - `CommandProducer<'a> = spsc::Producer<'a, RenderCommand>`
  - `CommandConsumer<'a> = spsc::Consumer<'a, RenderCommand>`
- **`QUEUE_CAPACITY: usize = 64`**: Chosen to allow Core 0 to run ahead by up to 64 commands, accommodating the teapot demo's ~290 commands/frame while maintaining overlap between transform (Core 0) and SPI transmission (Core 1).

### Algorithm / Behavior

1. **Allocation**: `COMMAND_QUEUE` is a static mutable `heapless::spsc::Queue` in BSS, zero-initialized.
2. **Split**: `main()` calls `COMMAND_QUEUE.split()` exactly once (unsafe) to obtain `(producer, consumer)`. After this point, `producer` is exclusively owned by Core 0 and `consumer` by Core 1.
3. **Thread safety**: `heapless::spsc::Queue` uses atomic operations for the head and tail pointers, making `Producer` and `Consumer` safe to use from different cores without additional synchronization.
4. **Enqueue (Core 0)**: `enqueue_blocking()` wraps `producer.enqueue()` in a retry loop with NOP spin-wait, implementing backpressure when the queue is full.
5. **Dequeue (Core 1)**: `core1_main()` calls `consumer.dequeue()` each loop iteration. Returns `None` immediately when empty (non-blocking); Core 1 executes a NOP and retries.
6. **Command variants**: `RenderCommand` is a `Copy` enum with variants: `RenderMeshPatch` (~264 bytes: 2x Mat4 + lights + patch ref + flags + clip_flags, primary per-frame command), `SubmitScreenTriangle` (~80 bytes, retained for simple demos), `WaitVsync`, `ClearFramebuffer`, `SetTriMode`, `UploadTexture`.

## Implementation

- `crates/pico-gs-core/src/render/mod.rs`: `RenderCommand` enum and associated structs (shared)
- `crates/pico-gs-rp2350/src/queue.rs`: `CommandQueue`, `CommandProducer`, `CommandConsumer` type aliases; `QUEUE_CAPACITY` constant (RP2350-specific)
- `crates/pico-gs-rp2350/src/main.rs`: `COMMAND_QUEUE` static allocation, `split()` call, `enqueue_blocking()` helper (RP2350-specific)

## Verification

- **Enqueue/dequeue test**: Verify a command enqueued by the producer can be dequeued by the consumer with correct data.
- **Queue full test**: Verify enqueue returns `Err` when 64 items are queued, and `enqueue_blocking()` retries until space is available.
- **Queue empty test**: Verify dequeue returns `None` when the queue is empty.
- **Ordering test**: Verify commands are dequeued in FIFO order.
- **Memory layout test**: Verify `RenderCommand` size does not exceed expected bounds (~264 bytes for `RenderMeshPatch` variant).

## Design Notes

Migrated from speckit module specification.
