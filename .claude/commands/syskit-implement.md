---
description: Execute implementation tasks from the current plan
arguments:
  - name: task
    description: Task number to implement (optional, continues from current or starts at 1)
    required: false
---

# Implement Task

You are implementing tasks from the current implementation plan.

## Instructions

### Step 1: Load Task Plan

Find the most recent folder in `.syskit/tasks/` and load:
- `plan.md` — Overall plan
- `snapshot.md` — Document state at planning time

If `$ARGUMENTS.task` is provided:
- Load `task_$ARGUMENTS.task_*.md` (matching the number prefix)

Otherwise:
- Find the first task with Status: Pending
- Or if all complete, report completion

### Step 2: Check Freshness

Run the freshness check script:

```bash
.syskit/scripts/manifest-check.sh .syskit/tasks/<folder>/snapshot.md
```

- If referenced specifications changed (exit code 1), warn user
- Changes to specs may invalidate the task plan
- Recommend re-running `/syskit-plan` if changes are significant

### Step 3: Check Dependencies

Verify all dependency tasks are complete:

- If dependencies are pending, prompt user to complete them first
- Or offer to implement the dependency task instead

### Step 4: Load Context

Load all files listed in the task's "Files to Modify" and "Specification References" sections.

Understand:
- What the specification requires
- What the current implementation looks like
- What changes are needed

### Step 5: Implement

Follow the task's implementation steps:

1. Make the changes described
2. Explain each change as you make it
3. Ensure changes align with referenced specifications

### Step 6: Verify

Work through the task's verification checklist:

1. For each verification criterion, confirm it is met
2. If a criterion cannot be verified, note why
3. Run any specified tests

### Step 7: Update Task Status

Update the task file:

```markdown
Status: Complete
Completed: <timestamp>
```

Add a completion summary:

```markdown
## Completion Notes

<What was actually done, any deviations from plan>

## Verification Results

- [x] <criterion> — <result>
- [x] <criterion> — <result>
```

### Step 8: Next Steps

After completing the task:

1. Check if there are more pending tasks
2. If yes, ask: "Task <n> complete. Proceed to Task <next>?"
3. If no, report: "All tasks complete. Run `.syskit/scripts/manifest.sh` to update the manifest."

Also remind to update any design documents if implementation details changed.
