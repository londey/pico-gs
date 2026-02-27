---
description: Interactive guide for getting started with syskit
arguments:
  - name: system
    description: Brief description of your system or project (e.g., "LED controller with SPI interface")
    required: false
---

# syskit Guide

You are guiding a user through getting started with syskit in this project.

If `$ARGUMENTS.system` is provided, use it to tailor examples and suggestions to their system.

## Instructions

### Step 1: Detect Scenario

List all files in `doc/requirements/`, `doc/interfaces/`, `doc/design/`, and `doc/verification/`.

Ignore template files (filenames containing `_000_template`).

- If **no non-template documents** exist → follow **Path A: Fresh Project** (Step 2A)
- If **non-template documents** exist → follow **Path B: Existing Project** (Step 2B)

---

## Path A: Fresh Project

### Step 2A: Orient

Explain the project structure syskit has set up:

1. **`doc/requirements/`** — What the system must do. Each file is a requirement (REQ-NNN).
2. **`doc/interfaces/`** — Contracts between components and external systems. Each file is an interface (INT-NNN).
3. **`doc/design/`** — How each piece of the system works. Each file is a design unit (UNIT-NNN).
4. **`doc/verification/`** — How requirements are verified. Each file is a verification procedure (VER-NNN).
5. **`.syskit/`** — Tooling: scripts, manifest, working folders for analysis and tasks.

Explain the naming convention:
- `req_001_motor_control.md` → referenced as `REQ-001`
- `req_001.01_torque_limit.md` → referenced as `REQ-001.01` (child of REQ-001)
- `int_002_spi_bus.md` → referenced as `INT-002`
- `int_002.01_uart_registers.md` → referenced as `INT-002.01` (child of INT-002)
- `unit_003_pwm_driver.md` → referenced as `UNIT-003`
- `unit_003.01_pid_controller.md` → referenced as `UNIT-003.01` (child of UNIT-003)
- `ver_004_motor_test.md` → referenced as `VER-004`
- `ver_004.01_edge_cases.md` → referenced as `VER-004.01` (child of VER-004)

Explain that all document types support two-level hierarchy — child documents use dot-notation (e.g., `REQ-001.03`, `INT-002.01`, `UNIT-003.01`) so the parent relationship is visible from the ID itself.

Explain that these documents cross-reference each other to create a traceability web:
- Requirements reference the interfaces they use, the design units that implement them, and the verifications that prove them
- Design units reference the requirements they satisfy and the interfaces they provide or consume
- Verification documents reference the requirements they verify and the design units they exercise

### Step 3A: Create a Requirement

Ask the user what their first requirement should be about. Use `$ARGUMENTS.system` for context if provided.

Once they respond, create the requirement:

1. Run `.syskit/scripts/new-req.sh <name>` with a snake_case name based on their description
2. Read the created file
3. Walk the user through filling in each section interactively — ask them questions to populate:
   - **Classification:** Help them choose Priority (Essential/Important/Nice-to-have), Stability (Stable/Evolving/Volatile), and Verification method
   - **Requirement statement:** Help them write the requirement in condition/response format: "When [condition], the system SHALL [observable behavior]."
     Before finalizing the statement, validate it against the quality criteria:
     1. **Condition/Response format** — Does it follow "When X, the system SHALL Y"? If not, help identify the trigger condition that makes this testable.
     2. **Singular** — Does it address exactly one thing? If it uses "and" or "or" to combine distinct capabilities, split it into separate requirements.
     3. **Appropriate Level** — Does it describe a capability or behavior (correct) rather than data layout, register fields, or encoding details (too low-level)? If it specifies struct fields, byte offsets, or protocol encoding, move that detail to an interface document and have the requirement reference the interface instead.
     4. **Unambiguous** — Could two engineers interpret this differently? Eliminate vague terms like "fast", "efficient", "appropriate".
     5. **Necessary** — Is this requirement essential, or is it an implementation detail that belongs in a design unit?
     If the statement fails any check, explain the issue to the user and help them revise it before proceeding.
   - **Rationale:** Ask why this requirement exists
4. Leave **Allocated To** and **Interfaces** as TBD — these will be filled in after creating those documents

Write the completed content to the file.

### Step 4A: Create an Interface

Ask the user what interface is relevant to the requirement just created. For example, if the requirement involves communication, the interface might be a protocol or data format.

Once they respond:

1. Run `.syskit/scripts/new-int.sh <name>`
2. Read the created file
3. Walk the user through:
   - **Type:** Internal, External Standard, or External Service
   - **Parties:** Leave Provider/Consumer as TBD until the design unit exists
   - **Referenced By:** Add the requirement just created (e.g., REQ-001)
   - **Specification:** Help them write at least an overview of what this interface does
   - Help the user understand that detailed data layouts, field definitions, register maps, and encoding specifications belong here in the interface document — not in requirements. If the user described low-level details during requirement creation that were redirected here, incorporate them into the interface specification.

Write the completed content to the file.

### Step 5A: Create a Design Unit

Ask the user what component or module will implement the requirement.

Once they respond:

1. Run `.syskit/scripts/new-unit.sh <name>`
2. Read the created file
3. Walk the user through:
   - **Purpose:** What this unit does
   - **Implements Requirements:** Link to the requirement from Step 3A
   - **Interfaces — Provides/Consumes:** Link to the interface from Step 4A
   - **Design Description:** Help them describe how it works at a high level

Write the completed content to the file.

### Step 6A: Wire Up Cross-References

Now go back and complete the cross-references:

1. Edit the requirement file:
   - Set **Allocated To** → the design unit just created (e.g., UNIT-001)
   - Set **Interfaces** → the interface just created (e.g., INT-001)

2. Edit the interface file:
   - Set **Provider/Consumer** in Parties → the design unit (e.g., UNIT-001)

Explain to the user how this traceability web works: every requirement traces forward to what implements it, and every design unit traces back to why it exists.

### Step 7A: Update Manifest and Explain Workflow

Run `.syskit/scripts/manifest.sh` to record the current state of all documents.

Explain:
- The manifest (`.syskit/manifest.md`) stores SHA256 hashes of every spec document
- This enables **freshness checking** — syskit detects when specs have changed between workflow steps, preventing work based on stale analysis

Then explain the change workflow for future changes:

1. **`/syskit-impact`** — Describe a change; syskit analyzes which specs are affected
2. **`/syskit-propose`** — Draft proposed modifications to affected specs
3. **`/syskit-refine`** — (Optional, repeatable) Fix issues in proposed changes based on your review feedback
4. **`/syskit-approve`** — Approve changes when ready (works across sessions — review overnight if needed)
5. **`/syskit-plan`** — Break approved spec changes into implementation tasks
6. **`/syskit-implement`** — Execute tasks one by one with verification

Tell the user: "You're set up. When you want to make a change, start with `/syskit-impact` and describe what you want to change. If you need to investigate a topic first, use `/syskit-technical-report` to document your findings before proposing changes."

---

## Path B: Existing Project

### Step 2B: Overview

Provide a brief inventory of existing documents:

1. Count and list documents by type:
   - **Requirements:** List each file's ID and title (e.g., `REQ-001: Motor Control`)
   - **Interfaces:** List each file's ID and title (e.g., `INT-001: SPI Bus`)
   - **Design Units:** List each file's ID and title (e.g., `UNIT-001: PWM Driver`)
   - **Verification:** List each file's ID and title (e.g., `VER-001: Motor Test`)
2. Note any special documents present: `states_and_modes.md`, `quality_metrics.md`, `design_decisions.md`, `concept_of_execution.md`, `test_strategy.md`

### Step 3B: Explain the Structure

Explain the conventions this project uses:

1. **Naming:** `req_NNN_name.md` → `REQ-NNN`, `int_NNN_name.md` → `INT-NNN`, `unit_NNN_name.md` → `UNIT-NNN`, `ver_NNN_name.md` → `VER-NNN` (children use dot-notation: `req_NNN.NN_name.md` → `REQ-NNN.NN`, `int_NNN.NN_name.md` → `INT-NNN.NN`, `unit_NNN.NN_name.md` → `UNIT-NNN.NN`, `ver_NNN.NN_name.md` → `VER-NNN.NN`)
2. **Cross-references:** Documents link to each other using these IDs to create traceability:
   - Requirements → Interfaces they use, Design Units that implement them, Verifications that prove them
   - Design Units → Requirements they satisfy, Interfaces they provide/consume
   - Verifications → Requirements they verify, Design Units they exercise
3. **Manifest:** `.syskit/manifest.md` stores SHA256 hashes for freshness checking between workflow steps

### Step 4B: Explain the Change Workflow

Walk through how to make changes in this project:

1. **`/syskit-impact <description>`** — Start here. Describe what you want to change. Syskit analyzes which specs are affected and creates an impact report.
2. **`/syskit-propose`** — Drafts specific edits to affected specs. You review using `git diff`.
3. **`/syskit-refine --feedback "<issues>"`** — (Optional) Fix issues in the proposal based on your review. Repeatable.
4. **`/syskit-approve`** — Approve changes when satisfied. Works across sessions — review overnight if needed.
5. **`/syskit-plan`** — Creates an implementation task breakdown from approved spec changes.
6. **`/syskit-implement`** — Executes tasks one by one with verification.

Also mention helper scripts for creating new documents:
- `.syskit/scripts/new-req.sh <name>` — Create a new requirement (use `--parent REQ-NNN` for child)
- `.syskit/scripts/new-int.sh <name>` — Create a new interface (use `--parent INT-NNN` for child)
- `.syskit/scripts/new-unit.sh <name>` — Create a new design unit (use `--parent UNIT-NNN` for child)
- `.syskit/scripts/new-ver.sh <name>` — Create a new verification (use `--parent VER-NNN` for child)

### Step 5B: Offer Next Steps

Ask the user what they'd like to do:

- Create a new requirement, interface, or design unit to get hands-on practice
- Run `/syskit-impact` on a change they have in mind
- Run `/syskit-technical-report` to investigate a topic and document findings
- Ask questions about the existing specifications
