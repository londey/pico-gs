# Project Constitution: ICEpi GPU

## Preamble

This document establishes the non-negotiable principles governing the development of a PS2 GS-inspired graphics processor for the ICEpi Zero development board. These principles ensure architectural consistency, resource discipline, and incremental deliverability.

---

## Article I: Open Toolchain Mandate

All RTL **must** synthesize using the open-source FPGA toolchain:

- **Synthesis**: Yosys
- **Place & Route**: nextpnr-ecp5
- **Programming**: openFPGALoader
- **Simulation**: Verilator or Icarus Verilog with cocotb testbenches

No vendor-specific primitives are permitted except documented ECP5 hard blocks (SERDES, PLL, DSP48, EBR). If a feature requires proprietary IP, it must be flagged and an open alternative found or the feature deferred.

---

## Article II: Resource Budget Discipline

The ECP5-25K provides finite resources. All modules **must** document their utilization:

| Resource | Budget | Headroom Target |
|----------|--------|-----------------|
| LUTs | 24,000 | Use ≤ 20,000 |
| BRAM (EBR) | 1,008 kbit | Use ≤ 800 kbit |
| DSP blocks | 28 | Use ≤ 24 |
| SRAM bandwidth | 200 MB/s | Reserve 80 MB/s for display |

Post-synthesis resource reports **must** be generated and reviewed before integration. Any module exceeding 25% of total budget requires architectural review.

---

## Article III: Bandwidth-First Design

Display refresh has **absolute priority** over all other SRAM access. The memory arbiter must guarantee:

1. No visible tearing or scanline corruption under any draw load
2. Display read-ahead FIFO sufficient to mask arbiter latency
3. Draw operations gracefully degrade (stall) rather than corrupt display

Bandwidth allocation:
- Display scanout: 74 MB/s guaranteed (640×480×32bpp×60Hz)
- Draw operations: Best-effort with remaining bandwidth
- Texture fetch: Shared with draw, prioritized per-pixel

---

## Article IV: Interface Stability Covenant

The SPI register interface is the **contract** with host software. Once a register address and bit field is documented in the specification:

1. The address **shall not** be reassigned
2. Bit field meanings **shall not** change semantically
3. Reserved bits **shall** read as zero and ignore writes

Breaking changes require a major version increment and explicit migration documentation. The host-side driver must be able to detect GPU version via a read-only ID register.

---

## Article V: Test-First Development

**No RTL module shall be integrated without simulation coverage.**

Required test progression:
1. **Unit tests**: Individual module functionality (edge functions, interpolators, etc.)
2. **Integration tests**: Module interactions (arbiter + draw engine + display controller)
3. **Reference tests**: Rasterizer output compared against software reference implementation
4. **Hardware tests**: On-device validation after synthesis

Cocotb is the preferred test framework. Test coverage targets:
- All register read/write paths
- All state machine transitions
- Boundary conditions (screen edges, texture wrap, FIFO full/empty)

---

## Article VI: Incremental Delivery

Features **must** be delivered in layers that provide value at each stage:

| Milestone | Deliverable | Validates |
|-----------|-------------|-----------|
| M1 | SPI register interface | Host communication |
| M2 | Framebuffer clear | SRAM write path |
| M3 | Single pixel write | Coordinate mapping |
| M4 | Flat-shaded triangle | Core rasterizer |
| M5 | DVI output | Display pipeline |
| M6 | Gouraud shading | Color interpolation |
| M7 | Z-buffer | Depth testing |
| M8 | Textured triangle | Full pixel pipeline |

Each milestone **must** be demonstrable on hardware before proceeding. "It works in simulation" is necessary but not sufficient.

---

## Article VII: Simplicity Gate

The GPU targets a **specific, constrained feature set** inspired by PS2 GS:

**In scope:**
- Triangle rasterization with edge walking
- Vertex color interpolation (Gouraud shading)
- Single texture with perspective-correct UV
- Z-buffer depth testing
- Double-buffered framebuffer

**Explicitly out of scope (for initial release):**
- Programmable shaders
- Multiple texture units
- Stencil buffer
- Anti-aliasing
- Alpha blending (deferred to future milestone)

Feature creep is the enemy. Any addition must justify its resource cost and implementation complexity against the core goal: **lit teapot and textured cube on screen**.

---

## Article VIII: Documentation as Artifact

Specifications, register maps, and timing diagrams are **first-class deliverables**, not afterthoughts.

Required documentation:
- Register map with bit-level definitions
- SPI transaction timing diagram
- Memory map showing SRAM allocation
- State machine diagrams for rasterizer and arbiter
- Host-side example code demonstrating triangle submission

Documentation **must** be updated when implementation changes. Stale documentation is a defect.

---

## Article IX: Host Responsibility Boundary

The GPU is a **rasterizer**, not a geometry processor. The host (RP2350) is responsible for:

- Model/view/projection matrix transforms
- Clipping to view frustum
- Perspective division (computing 1/W per vertex)
- Back-face culling
- Scene management and draw ordering

The GPU accepts screen-space vertices with pre-computed attributes. This division of labor matches the PS2 architecture (EE/VU → GS) and keeps the FPGA design tractable.

---

## Amendments

This constitution may be amended by explicit decision when:
1. A fundamental assumption proves incorrect
2. Resource constraints require architectural change
3. A new capability is deemed essential to project goals

Amendments must be documented with rationale and impact assessment.
