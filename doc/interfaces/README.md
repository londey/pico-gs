# Interfaces

*Interface Design Description (IDD) for pico-gs*

This directory contains the interface specifications — the authoritative record of **contracts** between components and with external systems.

## System Overview

The pico-gs system is a two-chip 3D graphics pipeline. An RP2350 microcontroller (dual Cortex-M33, 150 MHz) acts as the host processor, performing scene management, vertex transformation, and lighting. It communicates over a 25 MHz SPI bus with a Lattice ECP5 FPGA that implements a fixed-function triangle rasterizer with Gouraud shading, Z-buffering, and texture sampling. The FPGA drives a 640x480 DVI display from a double-buffered framebuffer in 32 MB of external SRAM. A host-side asset build tool prepares textures and meshes from standard formats (PNG, OBJ) for the target hardware.

## Document Description

This document set constitutes the Interface Control Document (ICD) for pico-gs. It defines the **contracts** between system components and with external standards — data formats, protocols, APIs, and signal definitions that both sides of a boundary agree on. Interfaces are organized by number range:

| Range | Scope |
|-------|-------|
| INT-001 – INT-002 | External standards (SPI, DVI) |
| INT-010 – INT-014 | Hardware interfaces between host and FPGA (register map, memory layout, SPI framing, GPIO, textures) |

Each interface names a Provider and one or more Consumers, enabling components to be developed and tested independently against the contract.

## Purpose

Each interface document defines a precise contract: data formats, protocols, APIs, or signal definitions that components agree on. Interfaces are the bridge between requirements (what) and design (how), ensuring components can be developed and tested independently.

Interface types:

- **Internal** — Defined by this project (register maps, packet formats, internal APIs)
- **External Standard** — Defined by an external spec (PNG, SPI, USB)
- **External Service** — Defined by an external service (REST API, cloud endpoint)

## Conventions

- **Naming:** `int_NNN_<name>.md` — 3-digit zero-padded number, lowercase, underscores
- **Create new:** `.syskit/scripts/new-int.sh <name>`
- **Cross-references:** Use `INT-NNN` identifiers (derived from filename)
- **Parties:** Each interface has a Provider and one or more Consumers

## Table of Contents

<!-- TOC-START -->
- [INT-001: SPI Mode 0 Protocol](int_001_spi_mode_0_protocol.md)
- [INT-002: DVI TMDS Output](int_002_dvi_tmds_output.md)
- [INT-010: GPU Register Map](int_010_gpu_register_map.md)
- [INT-011: SDRAM Memory Layout](int_011_sram_memory_layout.md)
- [INT-012: SPI Transaction Format](int_012_spi_transaction_format.md)
- [INT-013: GPIO Status Signals](int_013_gpio_status_signals.md)
- [INT-014: Texture Memory Layout](int_014_texture_memory_layout.md)
<!-- TOC-END -->

## Interface Summaries

| Interface | Scope |
| --------- | ----- |
| INT-001 | SPI Mode 0 electrical and protocol contract between host MCU and FPGA |
| INT-002 | DVI TMDS output signal contract for the display subsystem |
| INT-010 | GPU register map: 7-bit address space, 64-bit registers. Texture registers: TEXn_CFG (format fixed at INDEXED8_2X2 = 4'd0, PALETTE_IDX[24], dimensions, wrap, filter), PALETTE0/PALETTE1 (0x12/0x13) with BASE_ADDR×512 and self-clearing LOAD_TRIGGER |
| INT-011 | SDRAM memory layout: framebuffer, Z-buffer, texture index arrays, palette blobs |
| INT-012 | SPI transaction framing: 72-bit frames (1 R/W̄ + 7 addr + 64 data) |
| INT-013 | GPIO status signals: VSYNC, IRQ, flow control |
| INT-014 | Texture memory layout: single format INDEXED8_2X2 — 4×4 index blocks (8-bit index per apparent 2×2 tile, 16 bytes per block); palette blob (256 entries × 4 RGBA8888 quadrant colors = 4096 bytes, addressed at BASE_ADDR×512) |
