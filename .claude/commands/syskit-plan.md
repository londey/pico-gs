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

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for IMPACT_SUMMARY, PROPOSE_SUMMARY, CHUNK_SUMMARY, PLAN_SUMMARY, or IMPLEMENT_SUMMARY markers, or previous `/syskit-*` command invocations), STOP and tell the user:

"This conversation already has syskit command history in context. Start a fresh conversation to run `/syskit-plan` — all progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Load Approved Changes

If `$ARGUMENTS.analysis` is provided:

- Find the analysis folder: `.syskit/analysis/$ARGUMENTS.analysis/`

Otherwise:

- Find the most recent folder in `.syskit/analysis/`

Check for approval status:

1. Check that `proposed_changes.md` exists in the folder.
   - If it does not exist, tell the user: "No proposed changes found. Run `/syskit-propose` first to generate specification changes."

2. Read ONLY its first ~10 lines. Check the `Status:` line.
   - If "Approved", proceed.
   - If "Pending Approval", tell the user: "Proposed changes have not been approved yet. Run `/syskit-approve` to review and approve them, or approve inline during `/syskit-propose`."
   - If any other status, tell the user the current status and suggest re-running `/syskit-propose`.

Note the analysis folder path and the change name — you will pass these to the subagent.

### Step 2: Delegate Scope Extraction

Use the Task tool to launch a subagent that reads the affected documents and design units to extract implementation scope. This keeps the full document contents out of your context window.

The subagent reads all needed files from disk — do NOT embed proposed_changes.md content in the prompt.

Launch a `general-purpose` Task agent with **model: sonnet** and this prompt (substitute ANALYSIS_FOLDER and TASK_FOLDER):

> Read your full instructions from `.syskit/prompts/plan-extract.md`.
>
> Use these values for placeholders in the prompt file:
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
> - `{{TASK_FOLDER}}`: TASK_FOLDER (use `.syskit/tasks/{{DATE}}_<change_name>/`)
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

The subagent will return a summary in `PLAN_SUMMARY_START`/`PLAN_SUMMARY_END` format.

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
