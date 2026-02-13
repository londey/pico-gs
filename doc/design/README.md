# Design

*Software Design Description (SDD) for pico-gs*

This directory contains the design specification — the authoritative record of **how** the system accomplishes its requirements.

## System Overview

The pico-gs system is a two-chip 3D graphics pipeline. An RP2350 microcontroller (dual Cortex-M33, 150 MHz) acts as the host processor, performing scene management, vertex transformation, and lighting. It communicates over a 25 MHz SPI bus with a Lattice ECP5 FPGA that implements a fixed-function triangle rasterizer with Gouraud shading, Z-buffering, and texture sampling. The FPGA drives a 640x480 DVI display from a double-buffered framebuffer in 32 MB of external SRAM. A host-side asset build tool prepares textures and meshes from standard formats (PNG, OBJ) for the target hardware.

## Document Description

This document set constitutes the Design Description Document (DDD) for pico-gs. It defines **how** the system accomplishes its requirements — the internal architecture, algorithms, data structures, and control flow of each component. Design units are organized by number range:

| Range | Scope |
|-------|-------|
| UNIT-001 – UNIT-009 | FPGA RTL modules (SPI slave, FIFO, register file, rasterizer, pixel pipeline, SRAM arbiter, display, DVI) |
| UNIT-020 – UNIT-027 | Host firmware modules (scene manager, render executor, GPU driver, transform, lighting, USB, inter-core queue, demo state) |
| UNIT-030 – UNIT-034 | Asset build tool modules (PNG decoder, OBJ parser, mesh splitter, codegen, build orchestrator) |

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
- [UNIT-004: Triangle Setup](unit_004_triangle_setup.md)
- [UNIT-005: Rasterizer](unit_005_rasterizer.md)
- [UNIT-006: Pixel Pipeline](unit_006_pixel_pipeline.md)
- [UNIT-007: SRAM Arbiter](unit_007_sram_arbiter.md)
- [UNIT-008: Display Controller](unit_008_display_controller.md)
- [UNIT-009: DVI TMDS Encoder](unit_009_dvi_tmds_encoder.md)
- [UNIT-020: Core 0 Scene Manager](unit_020_core_0_scene_manager.md)
- [UNIT-021: Core 1 Render Executor](unit_021_core_1_render_executor.md)
- [UNIT-022: GPU Driver Layer](unit_022_gpu_driver_layer.md)
- [UNIT-023: Transformation Pipeline](unit_023_transformation_pipeline.md)
- [UNIT-024: Lighting Calculator](unit_024_lighting_calculator.md)
- [UNIT-025: USB Keyboard Handler](unit_025_usb_keyboard_handler.md)
- [UNIT-026: Inter-Core Queue](unit_026_intercore_queue.md)
- [UNIT-027: Demo State Machine](unit_027_demo_state_machine.md)
- [UNIT-030: PNG Decoder](unit_030_png_decoder.md)
- [UNIT-031: OBJ Parser](unit_031_obj_parser.md)
- [UNIT-032: Mesh Patch Splitter](unit_032_mesh_patch_splitter.md)
- [UNIT-033: Codegen Engine](unit_033_codegen_engine.md)
- [UNIT-034: Build.rs Orchestrator](unit_034_buildrs_orchestrator.md)
- [UNIT-035: PC SPI Driver (FT232H)](unit_035_pc_spi_driver.md)
- [UNIT-036: PC Input Handler](unit_036_pc_input_handler.md)
<!-- TOC-END -->
