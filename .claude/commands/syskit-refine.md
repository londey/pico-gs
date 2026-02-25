---
description: Refine proposed specification changes based on review feedback
arguments:
  - name: feedback
    description: "Description of what needs to change in the proposed specifications (e.g., 'INT-002 should use CAN instead of SPI', 'REQ-003 also needs to cover error recovery')"
    required: true
  - name: analysis
    description: Name of the analysis folder (optional, uses most recent if not specified)
    required: false
---

# Refine Proposed Changes

You are refining previously proposed specification changes based on the user's review feedback. This command iterates on changes from `/syskit-propose` — fixing issues, adjusting decisions, or addressing gaps the user identified during review.

## Instructions

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for any `*_SUMMARY` markers or previous `/syskit-*` command invocations), STOP and tell the user:

"Refine needs a fresh conversation to cleanly re-read your current doc state. All progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Check for Pending Proposed Changes

Run `git status -- doc/` to check for uncommitted changes in the doc directory.

If there are **no** uncommitted changes in `doc/`, **stop and tell the user:**

"No uncommitted changes found in `doc/`. Run `/syskit-propose` first to generate specification changes, then use `/syskit-refine` to iterate on them."

### Step 2: Load the Analysis Context

If `$ARGUMENTS.analysis` is provided:

- Find the analysis folder: `.syskit/analysis/$ARGUMENTS.analysis/`

Otherwise:

- Find the most recent folder in `.syskit/analysis/`

Check that `proposed_changes.md` exists. If not, warn the user that the uncommitted doc changes may not be from a syskit proposal.

Read the first ~10 lines of `proposed_changes.md` to get the change name and status. If `Status:` is "Approved", warn the user:

"These changes have already been approved. Running refine will modify approved specifications. Continue? (yes/no)"

Read ONLY the `## Change Summary` table from `proposed_changes.md` to get the list of affected filenames and change descriptions.

Also read ONLY the `## Summary` section from `impact.md` (the last ~15 lines) to get the impact context.

Note the analysis folder path — you will pass it to the subagent.

### Step 3: Determine Affected Files

From the user's feedback (`$ARGUMENTS.feedback`), identify which documents are likely affected:

1. Look for explicit document references (REQ-NNN, INT-NNN, UNIT-NNN, or filenames)
2. Match against the change summary table to identify relevant files
3. If the feedback is broad or doesn't reference specific documents, include all documents from the change summary

Run `git diff --name-only -- doc/` to get the list of files with uncommitted changes. Cross-reference with the feedback to build the final list of files the subagent should examine and potentially modify.

### Step 4: Delegate Refinement

Count the affected documents.

**8 or fewer documents:** Launch a single subagent.

Launch a `general-purpose` Task agent with **model: sonnet** and this prompt (substitute ANALYSIS_FOLDER, FEEDBACK, and AFFECTED_FILES with actual values):

> Read your full instructions from `.syskit/prompts/refine-single.md`.
>
> Use these values for placeholders in the prompt file:
> - `{{FEEDBACK}}`: FEEDBACK
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
> - `{{AFFECTED_FILES}}`: AFFECTED_FILES (the list of specific filenames to examine and potentially modify)
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

The subagent will return a summary in `REFINE_SUMMARY_START`/`REFINE_SUMMARY_END` format.

**More than 8 documents:** Use the same chunked approach — launch multiple subagents each handling a subset of the affected files, passing the full feedback to each. Launch all chunk agents in parallel. After all complete, assemble results.

### Step 5: Validate Refinement

After the subagent(s) return:

1. Parse the summary to verify which documents were edited
2. Note any quality warnings reported
3. If the subagent failed or returned incomplete results, tell the user and offer to re-run

### Step 6: Present Changes for Review

Run `git diff --stat -- doc/` to get the updated change summary.

Tell the user:

"Refinement applied based on your feedback. Review the updated changes using `git diff doc/` or the VSCode source control panel.

**Feedback addressed:**
$ARGUMENTS.feedback

**Documents modified in this refinement:** \<n\>
**Summary:**
\<paste the change summary from the subagent's returned summary\>

**Quality warnings:** \<list any, or 'None'\>

Reply with:
- **'approve'** to accept all changes (updates status and proceeds to planning)
- **'approve \<filename\>'** to keep changes to specific file(s) and revert others
- **'reject'** to revert ALL changes including the original proposal (`git checkout -- doc/`)
- **Further feedback** to describe additional issues (will require another `/syskit-refine` run in a new session)

Or review at your leisure and run `/syskit-approve` in a new session when ready."

### Step 7: Handle Response

- **approve:** Update `Status: Pending Approval` to `Status: Approved` in `.syskit/analysis/<folder>/proposed_changes.md`. Proceed to Step 8.
- **approve \<filename\>:** Revert non-specified files with `git checkout -- doc/<other files>`, keep the specified file(s). Update Status to "Approved". Proceed to Step 8.
- **reject:** Run `git checkout -- doc/` to revert all changes (including the original proposal). Tell the user the changes have been discarded.
- **Further feedback:** Tell the user to start a new conversation and run `/syskit-refine --feedback "<their new feedback>"`.

### Step 8: Next Steps

Tell the user:

"Changes approved. Status updated in `.syskit/analysis/<folder>/proposed_changes.md`.

Next step: run `/syskit-plan` to create an implementation task breakdown. You can run it right here in this conversation or start a new one."
