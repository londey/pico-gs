---
description: Execute implementation tasks from the current plan
arguments:
  - name: task
    description: Task number to implement (optional, continues from current or starts at 1)
    required: false
---

# Implement Task

You are orchestrating implementation of tasks from the current implementation plan. The actual implementation work is delegated to a subagent to keep your context lean.

## Instructions

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for IMPACT_SUMMARY, PROPOSE_SUMMARY, CHUNK_SUMMARY, PLAN_SUMMARY, or IMPLEMENT_SUMMARY markers, or previous `/syskit-*` command invocations), STOP and tell the user:

"This conversation already has syskit command history in context. Start a fresh conversation to run `/syskit-implement` — all progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Find Task Folder and Identify Current Task

Find the most recent folder in `.syskit/tasks/`.

Read ONLY the `## Task Sequence` table from `plan.md` (use a targeted read of the first ~30 lines — do NOT load the full file).

If `$ARGUMENTS.task` is provided, identify the matching task file: `task_$ARGUMENTS.task_*.md`

Otherwise, scan task file headers (first 5 lines of each) to find the first task with `Status: Pending`. If all are complete, report completion and stop.

### Step 2: Check Freshness

Run the freshness check script:

```bash
.syskit/scripts/manifest-check.sh .syskit/tasks/<folder>/snapshot.md
```

- If referenced specifications changed (exit code 1), warn user
- Recommend re-running `/syskit-plan` if changes are significant

### Step 3: Check Dependencies

Read only the `Dependencies:` line from the current task file (first 5 lines).

If dependencies exist, read only the `Status:` line from each dependency task file. If any dependency is not complete, prompt the user to complete it first or offer to implement the dependency instead.

### Step 4: Delegate Implementation

Launch a `general-purpose` Task agent with this prompt (substitute TASK_FILE with the full path to the task file, TASK_FOLDER with the task folder path, and TIMESTAMP with the current date/time):

> Read your full instructions from `.syskit/prompts/implement-task.md`.
>
> Your assignment:
> - Task file: TASK_FILE
> - Task folder: TASK_FOLDER
> - Timestamp: TIMESTAMP
>
> In the prompt file, replace `{{TASK_FILE}}` with your task file path, `{{TASK_FOLDER}}` with the task folder path, and `{{TIMESTAMP}}` with the timestamp.
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

### Step 5: Validate Results

After the subagent returns:

1. Parse the `IMPLEMENT_SUMMARY_START`/`IMPLEMENT_SUMMARY_END` block
2. Check that all verification criteria passed
3. If the subagent failed or returned incomplete results, tell the user and offer to re-run

If any verification criteria failed, tell the user which ones and ask how to proceed.

### Step 6: Post-Implementation Scripts

Run these scripts to verify consistency:

```bash
.syskit/scripts/trace-sync.sh
```

If trace-sync reports issues, run `.syskit/scripts/trace-sync.sh --fix` and report what was fixed.

For each design unit referenced by the task, update Spec-ref hashes:

```bash
.syskit/scripts/impl-stamp.sh UNIT-NNN
```

Then verify implementation freshness:

```bash
.syskit/scripts/impl-check.sh
```

Report any issues from these scripts to the user.

### Step 7: Next Steps

After completing the task:

1. Check if there are more pending tasks (scan task file headers for `Status: Pending`)
2. If yes, tell the user:

"Task <n> complete.

Next: run `/syskit-implement` in a new conversation to continue with the next pending task."

3. If no, report: "All tasks complete. Run `.syskit/scripts/manifest.sh` to update the manifest."

Also remind to update any design documents if implementation details changed.
