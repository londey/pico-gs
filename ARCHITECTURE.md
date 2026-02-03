# Architecture & Design Principles

**Version**: 1.0.0
**Last Updated**: 2026-02-03

## Overview

This document captures the architectural decisions and design principles specific to the pico-gs project: an FPGA-based 3D graphics synthesizer for the ICEpi platform, inspired by the PlayStation 2 Graphics Synthesizer (GS).

**Relationship to Constitution**: The [constitution.md](constitution.md) defines *how* we build software (coding practices). This document defines *what* we're building and *why* (design constraints and architectural philosophy).

---

## Design Philosophy

The pico-gs targets a **specific, constrained feature set** to deliver a functional, demonstrable 3D graphics pipeline within FPGA resource limits.

**Core goal**: Render a lit teapot and textured cube on screen at 640×480 @ 60Hz.

### In Scope (MVP)
- Triangle rasterization with edge walking
- Vertex color interpolation (Gouraud shading)
- Single texture with perspective-correct UV mapping
- Z-buffer depth testing
- Double-buffered framebuffer
- DVI/HDMI output via GPDI connector

### Explicitly Out of Scope (Initial Release)
- Programmable shaders
- Multiple texture units
- Stencil buffer
- Anti-aliasing (MSAA/FXAA)
- Alpha blending (deferred to future milestone)
- Geometry processing (transforms done on host)

**Rationale**: Feature discipline keeps the project tractable within resource constraints and delivers a working system faster.

---

## Platform Constraints

### Hardware Platform: ICEpi Zero

**FPGA**: Lattice ECP5-25K
- 24,000 LUTs
- 1,008 Kbit Block RAM (EBR)
- 28 DSP slices
- Open-source toolchain support

**Host**: Raspberry Pi RP2350
- Dual Cortex-M33 @ 150 MHz
- 520 KB SRAM
- 4 MB Flash
- USB host capability

**External Memory**: 4 MB SPI PSRAM
- Shared between framebuffer and texture storage
- ~200 MB/s bandwidth @ 100 MHz SPI

### Toolchain Mandate

All RTL **must** synthesize using the open-source FPGA toolchain:
- **Synthesis**: Yosys
- **Place & Route**: nextpnr-ecp5
- **Programming**: openFPGALoader
- **Simulation**: Verilator or Icarus Verilog with cocotb testbenches

**No vendor-specific primitives** are permitted except documented ECP5 hard blocks:
- SERDES (for DVI output)
- PLL (clock generation)
- DSP48 (multiply-accumulate for interpolation)
- EBR (on-chip block RAM)

**Rationale**: Open toolchain ensures reproducibility, avoids vendor lock-in, and aligns with maker/educational community values.

---

## Resource Budget

The ECP5-25K provides finite resources. Design decisions must respect these limits.

| Resource | Total | Budget Target | Headroom |
|----------|-------|---------------|----------|
| LUTs | 24,000 | ≤ 20,000 (83%) | 4,000 |
| BRAM (EBR) | 1,008 kbit | ≤ 800 kbit (79%) | 208 kbit |
| DSP blocks | 28 | ≤ 24 (86%) | 4 |
| SRAM bandwidth | 200 MB/s | Display: 74 MB/s<br>Draw: 126 MB/s | — |

### Resource Discipline

- Post-synthesis resource reports **must** be generated for all modules
- Any module exceeding 25% of total budget requires architectural review
- Favor algorithmic efficiency over brute-force parallelism
- Use DSP blocks for multiply operations where possible (saves LUTs)

---

## System Architecture

### Host-GPU Division of Responsibility

The GPU is a **rasterizer**, not a geometry processor. This mirrors the PS2 architecture (EE/VU → GS).

**Host (RP2350) responsibilities:**
- Model/view/projection matrix transforms
- Clipping to view frustum
- Perspective division (computing 1/W per vertex)
- Back-face culling
- Scene management and draw ordering
- Asset loading and management

**GPU (FPGA) responsibilities:**
- Triangle rasterization (screen-space)
- Vertex attribute interpolation (color, UV, depth)
- Texture sampling
- Depth testing
- Framebuffer writes
- Display scanout

**Interface**: SPI register-based command interface. Host writes vertex data and draw commands; GPU rasterizes to framebuffer.

**Rationale**: This division keeps the FPGA design tractable and leverages the RP2350's computational capabilities for geometry processing.

---

## Memory Architecture

### SRAM Allocation (4 MB total)

| Region | Size | Purpose |
|--------|------|---------|
| Framebuffer 0 | 1.2 MB | 640×480×32bpp (RGBA8888) |
| Framebuffer 1 | 1.2 MB | 640×480×32bpp (double buffer) |
| Z-buffer | 600 KB | 640×480×16bpp (fixed-point depth) |
| Texture cache | 1 MB | Runtime texture data |

### Bandwidth-First Design

Display refresh has **absolute priority** over all other SRAM access.

**Bandwidth allocation:**
- Display scanout: **74 MB/s guaranteed** (640×480×32bpp×60Hz)
- Draw operations: Best-effort with remaining ~126 MB/s
- Texture fetch: Shared with draw, prioritized per-pixel

**Memory arbiter must guarantee:**
1. No visible tearing or scanline corruption under any draw load
2. Display read-ahead FIFO sufficient to mask arbiter latency (≥ 2 scanlines)
3. Draw operations gracefully stall rather than corrupt display

**Rationale**: Visual glitches are unacceptable in a graphics system. Bandwidth discipline prevents hard-to-debug race conditions.

---

## Interface Stability

The SPI register interface is the **contract** between host software and GPU hardware.

### Versioning Rules

Once a register address and bit field is documented:
1. The address **shall not** be reassigned
2. Bit field semantics **shall not** change
3. Reserved bits **shall** read as zero and ignore writes

### Version Detection

- GPU ID register (read-only) contains:
  - Major version (breaking changes)
  - Minor version (backward-compatible additions)
  - Patch version (bug fixes)
- Host driver checks version at initialization
- Incompatible versions fail gracefully with error message

### Breaking Changes

Breaking changes require:
1. Major version increment
2. Explicit migration documentation
3. Feature flag or capability query mechanism

**Rationale**: Interface stability enables independent development of host firmware and FPGA bitstream. Clear versioning prevents mysterious runtime failures.

---

## Development Milestones

Features are delivered in layers that provide incremental value and validation.

| Milestone | Deliverable | Validates |
|-----------|-------------|-----------|
| M1 | SPI register interface | Host communication working |
| M2 | Framebuffer clear | SRAM write path functional |
| M3 | Single pixel write | Coordinate mapping correct |
| M4 | Flat-shaded triangle | Core rasterizer algorithm |
| M5 | DVI output | Display pipeline end-to-end |
| M6 | Gouraud shading | Color interpolation working |
| M7 | Z-buffer | Depth testing functional |
| M8 | Textured triangle | Full pixel pipeline complete |

**Principle**: Each milestone **must** be demonstrable on hardware before proceeding. Simulation is necessary but not sufficient.

**Rationale**: Hardware bring-up is unpredictable. Incremental validation catches integration issues early and maintains working system state.

---

## Documentation Requirements

### Required Artifacts

**Hardware interface specifications:**
- Register map with bit-level definitions
- SPI transaction timing diagram
- Memory map showing SRAM allocation
- DVI timing parameters and constraints

**Design documentation:**
- State machine diagrams for rasterizer and arbiter
- Pipeline stage diagram with latency annotations
- Interpolation algorithm description with fixed-point precision

**Host integration:**
- Example code demonstrating triangle submission
- Asset format specifications (meshes, textures)
- Performance characteristics and limitations

**Rationale**: Specifications are executable documentation. They enable independent implementation of host and GPU components.

---

## Future Directions (Post-MVP)

Potential enhancements after initial release:

### Performance
- Tile-based rendering for bandwidth optimization
- Hardware mipmap generation
- Texture compression (PVRTC/ETC2)

### Features
- Alpha blending (over/additive modes)
- Multiple texture units (multi-texturing)
- Simple post-processing (scanline effects, dithering)
- Line and point primitive support

### Tooling
- Real-time performance counters
- GPU command stream capture/replay
- Waveform-based debugging interface

**Note**: These are aspirational. Each requires resource analysis and may be deferred indefinitely to maintain project scope discipline.

---

## Amendment History

- **1.0.0** (2026-02-03): Initial architecture document, extracted from constitution v2.0.0
