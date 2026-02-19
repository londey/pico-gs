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
- [REQ-001.01: Basic Host Communication](req_001_basic_host_communication.md)
- [REQ-005.01: Framebuffer Management](req_002_framebuffer_management.md)
- [REQ-002.01: Flat Shaded Triangle](req_003_flat_shaded_triangle.md)
- [REQ-002.02: Gouraud Shaded Triangle](req_004_gouraud_shaded_triangle.md)
- [REQ-005.02: Depth Tested Triangle](req_005_depth_tested_triangle.md)
- [REQ-003.01: Textured Triangle](req_006_textured_triangle.md)
- [REQ-006.01: Display Output](req_007_display_output.md)
- [REQ-003.02: Multi-Texture Rendering](req_008_multitexture_rendering.md)
- [REQ-004.01: Color Combiner](req_009_texture_blend_modes.md)
- [REQ-003.03: Compressed Textures](req_010_compressed_textures.md)
- [REQ-003.04: Swizzle Patterns](req_011_swizzle_patterns.md)
- [REQ-003.05: UV Wrapping Modes](req_012_uv_wrapping_modes.md)
- [REQ-005.03: Alpha Blending](req_013_alpha_blending.md)
- [REQ-005.04: Enhanced Z-Buffer](req_014_enhanced_zbuffer.md)
- [REQ-001.02: Memory Upload Interface](req_015_memory_upload_interface.md)
- [REQ-005.05: Triangle-Based Clearing](req_016_trianglebased_clearing.md)
- [REQ-001.03: SPI Electrical Interface](req_020_spi_electrical_interface.md)
- [REQ-001.04: Command Buffer FIFO](req_021_command_buffer_fifo.md)
- [REQ-001.05: Vertex Submission Protocol](req_022_vertex_submission_protocol.md)
- [REQ-002.03: Rasterization Algorithm](req_023_rasterization_algorithm.md)
- [REQ-003.06: Texture Sampling](req_024_texture_sampling.md)
- [REQ-005.06: Framebuffer Format](req_025_framebuffer_format.md)
- [REQ-006.02: Display Output Timing](req_026_display_output_timing.md)
- [REQ-005.07: Z-Buffer Operations](req_027_zbuffer_operations.md)
- [REQ-028: Alpha Blending](req_028_alpha_blending.md)
- [REQ-029: Memory Upload Interface](req_029_memory_upload_interface.md)
- [REQ-011.01: Performance Targets](req_050_performance_targets.md)
- [REQ-011.02: Resource Constraints](req_051_resource_constraints.md)
- [REQ-011.03: Reliability Requirements](req_052_reliability_requirements.md)
- [REQ-100: Host Firmware Architecture](req_100_host_firmware_architecture.md)
- [REQ-008.01: Scene Management](req_101_scene_management.md)
- [REQ-008.02: Render Pipeline Execution](req_102_render_pipeline_execution.md)
- [REQ-009.01: USB Keyboard Input](req_103_usb_keyboard_input.md)
- [REQ-007.01: Matrix Transformation Pipeline](req_104_matrix_transformation.md)
- [REQ-013.01: GPU Communication Protocol](req_105_gpu_communication_protocol.md)
- [REQ-010.01: PC Debug Host](req_106_pc_debug_host.md)
- [REQ-110: GPU Initialization](req_110_gpu_initialization.md)
- [REQ-111: Dual-Core Architecture](req_111_dualcore_architecture.md)
- [REQ-008.03: Scene Graph Management](req_112_scene_graph_management.md)
- [REQ-113: USB Keyboard Input](req_113_usb_keyboard_input.md)
- [REQ-008.04: Render Command Queue](req_114_render_command_queue.md)
- [REQ-007.02: Render Mesh Patch](req_115_render_mesh_patch.md)
- [REQ-013.02: Upload Texture](req_116_upload_texture.md)
- [REQ-013.03: VSync Synchronization](req_117_vsync_synchronization.md)
- [REQ-005.08: Clear Framebuffer](req_118_clear_framebuffer.md)
- [REQ-001.06: GPU Flow Control](req_119_gpu_flow_control.md)
- [REQ-120: Async Data Loading](req_120_async_data_loading.md)
- [REQ-121: Async SPI Transmission](req_121_async_spi_transmission.md)
- [REQ-008.05: Default Demo Startup](req_122_default_demo_startup.md)
- [REQ-005.09: Double-Buffered Rendering](req_123_doublebuffered_rendering.md)
- [REQ-003.07: Texture Mipmapping](req_130_texture_mipmapping.md)
- [REQ-003.08: Texture Cache](req_131_texture_cache.md)
- [REQ-005.10: Ordered Dithering](req_132_ordered_dithering.md)
- [REQ-006.03: Color Grading LUT](req_133_color_grading_lut.md)
- [REQ-004.02: Extended Precision Fragment Processing](req_134_extended_precision_fragment_processing.md)
- [REQ-012.01: PNG Asset Processing](req_200_png_asset_processing.md)
- [REQ-012.02: OBJ Mesh Processing](req_201_obj_mesh_processing.md)
- [REQ-012.03: Asset Build Orchestration](req_202_asset_build_orchestration.md)
<!-- TOC-END -->
