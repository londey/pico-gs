---
name: gpu-team
description: >
  Spawn a four-person GPU development team with coordinator, verilog specialist,
  rust digital twin specialist, and verification specialist. Use when a task
  benefits from parallel RTL + twin + verification work.
user-invocable: true
---

# GPU Development Team

Create an agent team for the following task:

**Task:** $ARGUMENTS

## Team structure

Spawn these five teammates using their agent definitions:

1. **gpu-coordinator** — Team lead. Decomposes the task, assigns work, resolves cross-cutting issues, and runs final `./build.sh --check` before declaring complete.

2. **syskit-specialist** — Specification documentation. Keeps requirement, interface, design, and verification docs under `doc/` in sync with what the team implements. Updates Spec-ref hashes and maintains traceability.

3. **verilog-specialist** — SystemVerilog RTL implementation. Works on `components/*/rtl/src/` modules. Reads the digital twin first, then implements RTL to match it bit-exactly. Follows `.claude/skills/claude-skill-verilog/SKILL.md` and `.claude/skills/ecp5-sv-yosys-verilator/SKILL.md`.

4. **rust-twin-specialist** — Digital twin implementation. Works on `components/*/twin/` crates and `integration/gs-twin/`. Implements the bit-accurate algorithm in Rust first. Follows `.claude/skills/claude-skill-rust/SKILL.md`. Generates expected outputs for verification.

5. **verification-specialist** — Verilator testbenches and synthesis validation. Works on `components/*/rtl/tests/` and `integration/harness/`. Compares RTL output against twin output using shared `.hex` stimulus. Follows `.claude/skills/claude-skill-cpp/SKILL.md`.

## Workflow

The team follows this order:

1. **Coordinator** reads relevant specs (`doc/design/`, `pipeline/pipeline.yaml`, `ARCHITECTURE.md`) and decomposes the task
2. **Rust-twin-specialist** implements or updates the twin algorithm (this defines the expected behavior)
3. **Verilog-specialist** implements RTL to match the twin (can start in parallel if the twin interface is stable)
4. **Verification-specialist** writes testbenches and runs RTL-vs-twin comparison
5. **Syskit-specialist** updates docs under `doc/` to reflect what was implemented, stamps Spec-ref hashes
6. **Coordinator** runs `./build.sh --check` and confirms all tests pass

## Rules

- The digital twin is the authoritative algorithm spec — RTL must match it
- Shared `.hex` stimulus files feed both twin and RTL testbenches
- `pipeline/pipeline.yaml` must be updated before adding new pipeline units
- All code must pass `./build.sh --check` (Verilator lint, cargo fmt, cargo check, cargo clippy)
- The syskit-specialist keeps docs in sync with implementation — no formal syskit workflow needed
