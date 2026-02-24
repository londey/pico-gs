# Verification

*Software Verification Description (SVD) for <system name>*

This directory contains the verification specifications — the authoritative record of **how** the system's requirements are verified.

## System Overview

<Brief description of the system: what it is, what it does, and its operational context.>

## Document Description

<Brief overview of what this document covers and how it is organized.>

## Purpose

Each verification document describes a test or analysis procedure that demonstrates a requirement is satisfied. Verification documents link back to requirements (`REQ-NNN`) and design units (`UNIT-NNN`), completing the traceability chain from requirement through design to test.

Verification methods:

- **Test** — Verified by executing a test procedure with defined pass/fail criteria
- **Analysis** — Verified by technical evaluation (calculation, simulation, modeling)
- **Inspection** — Verified by examination of design artifacts
- **Demonstration** — Verified by operating the system under specified conditions

## Conventions

- **Naming:** `ver_NNN_<name>.md` — 3-digit zero-padded number, lowercase, underscores
- **Child verifications:** `ver_NNN.NN_<name>.md` — dot-notation encodes parent (e.g., `ver_003.01_edge_cases.md`)
- **Create new:** `.syskit/scripts/new-ver.sh <name>` or `.syskit/scripts/new-ver.sh --parent VER-NNN <name>`
- **Cross-references:** Use `VER-NNN` or `VER-NNN.NN` identifiers (derived from filename)
- **Traceability:** Each verification document references the requirements it verifies

## Framework Documents

- **test_strategy.md** — Cross-cutting test strategy: frameworks, tools, coverage goals, and approaches

## Table of Contents

<!-- TOC-START -->
- [Test Strategy](test_strategy.md)
<!-- TOC-END -->

## Planned Verification Documents

The following VER documents are planned but not yet created.
Each file should be created from `ver_000_template.md` and placed in this directory.

### Unit Testbenches (VER-001 through VER-005)

| ID | Filename (to create) | Testbench | Verifies |
|----|----------------------|-----------|---------|
| VER-001 | `ver_001_rasterizer.md` | `tb_rasterizer` | REQ-002.03, UNIT-005 |
| VER-002 | `ver_002_early_z.md` | `tb_early_z` | REQ-005.02, UNIT-006 |
| VER-003 | `ver_003_register_file.md` | `tb_register_file` | UNIT-003 |
| VER-004 | `ver_004_color_combiner.md` | `color_combiner_tb` | REQ-004.01, UNIT-010 (blocked: UNIT-010 is WIP) |
| VER-005 | `ver_005_texture_decoder.md` | `texture_decoder_tb` | REQ-003.01, UNIT-006 |

### Golden Image Integration Tests (VER-010 through VER-013)

| ID | Filename (to create) | Scene | Verifies |
|----|----------------------|-------|---------|
| VER-010 | `ver_010_gouraud_triangle.md` | Multi-colored (Gouraud) triangle | REQ-002.02 |
| VER-011 | `ver_011_depth_tested_triangles.md` | Depth-tested overlapping triangles | REQ-005.02 |
| VER-012 | `ver_012_textured_triangle.md` | Textured triangle | REQ-003.01 |
| VER-013 | `ver_013_color_combined_output.md` | Blended/color-combined output | REQ-004.01 |

These tests require the common integration simulation harness (`spi_gpu/tests/harness/`) described in `test_strategy.md`.
