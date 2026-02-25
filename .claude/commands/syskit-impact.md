---
description: Analyze impact of a proposed change across all specifications
arguments:
  - name: change
    description: Description of the proposed change (not needed for --incremental)
    required: false
  - name: incremental
    description: "Re-run impact analysis acknowledging already-approved refinements (flag, no value needed)"
    required: false
---

# Impact Analysis

You are analyzing the impact of a proposed change on this project's specifications.

## Proposed Change

$ARGUMENTS.change

## Instructions

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for any `*_SUMMARY` markers or previous `/syskit-*` command invocations), STOP and tell the user:

"Impact analysis should start in a fresh conversation. All progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Read Manifest

Read `.syskit/manifest.md` to get the current list of all specification documents and their hashes.

Count the total number of specification documents listed (excluding any with `_000_template` in the name). You will use this count to validate the subagent's output.

### Step 1.5: Check for Incremental Mode

If `$ARGUMENTS.incremental` is provided (or the user's command included `--incremental`):

1. Find the most recent analysis folder in `.syskit/analysis/`.

2. Read the first few lines of `impact.md` in that folder to get the original proposed change description.

3. Set the PROPOSED_CHANGE to the original change description from impact.md, appended with:
   "NOTE: Specifications may have been modified since the original analysis (via `/syskit-propose` and `/syskit-refine`). The impact analysis should reflect the CURRENT state of all documents."

4. Rename the existing `impact.md` to `impact_prev.md` (for reference).

5. Note the analysis folder path — you will reuse it. Skip Step 2.

If `$ARGUMENTS.incremental` is NOT provided and `$ARGUMENTS.change` is empty, STOP and tell the user: "Please provide a change description: `/syskit-impact \"your change description\"`"

### Step 2: Create Analysis Folder

**Skip this step if in incremental mode (Step 1.5 was executed).**

Create the analysis folder: `.syskit/analysis/{{DATE}}_<change_name>/`

Also create a draft staging directory: `.syskit/analysis/_draft/`

### Step 3: Delegate Document Analysis

Use the Task tool to launch a subagent that reads and analyzes all specification documents. This keeps the full document contents out of your context window.

Launch a `general-purpose` Task agent with **model: sonnet** and this prompt (substitute the actual proposed change for PROPOSED_CHANGE, and the analysis folder path for ANALYSIS_FOLDER):

> Read your full instructions from `.syskit/prompts/impact-analysis.md`.
>
> Use these values for placeholders in the prompt file:
> - `{{PROPOSED_CHANGE}}`: PROPOSED_CHANGE
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

The subagent will return a summary in `IMPACT_SUMMARY_START`/`IMPACT_SUMMARY_END` format.

### Step 4: Validate Analysis

After the subagent returns:

1. Parse the summary counts from the `IMPACT_SUMMARY_START`/`IMPACT_SUMMARY_END` block
2. Compare the "Total" count against the count you computed from the manifest in Step 1
3. If any documents are missing, list them and warn the user
4. If the subagent failed or returned incomplete results, tell the user and offer to re-run

Do NOT read the full `impact.md` into context. Use the summary to validate.

### Step 5: Generate Snapshot

Run: `.syskit/scripts/manifest-snapshot.sh .syskit/analysis/<folder>/`

If NOT in incremental mode, clean up the draft staging directory:

```bash
rm -rf .syskit/analysis/_draft/
```

### Step 6: Next Step

Present the summary counts to the user.

**If in incremental mode**, also show a comparison: "Previous analysis had \<n\> documents affected. After refinement: \<n\> documents now affected."

Tell the user:

"Impact analysis complete. Results saved to `.syskit/analysis/<folder>/impact.md`.

Next step: run `/syskit-propose` to propose specification changes based on this analysis. You can run it right here in this conversation or start a new one."
