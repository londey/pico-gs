# Design Decisions

This document records significant design decisions using a lightweight Architecture Decision Record (ADR) format.

## Template

When adding a new decision, copy this template:

```markdown
## DD-NNN: <Title>

**Date:** YYYY-MM-DD  
**Status:** Proposed | Accepted | Superseded by DD-XXX

### Context

<What is the issue or question that needs a decision?>

### Decision

<What is the decision that was made?>

### Rationale

<Why was this decision made? What alternatives were considered?>

### Consequences

<What are the implications of this decision?>
```

---

## Decisions

<!-- Add decisions below, newest first -->


## DD-001: PS2 Graphics Synthesizer Reference

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-002: ECP5 FPGA Resources

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-003: DVI/HDMI Output

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-004: Decision 1: Language and HAL

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: Rust with `rp235x-hal` (bare-metal, no Embassy)

**Rationale**: The user specified Rust targeting Cortex M33 cores. `rp235x-hal` is the community-standard HAL for RP2350, based on the mature `rp2040-hal`. It provides direct access to SPI, DMA, GPIO, and multicore primitives. A bare-metal approach (vs Embassy async) gives deterministic timing essential for 30+ FPS real-time rendering on the render core.

**Alternatives considered**:
- Embassy-rp: Good for async I/O but cooperative...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-005: Decision 2: Target and Toolchain

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `thumbv8m.main-none-eabihf` target (Cortex-M33 with hardware FPU)

**Rationale**: The RP2350's Cortex-M33 cores have a single-precision hardware FPU and DSP extensions. The `eabihf` target enables hardware float calling conventions, critical for matrix math and lighting performance. The user explicitly chose Cortex M33 over the RP2350's RISC-V cores for this reason.

**Build tools**:
- `probe-rs` (v0.24+) for flash/debug via SWD
- `flip-link` for stack overflow protection
- `defmt...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-006: Decision 3: Dual-Core Communication

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `heapless::spsc::Queue` for the inter-core render command queue, with SIO FIFO doorbell signaling

**Rationale**: The RP2350 provides hardware SIO FIFOs (8-deep, 32-bit) for inter-core signaling, but they're too small for render commands. `heapless::spsc::Queue` is a proven single-producer single-consumer lock-free queue that requires no allocator and no mutexes. The SIO FIFO can signal "new commands available" to avoid busy-polling on Core 1.

**Alternatives considered**:
- `bbqu...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-007: 1. PNG Decoding Library

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `image` crate (v0.25+)

**Rationale**:
The `image` crate is the de facto standard for image processing in Rust and provides the best balance of ergonomics, features, and reliability:

- **High-level API**: Provides simple `open()` and `to_rgba8()` methods that handle all color space conversions automatically
- **Format support**: Handles PNG, JPEG, and other formats through a unified interface, enabling future format extensions
- **Active maintenance**: Widely used (10M+ downloads...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-008: 2. OBJ Parser Library

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `tobj` crate (v4.0+)

**Rationale**:
`tobj` is the clear winner for our use case, offering the best combination of features, reliability, and ecosystem integration:

- **Most popular**: 971K+ all-time downloads, used by 88 crates - proven reliability
- **Triangulation support**: Meshes can be triangulated on-the-fly with trivial triangle fan conversion
- **Complete attribute parsing**: Handles positions, normals, UVs, and vertex colors with optional attribute support
- **Simple AP...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-009: 3. Mesh Splitting Algorithm

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Algorithm Description**:

Based on FR-018 requirements, we implement a **greedy sequential triangle packing** algorithm that fills each patch with triangles until adding the next triangle would violate vertex or index limits.

**Design Rationale**:
- **Simplicity**: Easy to implement, debug, and maintain
- **Predictability**: Deterministic output for the same input mesh
- **Performance**: O(n) time complexity where n is the number of triangles
- **Trade-off**: Accepts some vertex duplication...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-001: PS2 Graphics Synthesizer Reference

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-002: ECP5 FPGA Resources

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-003: DVI/HDMI Output

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-004: Decision 1: Language and HAL

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: Rust with `rp235x-hal` (bare-metal, no Embassy)

**Rationale**: The user specified Rust targeting Cortex M33 cores. `rp235x-hal` is the community-standard HAL for RP2350, based on the mature `rp2040-hal`. It provides direct access to SPI, DMA, GPIO, and multicore primitives. A bare-metal approach (vs Embassy async) gives deterministic timing essential for 30+ FPS real-time rendering on the render core.

**Alternatives considered**:
- Embassy-rp: Good for async I/O but cooperative...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-005: Decision 2: Target and Toolchain

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `thumbv8m.main-none-eabihf` target (Cortex-M33 with hardware FPU)

**Rationale**: The RP2350's Cortex-M33 cores have a single-precision hardware FPU and DSP extensions. The `eabihf` target enables hardware float calling conventions, critical for matrix math and lighting performance. The user explicitly chose Cortex M33 over the RP2350's RISC-V cores for this reason.

**Build tools**:
- `probe-rs` (v0.24+) for flash/debug via SWD
- `flip-link` for stack overflow protection
- `defmt...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-006: Decision 3: Dual-Core Communication

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `heapless::spsc::Queue` for the inter-core render command queue, with SIO FIFO doorbell signaling

**Rationale**: The RP2350 provides hardware SIO FIFOs (8-deep, 32-bit) for inter-core signaling, but they're too small for render commands. `heapless::spsc::Queue` is a proven single-producer single-consumer lock-free queue that requires no allocator and no mutexes. The SIO FIFO can signal "new commands available" to avoid busy-polling on Core 1.

**Alternatives considered**:
- `bbqu...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-007: 1. PNG Decoding Library

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `image` crate (v0.25+)

**Rationale**:
The `image` crate is the de facto standard for image processing in Rust and provides the best balance of ergonomics, features, and reliability:

- **High-level API**: Provides simple `open()` and `to_rgba8()` methods that handle all color space conversions automatically
- **Format support**: Handles PNG, JPEG, and other formats through a unified interface, enabling future format extensions
- **Active maintenance**: Widely used (10M+ downloads...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-008: 2. OBJ Parser Library

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `tobj` crate (v4.0+)

**Rationale**:
`tobj` is the clear winner for our use case, offering the best combination of features, reliability, and ecosystem integration:

- **Most popular**: 971K+ all-time downloads, used by 88 crates - proven reliability
- **Triangulation support**: Meshes can be triangulated on-the-fly with trivial triangle fan conversion
- **Complete attribute parsing**: Handles positions, normals, UVs, and vertex colors with optional attribute support
- **Simple AP...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-009: 3. Mesh Splitting Algorithm

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Algorithm Description**:

Based on FR-018 requirements, we implement a **greedy sequential triangle packing** algorithm that fills each patch with triangles until adding the next triangle would violate vertex or index limits.

**Design Rationale**:
- **Simplicity**: Easy to implement, debug, and maintain
- **Predictability**: Deterministic output for the same input mesh
- **Performance**: O(n) time complexity where n is the number of triangles
- **Trade-off**: Accepts some vertex duplication...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-001: PS2 Graphics Synthesizer Reference

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-002: ECP5 FPGA Resources

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-003: DVI/HDMI Output

**Date:** 2026-02-08
**Status:** Accepted

### Context

...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/001-spi-gpu/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-004: Decision 1: Language and HAL

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: Rust with `rp235x-hal` (bare-metal, no Embassy)

**Rationale**: The user specified Rust targeting Cortex M33 cores. `rp235x-hal` is the community-standard HAL for RP2350, based on the mature `rp2040-hal`. It provides direct access to SPI, DMA, GPIO, and multicore primitives. A bare-metal approach (vs Embassy async) gives deterministic timing essential for 30+ FPS real-time rendering on the render core.

**Alternatives considered**:
- Embassy-rp: Good for async I/O but cooperative...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-005: Decision 2: Target and Toolchain

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `thumbv8m.main-none-eabihf` target (Cortex-M33 with hardware FPU)

**Rationale**: The RP2350's Cortex-M33 cores have a single-precision hardware FPU and DSP extensions. The `eabihf` target enables hardware float calling conventions, critical for matrix math and lighting performance. The user explicitly chose Cortex M33 over the RP2350's RISC-V cores for this reason.

**Build tools**:
- `probe-rs` (v0.24+) for flash/debug via SWD
- `flip-link` for stack overflow protection
- `defmt...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-006: Decision 3: Dual-Core Communication

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `heapless::spsc::Queue` for the inter-core render command queue, with SIO FIFO doorbell signaling

**Rationale**: The RP2350 provides hardware SIO FIFOs (8-deep, 32-bit) for inter-core signaling, but they're too small for render commands. `heapless::spsc::Queue` is a proven single-producer single-consumer lock-free queue that requires no allocator and no mutexes. The SIO FIFO can signal "new commands available" to avoid busy-polling on Core 1.

**Alternatives considered**:
- `bbqu...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/002-rp2350-host-software/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-007: 1. PNG Decoding Library

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `image` crate (v0.25+)

**Rationale**:
The `image` crate is the de facto standard for image processing in Rust and provides the best balance of ergonomics, features, and reliability:

- **High-level API**: Provides simple `open()` and `to_rgba8()` methods that handle all color space conversions automatically
- **Format support**: Handles PNG, JPEG, and other formats through a unified interface, enabling future format extensions
- **Active maintenance**: Widely used (10M+ downloads...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-008: 2. OBJ Parser Library

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Decision**: `tobj` crate (v4.0+)

**Rationale**:
`tobj` is the clear winner for our use case, offering the best combination of features, reliability, and ecosystem integration:

- **Most popular**: 971K+ all-time downloads, used by 88 crates - proven reliability
- **Triangulation support**: Meshes can be triangulated on-the-fly with trivial triangle fan conversion
- **Complete attribute parsing**: Handles positions, normals, UVs, and vertex colors with optional attribute support
- **Simple AP...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---


## DD-009: 3. Mesh Splitting Algorithm

**Date:** 2026-02-08
**Status:** Accepted

### Context

**Algorithm Description**:

Based on FR-018 requirements, we implement a **greedy sequential triangle packing** algorithm that fills each patch with triangles until adding the next triangle would violate vertex or index limits.

**Design Rationale**:
- **Simplicity**: Easy to implement, debug, and maintain
- **Predictability**: Deterministic output for the same input mesh
- **Performance**: O(n) time complexity where n is the number of triangles
- **Trade-off**: Accepts some vertex duplication...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: specs/003-asset-data-prep/research.md

### Consequences

TBD - Document specific trade-offs and implications.

---
