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
