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

3. **verilog-specialist** — SystemVerilog RTL implementation. Works on `rtl/components/*/src/` modules. Reads the digital twin first, then implements RTL to match it bit-exactly. Follows `.claude/skills/claude-skill-verilog/SKILL.md` and `.claude/skills/ecp5-sv-yosys-verilator/SKILL.md`.

4. **rust-twin-specialist** — Digital twin implementation. Works on `twin/components/*/` crates and `integration/gs-twin/`. Implements the bit-accurate algorithm in Rust first. Follows `.claude/skills/claude-skill-rust/SKILL.md`. Generates expected outputs for verification.

5. **verification-specialist** — Verilator testbenches and synthesis validation. Works on `rtl/components/*/tests/` and `rtl/tb/`. Compares RTL output against twin output using shared `.hex` stimulus. Follows `.claude/skills/claude-skill-cpp/SKILL.md`.

## Spawning responsibility

**The caller spawns all five agents.** The coordinator does not spawn anyone.

This is deliberate: the gpu-coordinator subagent's toolset does not reliably expose the `Agent` tool, so coordinator-driven spawning silently fails. Caller-driven spawning is the only pattern that works.

**Caller (top-level Claude that invoked this skill):**

1. Call `TeamCreate` to create the team.
2. Spawn all five agents via the `Agent` tool, each with `team_name` set to the team name:
   - `name: "coordinator"`, `subagent_type: "gpu-coordinator"`
   - `name: "twin"`, `subagent_type: "rust-twin-specialist"`
   - `name: "rtl"`, `subagent_type: "verilog-specialist"`
   - `name: "verif"`, `subagent_type: "verification-specialist"`
   - `name: "syskit"`, `subagent_type: "syskit-specialist"`
   Each specialist's initial prompt must end with: *"On first wakeup, send a one-line plain-text ack to `coordinator` (e.g. `rtl ready`) before doing anything else. Then wait for your assignment."*
3. After spawning, use the `Read` tool on `.claude/teams/<team-name>/config.json` and confirm all five names appear in `members`. Any missing name means the `Agent` call failed — retry it before proceeding.
4. Send the coordinator a briefing message describing the task, the approved in-scope work, and any flagged-only items. The coordinator will dispatch specialists once acks arrive.

**Coordinator (once spawned):**

1. Read relevant specs and decompose the task. Do not attempt to spawn agents — the caller has already done that.
2. Wait for each specialist to send a plain-text ack before dispatching assignments. If an expected ack is missing after your next turn, escalate to the caller (they may need to respawn).
3. Dispatch assignment messages via `SendMessage`. Monitor progress, unblock specialists, run final `./build.sh --check`, and report back to the caller.

## Spawn mechanics — read this carefully

These rules exist because silent failures here are the #1 way this skill wastes a session.

- **Only the caller calls `Agent` to spawn.** The coordinator must not attempt it.
- **`SendMessage` does NOT spawn agents.** It only writes to an inbox file. Sending a message to a name that was never spawned via `Agent` is a silent no-op — the message sits in an orphan inbox and nothing reads it. Do not rely on "message sent" as evidence that the recipient exists.
- **Verify membership with `Read`, not `Bash`.** Use the `Read` tool on `.claude/teams/<team-name>/config.json`. Do not shell out with `cat`/`jq`/`python3` — those trigger permission prompts that can stall the session.
- **Spawn before message.** Never send an assignment message to a specialist that is not present in `config.json`.

## Idle discipline for the coordinator

- Do **not** go idle immediately after dispatching inbox messages. "Messages sent" is not progress.
- **Never end a turn on a failed or denied tool call.** If a tool call is denied, errors, or stalls (permission prompt, missing tool, unexpected result), your very next action in the same turn must be a concrete progress step — usually a `Read`, a `SendMessage`, or an escalation to the caller describing what's blocked. Do not go idle right after a failure.
- Only go idle when one of the following is true:
  - All spawned specialists have acknowledged AND work is actively in flight (you are waiting on a named specialist's reply).
  - You are blocked on the caller for a decision and have already asked the caller a specific question.
  - Work is complete and you have reported the final result to the caller.
- If you catch yourself about to go idle without progress, instead: re-check `config.json` via `Read`, re-check inboxes, and take the next concrete action (re-send a prompt, ask the caller to respawn a missing specialist, or escalate).

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
- The caller owns spawning; the coordinator owns dispatch, monitoring, and the final `./build.sh --check`
- The coordinator must obey the idle-discipline rules above — never end a turn on a denied/failed tool call, and never go idle without progress
