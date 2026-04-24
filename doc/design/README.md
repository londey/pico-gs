# Design

*Software Design Description (SDD) for pico-gs*

This directory contains the design specification — the authoritative record of **how** the system accomplishes its requirements.

## System Overview

The pico-gs system is a two-chip 3D graphics pipeline. An RP2350 microcontroller (dual Cortex-M33, 150 MHz) acts as the host processor, performing scene management, vertex transformation, and lighting. It communicates over a 25 MHz SPI bus with a Lattice ECP5 FPGA that implements a fixed-function triangle rasterizer with Gouraud shading, Z-buffering, and texture sampling. The FPGA drives a 640x480 DVI display from a double-buffered framebuffer in 32 MB of external SRAM. A host-side asset build tool prepares textures and meshes from standard formats (PNG, OBJ) for the target hardware.

## Document Description

This document set constitutes the Design Description Document (DDD) for pico-gs. It defines **how** the system accomplishes its requirements — the internal architecture, algorithms, data structures, and control flow of each component. Design units are organized by number range:

| Range | Scope |
|-------|-------|
| UNIT-001 – UNIT-010 | FPGA RTL modules (SPI slave, FIFO, register file, rasterizer, pixel pipeline, SRAM arbiter, display, DVI, color combiner) |

Each design unit traces to the requirements it satisfies and the interfaces it provides or consumes, and links directly to source and test files for full traceability.

## Purpose

Each design unit document describes a cohesive piece of the system: its purpose, the requirements it satisfies, the interfaces it provides and consumes, and its internal behavior. Design units map directly to implementation — each links to source files and test files, enabling full traceability from requirement through design to code.

A design unit might be a hardware module, a source file, a library, or a logical grouping of related code.

## Conventions

- **Naming:** `unit_NNN_<name>.md` — 3-digit zero-padded number, lowercase, underscores
- **Create new:** `.syskit/scripts/new-unit.sh <name>`
- **Cross-references:** Use `UNIT-NNN` identifiers (derived from filename)
- **Traceability:** Source files link back via `Spec-ref` comments; use `impl-stamp.sh` to keep hashes current

## Framework Documents

- **concept_of_execution.md** — System runtime behavior, startup, data flow, and event handling
- **design_decisions.md** — Architecture Decision Records (ADR format)

## Table of Contents

<!-- TOC-START -->
- [Design Decisions](design_decisions.md)
- [Concept of Execution](concept_of_execution.md)
- [UNIT-001: SPI Slave Controller](unit_001_spi_slave_controller.md)
- [UNIT-002: Command FIFO](unit_002_command_fifo.md)
- [UNIT-003: Register File](unit_003_register_file.md)
- [UNIT-005.01: Triangle Setup](unit_005.01_triangle_setup.md)
- [UNIT-005.02: Edge Setup](unit_005.02_edge_setup.md)
- [UNIT-005.03: Derivative Pre-computation](unit_005.03_derivative_precomputation.md)
- [UNIT-005.04: Attribute Accumulation](unit_005.04_attribute_accumulation.md)
- [UNIT-005.05: Iteration FSM](unit_005.05_iteration_fsm.md)
- [UNIT-005.06: Hi-Z Block Metadata](unit_005.06_hiz_block_metadata.md)
- [UNIT-005: Rasterizer](unit_005_rasterizer.md)
- [UNIT-006: Pixel Pipeline](unit_006_pixel_pipeline.md)
- [UNIT-007: Memory Arbiter](unit_007_sram_arbiter.md)
- [UNIT-008: Display Controller](unit_008_display_controller.md)
- [UNIT-009: DVI TMDS Encoder](unit_009_dvi_tmds_encoder.md)
- [UNIT-010: Color Combiner](unit_010_color_combiner.md)
- [UNIT-011.01: UV Coordinate Processing](unit_011.01_uv_coordinate_processing.md)
- [UNIT-011.03: L1 Decompressed Cache](unit_011.03_l1_decompressed_cache.md)
- [UNIT-011.04: Block Decompressor](unit_011.04_block_decompressor.md)
- [UNIT-011.05: L2 Compressed Cache](unit_011.05_l2_compressed_cache.md)
- [UNIT-011: Texture Sampler](unit_011_texture_sampler.md)
- [UNIT-012: Z-Buffer Tile Cache](unit_012_zbuf_tile_cache.md)
<!-- TOC-END -->
