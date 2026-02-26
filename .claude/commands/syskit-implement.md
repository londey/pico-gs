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

If this conversation already contains output from a previous syskit command (look for any `*_SUMMARY` markers or previous `/syskit-*` command invocations), STOP and tell the user:

"Each implementation task needs its own fresh conversation to avoid context pollution between tasks. All progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Steps 1–3: Find Task, Check Freshness, Check Dependencies

Run the combined task-discovery script (single command covers task lookup, freshness, and dependency checks):

```bash
.syskit/scripts/find-task.sh $ARGUMENTS.task
```

(Omit the argument if `$ARGUMENTS.task` was not provided.)

Parse the structured output between `FIND_TASK_START` / `FIND_TASK_END`:

- **`all_complete: true`** → Report completion and stop.
- **`freshness: stale`** → Warn the user with `freshness_detail`. Recommend re-running `/syskit-plan` if changes are significant.
- **`deps_ok: false`** → Show `deps_detail`. Prompt the user to complete dependencies first or offer to implement the dependency instead.
- **`task_file`** → Path to the task file to implement (used in Step 4).
- **`task_folder`** → Path to the task folder (used in Step 4).
- **`pending_remaining`** → Number of pending tasks (used in Step 7).

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

3. If no, run `.syskit/scripts/manifest.sh` to update the manifest, then report: "All tasks complete. Manifest updated."

Also remind to update any design or verification documents if implementation details changed the behavior of verified requirements or design units.
