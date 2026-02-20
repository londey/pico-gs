# Requirements

*Software Requirements Specification (SRS) for pico-gs*

This directory contains the system requirements specification — the authoritative record of **what** the system must do.

## System Overview

The pico-gs system is a two-chip 3D graphics pipeline. An RP2350 microcontroller (dual Cortex-M33, 150 MHz) acts as the host processor, performing scene management, vertex transformation, and lighting. It communicates over a 25 MHz SPI bus with a Lattice ECP5 FPGA that implements a fixed-function triangle rasterizer with Gouraud shading, Z-buffering, and texture sampling. The FPGA drives a 640x480 DVI display from a double-buffered framebuffer in 32 MB of external SRAM. A host-side asset build tool prepares textures and meshes from standard formats (PNG, OBJ) for the target hardware.

## Document Description

This document set constitutes the System Requirements Specification (SRS) for pico-gs. It defines **what** the system must do — every externally observable behavior, performance target, and resource constraint — without prescribing implementation. Requirements are organized into functional groups by number range:

| Range | Scope |
|-------|-------|
| REQ-001.01 – REQ-029 | GPU hardware capabilities (rendering, display, memory) |
| REQ-011.01 – REQ-011.03 | Non-functional requirements (performance, resources, reliability) |
| REQ-100 – REQ-004.02 | Host firmware capabilities (scene management, driver, rendering features) |
| REQ-012.01 – REQ-012.03 | Asset build tool capabilities |

Each requirement is individually testable and traceable to the design units (UNIT-NNN) that implement it and the interfaces (INT-NNN) it depends on.

## Purpose

Each requirement document defines a single, testable system behavior using the condition/response pattern:

> **When** [condition], the system **SHALL/SHOULD/MAY** [behavior].

Requirements are traceable: each is allocated to design units (`UNIT-NNN`) and references interfaces (`INT-NNN`). Together they form a complete, verifiable description of system capability.

## Conventions

- **Naming:** `req_NNN_<name>.md` — 3-digit zero-padded number, lowercase, underscores
- **Child requirements:** `req_NNN.NN_<name>.md` — dot-notation encodes parent (e.g., `req_004.01_voltage_levels.md`)
- **Create new:** `.syskit/scripts/new-req.sh <name>` or `.syskit/scripts/new-req.sh --parent REQ-NNN <name>`
- **Cross-references:** Use `REQ-NNN` or `REQ-NNN.NN` identifiers (derived from filename)
- **Hierarchy:** Parent relationship is visible in the ID; `Parent Requirements` field provides explicit back-reference

## Framework Documents

- **quality_metrics.md** — Quality attributes, targets, and measurement methods
- **states_and_modes.md** — System operational states, modes, and transitions

## Table of Contents

<!-- TOC-START -->
- [States and Modes](states_and_modes.md)
- [Quality Metrics](quality_metrics.md)
- [REQ-001.01: Basic Host Communication](req_001.01_basic_host_communication.md)
- [REQ-001.02: Memory Upload Interface](req_001.02_memory_upload_interface.md)
- [REQ-001.03: SPI Electrical Interface](req_001.03_spi_electrical_interface.md)
- [REQ-001.04: Command Buffer FIFO](req_001.04_command_buffer_fifo.md)
- [REQ-001.05: Vertex Submission Protocol](req_001.05_vertex_submission_protocol.md)
- [REQ-001.06: GPU Flow Control](req_001.06_gpu_flow_control.md)
- [REQ-001: GPU SPI Hardware](req_001_gpu_spi_hardware.md)
- [REQ-002.01: Flat Shaded Triangle](req_002.01_flat_shaded_triangle.md)
- [REQ-002.02: Gouraud Shaded Triangle](req_002.02_gouraud_shaded_triangle.md)
- [REQ-002.03: Rasterization Algorithm](req_002.03_rasterization_algorithm.md)
- [REQ-002: Rasterizer](req_002_rasterizer.md)
- [REQ-003.01: Textured Triangle](req_003.01_textured_triangle.md)
- [REQ-003.02: Multi-Texture Rendering](req_003.02_multitexture_rendering.md)
- [REQ-003.03: Compressed Textures](req_003.03_compressed_textures.md)
- [REQ-003.04: Swizzle Patterns](req_003.04_swizzle_patterns.md)
- [REQ-003.05: UV Wrapping Modes](req_003.05_uv_wrapping_modes.md)
- [REQ-003.06: Texture Sampling](req_003.06_texture_sampling.md)
- [REQ-003.07: Texture Mipmapping](req_003.07_texture_mipmapping.md)
- [REQ-003.08: Texture Cache](req_003.08_texture_cache.md)
- [REQ-003: Texture Samplers](req_003_texture_samplers.md)
- [REQ-004.01: Color Combiner](req_004.01_color_combiner.md)
- [REQ-004.02: Extended Precision Fragment Processing](req_004.02_extended_precision_fragment_processing.md)
- [REQ-004: Fragment Processor / Color Combiner](req_004_fragment_processor.md)
- [REQ-005.01: Framebuffer Management](req_005.01_framebuffer_management.md)
- [REQ-005.02: Depth Tested Triangle](req_005.02_depth_tested_triangle.md)
- [REQ-005.03: Alpha Blending](req_005.03_alpha_blending.md)
- [REQ-005.04: Enhanced Z-Buffer](req_005.04_enhanced_zbuffer.md)
- [REQ-005.05: Triangle-Based Clearing](req_005.05_trianglebased_clearing.md)
- [REQ-005.06: Framebuffer Format](req_005.06_framebuffer_format.md)
- [REQ-005.07: Z-Buffer Operations](req_005.07_zbuffer_operations.md)
- [REQ-005.08: Clear Framebuffer](req_005.08_clear_framebuffer.md)
- [REQ-005.09: Double-Buffered Rendering](req_005.09_doublebuffered_rendering.md)
- [REQ-005.10: Ordered Dithering](req_005.10_ordered_dithering.md)
- [REQ-005: Blend / Frame Buffer Store](req_005_blend_framebuffer.md)
- [REQ-006.01: Display Output](req_006.01_display_output.md)
- [REQ-006.02: Display Output Timing](req_006.02_display_output_timing.md)
- [REQ-006.03: Color Grading LUT](req_006.03_color_grading_lut.md)
- [REQ-006: Screen Scan Out](req_006_screen_scan_out.md)
- [REQ-007.01: Matrix Transformation Pipeline](req_007.01_matrix_transformation.md)
- [REQ-007.02: Render Mesh Patch](req_007.02_render_mesh_patch.md)
- [REQ-007: Vertex Transformation](req_007_vertex_transformation.md)
- [REQ-008.01: Scene Management](req_008.01_scene_management.md)
- [REQ-008.02: Render Pipeline Execution](req_008.02_render_pipeline_execution.md)
- [REQ-008.03: Scene Graph Management](req_008.03_scene_graph_management.md)
- [REQ-008.04: Render Command Queue](req_008.04_render_command_queue.md)
- [REQ-008.05: Default Demo Startup](req_008.05_default_demo_startup.md)
- [REQ-008: Scene Graph / ECS](req_008_scene_graph.md)
- [REQ-009.01: USB Keyboard Input](req_009.01_usb_keyboard_input.md)
- [REQ-009.02: Gamepad Input](req_009.02_gamepad_input.md)
- [REQ-009: Keyboard and Controller Input](req_009_input.md)
- [REQ-010.01: PC Debug Host](req_010.01_pc_debug_host.md)
- [REQ-010: GPU Debug GUI](req_010_debug_gui.md)
- [REQ-011.01: Performance Targets](req_011.01_performance_targets.md)
- [REQ-011.02: Resource Constraints](req_011.02_resource_constraints.md)
- [REQ-011.03: Reliability Requirements](req_011.03_reliability_requirements.md)
- [REQ-011: System Constraints](req_011_system_constraints.md)
- [REQ-012.01: PNG Asset Processing](req_012.01_png_asset_processing.md)
- [REQ-012.02: OBJ Mesh Processing](req_012.02_obj_mesh_processing.md)
- [REQ-012.03: Asset Build Orchestration](req_012.03_asset_build_orchestration.md)
- [REQ-012: Asset Pipeline](req_012_asset_pipeline.md)
- [REQ-013.01: GPU Communication Protocol](req_013.01_gpu_communication_protocol.md)
- [REQ-013.02: Upload Texture](req_013.02_upload_texture.md)
- [REQ-013.03: VSync Synchronization](req_013.03_vsync_synchronization.md)
- [REQ-013: Host SPI Driver](req_013_host_spi_driver.md)
- [REQ-014.01: Lightmapped Static Mesh](req_014.01_lightmapped_static_mesh.md)
- [REQ-014.02: Static Mesh with Directional Lighting](req_014.02_static_mesh_directional_lighting.md)
- [REQ-014.03: Skinned Mesh (3-Bone)](req_014.03_skinned_mesh.md)
- [REQ-014.04: Particle System](req_014.04_particle_system.md)
- [REQ-014: Render Modes](req_014_render_modes.md)
<!-- TOC-END -->
