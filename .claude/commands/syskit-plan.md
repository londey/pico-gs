---
description: Create implementation task breakdown from approved specification changes
arguments:
  - name: analysis
    description: Name of the analysis folder (optional, uses most recent if not specified)
    required: false
---

# Plan Implementation Tasks

You are creating an implementation task breakdown based on approved specification changes.

## Instructions

### Step 1: Load Approved Changes

If `$ARGUMENTS.analysis` is provided:
- Load `.syskit/analysis/$ARGUMENTS.analysis/proposed_changes.md`

Otherwise:
- Find the most recent folder in `.syskit/analysis/`
- Load `proposed_changes.md` from that folder

Verify the status shows changes were approved. If not, prompt user to run `/syskit-propose` first.

Note the analysis folder path — you will pass it to subagents.

### Step 2: Delegate Scope Extraction

Use the Task tool to launch a subagent that reads the affected documents and design units to extract implementation scope. This keeps the full document contents out of your context window.

The subagent reads all needed files from disk — do NOT embed proposed_changes.md content in the prompt.

Launch a `general-purpose` Task agent with this prompt (substitute ANALYSIS_FOLDER with the actual path):

> You are extracting implementation scope from approved specification changes.
>
> ## Instructions
>
> 1. Read the change summary from: `ANALYSIS_FOLDER/proposed_changes.md`
>
> 2. Run `git diff doc/` to see the exact specification changes that were applied.
>
> 3. Read all design unit documents (`doc/design/unit_*.md`) to understand implementation structure. Focus especially on:
>    - The `## Implementation` section (lists source files)
>    - The `## Implements Requirements` section (links to REQ-NNN)
>    - The `## Provides` and `## Consumes` sections (links to INT-NNN)
>
> 4. For each specification change, identify:
>    - Which source files need modification (from design unit Implementation sections)
>    - Which test files need modification or creation
>    - Dependencies between changes (what must be done first)
>    - How to verify the change was implemented correctly
>
> 5. Create the task folder: `.syskit/tasks/{{DATE}}_<change_name>/`
>
> 6. Write `plan.md` to the task folder:
>
>    ```markdown
>    # Implementation Plan: <change name>
>
>    Based on: ../../.syskit/analysis/<folder>/proposed_changes.md
>    Created: <timestamp>
>    Status: In Progress
>
>    ## Overview
>
>    <Brief description of what is being implemented>
>
>    ## Specification Changes Applied
>
>    | Document | Change Type | Summary |
>    |----------|-------------|---------|
>    | <doc> | Modified | <summary> |
>
>    ## Implementation Strategy
>
>    <High-level approach to implementing these changes>
>
>    ## Task Sequence
>
>    | # | Task | Dependencies | Est. Effort |
>    |---|------|--------------|-------------|
>    | 1 | <task name> | None | <small/medium/large> |
>    | 2 | <task name> | Task 1 | <effort> |
>
>    ## Verification Approach
>
>    <How we will verify the implementation meets the specifications>
>
>    ## Risks and Considerations
>
>    - <risk or consideration>
>    ```
>
> 7. Write individual task files `task_NNN_<name>.md` to the task folder:
>
>    ```markdown
>    # Task NNN: <task name>
>
>    Status: Pending
>    Dependencies: <list or "None">
>    Specification References: <REQ-NNN, INT-NNN, UNIT-NNN>
>
>    ## Objective
>
>    <What this task accomplishes>
>
>    ## Files to Modify
>
>    - `<filepath>`: <what changes>
>
>    ## Files to Create
>
>    - `<filepath>`: <purpose>
>
>    ## Implementation Steps
>
>    1. <step>
>    2. <step>
>    3. <step>
>
>    ## Verification
>
>    - [ ] <verification criterion>
>    - [ ] <verification criterion>
>
>    ## Notes
>
>    <Any additional context or considerations>
>    ```
>
> 8. After writing all files, return ONLY this compact summary (nothing else):
>
>    PLAN_SUMMARY_START
>    Task folder: <path to task folder>
>    Tasks created: <n>
>    Task sequence:
>    1. <task name> (deps: None)
>    2. <task name> (deps: Task 1)
>    ...
>    Source files to modify: <n>
>    Source files to create: <n>
>    Risks: <n>
>    PLAN_SUMMARY_END

### Step 3: Validate Plan

After the subagent returns:

1. Parse the summary to verify the task folder was created and tasks were written
2. Verify the task count is reasonable for the scope of changes
3. If the subagent failed or returned incomplete results, tell the user and offer to re-run

Do NOT read the full plan.md or task files into context. Use the summary to validate.

### Step 4: Generate Snapshot

Run: `.syskit/scripts/manifest-snapshot.sh <task-folder-path>`

### Step 5: Present Plan

Present the task sequence from the subagent's summary and tell the user:

"Implementation plan created with <n> tasks in `<task-folder>`.

**Task sequence:**
<paste the task sequence from the summary>

Next step: run `/syskit-implement` to begin working through the tasks.

Tip: Start a new conversation before running the next command to free up context."
