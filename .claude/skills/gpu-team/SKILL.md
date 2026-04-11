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

The team has five roles:

1. **gpu-coordinator** — Team lead. Decomposes the task, spawns the four specialists, assigns work, resolves cross-cutting issues, and runs final `./build.sh --check` before declaring complete.

2. **syskit-specialist** — Specification documentation. Keeps requirement, interface, design, and verification docs under `doc/` in sync with what the team implements. Updates Spec-ref hashes and maintains traceability.

3. **verilog-specialist** — SystemVerilog RTL implementation. Works on `components/*/rtl/src/` modules. Reads the digital twin first, then implements RTL to match it bit-exactly. Follows `.claude/skills/claude-skill-verilog/SKILL.md` and `.claude/skills/ecp5-sv-yosys-verilator/SKILL.md`.

4. **rust-twin-specialist** — Digital twin implementation. Works on `components/*/twin/` crates and `integration/gs-twin/`. Implements the bit-accurate algorithm in Rust first. Follows `.claude/skills/claude-skill-rust/SKILL.md`. Generates expected outputs for verification.

5. **verification-specialist** — Verilator testbenches and synthesis validation. Works on `components/*/rtl/tests/` and `integration/harness/`. Compares RTL output against twin output using shared `.hex` stimulus. Follows `.claude/skills/claude-skill-cpp/SKILL.md`.

## Spawning responsibility

Spawning is split between the caller and the coordinator — do not conflate the two.

**Caller (top-level Claude that invoked this skill):**

1. Call `TeamCreate` to create the team.
2. Spawn **only** the `gpu-coordinator` via the `Agent` tool, passing `team_name` and `name: "coordinator"`. Hand it the task and tell it to spawn the four specialists itself.
3. Do not spawn the specialists yourself — the coordinator owns that.

**Coordinator (once spawned):**

1. Spawn each of the four specialists (`syskit`, `rtl`, `twin`, `verif`) via the `Agent` tool, with `team_name`, a `name`, and the appropriate `subagent_type`.
2. Wait for each specialist to send a plain-text acknowledgment before dispatching any assignment messages (see "Spawn handshake" below).
3. Only after all acks are received: dispatch assignment messages via `SendMessage`.

## Spawn mechanics — read this carefully

These rules exist because silent failures here are the #1 way this skill wastes a session.

- **To spawn a teammate you MUST call the `Agent` tool** with `team_name`, `name`, and `subagent_type`. This is what actually starts the agent process.
- **`SendMessage` does NOT spawn agents.** It only writes to an inbox file. Sending a message to a name that was never spawned via `Agent` is a silent no-op — the message sits in an orphan inbox and nothing reads it. Do not rely on "message sent" as evidence that the recipient exists.
- **After spawning, verify the team membership.** Read `.claude/teams/<team-name>/config.json` and confirm every expected name appears in the `members` array. Any missing name means the `Agent` call failed or was never made — fix that before proceeding.
- **Spawn before message.** Never send an assignment message to a specialist you have not already spawned and confirmed present in `config.json`.

## Spawn handshake

To guarantee specialists are actually running before work begins:

1. Coordinator spawns each specialist with an initial prompt that ends with: *"On first wakeup, send a one-line plain-text ack to `coordinator` (e.g. `rtl ready`) before doing anything else."*
2. Each specialist, on first wakeup, reads its inbox and sends that ack immediately, then proceeds.
3. Coordinator does not go idle until every expected specialist has acked. Missing acks after one cycle = respawn or escalate to the caller.

## Idle discipline for the coordinator

- Do **not** go idle immediately after dispatching inbox messages. "Messages sent" is not progress.
- Only go idle when one of the following is true:
  - All spawned specialists have acknowledged AND work is actively in flight (you are waiting on a named specialist's reply).
  - You are blocked on the caller for a decision and have already asked the caller a specific question.
  - Work is complete and you have reported the final result to the caller.
- If you catch yourself about to go idle without progress, instead: re-check `config.json`, re-check inboxes, and take the next concrete action (spawn a missing specialist, re-send a prompt, or escalate to the caller).

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
- The coordinator must obey the spawn mechanics and idle discipline rules above — sending a `SendMessage` to an unspawned name is a failure, not an assignment
