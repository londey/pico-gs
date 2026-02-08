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

List all files in `doc/requirements/`, `doc/interfaces/`, and `doc/design/`.

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
4. **`.syskit/`** — Tooling: scripts, manifest, working folders for analysis and tasks.

Explain the naming convention:
- `req_001_motor_control.md` → referenced as `REQ-001`
- `int_002_spi_bus.md` → referenced as `INT-002`
- `unit_003_pwm_driver.md` → referenced as `UNIT-003`

Explain that these documents cross-reference each other to create a traceability web:
- Requirements reference the interfaces they use and the design units that implement them
- Design units reference the requirements they satisfy and the interfaces they provide or consume

### Step 3A: Create a Requirement

Ask the user what their first requirement should be about. Use `$ARGUMENTS.system` for context if provided.

Once they respond, create the requirement:

1. Run `.syskit/scripts/new-req.sh <name>` with a snake_case name based on their description
2. Read the created file
3. Walk the user through filling in each section interactively — ask them questions to populate:
   - **Classification:** Help them choose Priority (Essential/Important/Nice-to-have), Stability (Stable/Evolving/Volatile), and Verification method
   - **Requirement statement:** Help them write a clear SHALL/SHOULD/MAY statement
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

Then explain the four-command change workflow for future changes:

1. **`/syskit-impact`** — Describe a change; syskit analyzes which specs are affected
2. **`/syskit-propose`** — Review and approve proposed modifications to affected specs
3. **`/syskit-plan`** — Break approved spec changes into implementation tasks
4. **`/syskit-implement`** — Execute tasks one by one with verification

Tell the user: "You're set up. When you want to make a change, start with `/syskit-impact` and describe what you want to change."

---

## Path B: Existing Project

### Step 2B: Overview

Provide a brief inventory of existing documents:

1. Count and list documents by type:
   - **Requirements:** List each file's ID and title (e.g., `REQ-001: Motor Control`)
   - **Interfaces:** List each file's ID and title (e.g., `INT-001: SPI Bus`)
   - **Design Units:** List each file's ID and title (e.g., `UNIT-001: PWM Driver`)
2. Note any special documents present: `states_and_modes.md`, `quality_metrics.md`, `design_decisions.md`, `concept_of_execution.md`

### Step 3B: Explain the Structure

Explain the conventions this project uses:

1. **Naming:** `req_NNN_name.md` → `REQ-NNN`, `int_NNN_name.md` → `INT-NNN`, `unit_NNN_name.md` → `UNIT-NNN`
2. **Cross-references:** Documents link to each other using these IDs to create traceability:
   - Requirements → Interfaces they use, Design Units that implement them
   - Design Units → Requirements they satisfy, Interfaces they provide/consume
3. **Manifest:** `.syskit/manifest.md` stores SHA256 hashes for freshness checking between workflow steps

### Step 4B: Explain the Change Workflow

Walk through how to make changes in this project:

1. **`/syskit-impact <description>`** — Start here. Describe what you want to change. Syskit analyzes which specs are affected and creates an impact report.
2. **`/syskit-propose`** — Proposes specific edits to affected specs. You review and approve before any specs are modified.
3. **`/syskit-plan`** — Creates an implementation task breakdown from approved spec changes.
4. **`/syskit-implement`** — Executes tasks one by one with verification.

Also mention helper scripts for creating new documents:
- `.syskit/scripts/new-req.sh <name>` — Create a new requirement
- `.syskit/scripts/new-int.sh <name>` — Create a new interface
- `.syskit/scripts/new-unit.sh <name>` — Create a new design unit

### Step 5B: Offer Next Steps

Ask the user what they'd like to do:

- Create a new requirement, interface, or design unit to get hands-on practice
- Run `/syskit-impact` on a change they have in mind
- Ask questions about the existing specifications
