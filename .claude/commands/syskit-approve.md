---
description: Approve or reject proposed specification changes (works across sessions)
arguments:
  - name: analysis
    description: Name of the analysis folder (optional, uses most recent if not specified)
    required: false
---

# Approve Specification Changes

You are reviewing and approving (or rejecting) proposed specification changes from a previous `/syskit-propose` or `/syskit-refine` session.

## Instructions

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for IMPACT_SUMMARY, PROPOSE_SUMMARY, CHUNK_SUMMARY, PLAN_SUMMARY, IMPLEMENT_SUMMARY, or REFINE_SUMMARY markers, or previous `/syskit-*` command invocations), STOP and tell the user:

"This conversation already has syskit command history in context. Start a fresh conversation to run `/syskit-approve` — all progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Find Pending Changes

If `$ARGUMENTS.analysis` is provided:

- Find the analysis folder: `.syskit/analysis/$ARGUMENTS.analysis/`

Otherwise:

- Find the most recent folder in `.syskit/analysis/`

Check that `proposed_changes.md` exists in the folder. If not, tell the user:

"No proposed changes found. Run `/syskit-propose` first to generate specification changes."

Read the first ~10 lines of `proposed_changes.md` to get the change name and status.

If `Status:` is already "Approved", tell the user:

"These changes have already been approved. Run `/syskit-plan` to create an implementation task breakdown."

If `Status:` is not "Pending Approval", tell the user the current status and suggest running `/syskit-propose`.

### Step 2: Check for Uncommitted Changes

Run `git status -- doc/` to verify there are uncommitted changes in the doc directory.

If there are **no** uncommitted changes in `doc/`:

Tell the user: "No uncommitted changes found in `doc/`. The proposed changes may have already been committed or reverted. Check `git log -- doc/` for recent commits, or re-run `/syskit-propose` to regenerate changes."

### Step 3: Show Change Summary

Read the change summary table from `proposed_changes.md` (the `## Change Summary` section, typically a markdown table).

Run `git diff --stat -- doc/` to get a compact summary of what files changed.

Present to the user:

"**Pending approval:** <change name>
**Analysis folder:** `.syskit/analysis/<folder>/`

**Change summary:**
<paste the change summary table from proposed_changes.md>

**Files changed:**
<paste git diff --stat output>

Review the full diff with `git diff doc/` or your editor's source control panel.

Reply with:
- **'approve'** to accept all changes and proceed to planning
- **'approve \<filename\>'** to keep changes to specific file(s) and revert others
- **'reject'** to revert all changes (`git checkout -- doc/`)
- **'refine'** to describe issues and run `/syskit-refine` instead"

### Step 4: Handle Response

- **approve:** Update `Status: Pending Approval` to `Status: Approved` in `.syskit/analysis/<folder>/proposed_changes.md`. Proceed to Step 5.
- **approve \<filename\>:** Revert all other changed doc files with `git checkout -- doc/<other files>`, keeping only the specified file(s). Update `Status: Pending Approval` to `Status: Approved` in `proposed_changes.md`. Proceed to Step 5.
- **reject:** Run `git checkout -- doc/` to revert all changes. Tell the user the proposal has been discarded.
- **refine:** Tell the user to start a new conversation and run `/syskit-refine --feedback "<their feedback>"` to iterate on the changes.

### Step 5: Next Steps

Tell the user:

"Changes approved. Status updated in `.syskit/analysis/<folder>/proposed_changes.md`.

Next step: run `/syskit-plan` to create an implementation task breakdown.

Tip: Start a new conversation before running the next command to free up context."
