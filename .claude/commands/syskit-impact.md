---
description: Analyze impact of a proposed change across all specifications
arguments:
  - name: change
    description: Description of the proposed change
    required: true
---

# Impact Analysis

You are analyzing the impact of a proposed change on this project's specifications.

## Proposed Change

$ARGUMENTS.change

## Instructions

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for IMPACT_SUMMARY, PROPOSE_SUMMARY, CHUNK_SUMMARY, PLAN_SUMMARY, or IMPLEMENT_SUMMARY markers, or previous `/syskit-*` command invocations), STOP and tell the user:

"This conversation already has syskit command history in context. Start a fresh conversation to run `/syskit-impact` — all progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Read Manifest

Read `.syskit/manifest.md` to get the current list of all specification documents and their hashes.

Count the total number of specification documents listed (excluding any with `_000_template` in the name). You will use this count to validate the subagent's output.

### Step 2: Create Analysis Folder

Create the analysis folder: `.syskit/analysis/{{DATE}}_<change_name>/`

Also create a draft staging directory: `.syskit/analysis/_draft/`

### Step 3: Delegate Document Analysis

Use the Task tool to launch a subagent that reads and analyzes all specification documents. This keeps the full document contents out of your context window.

Launch a `general-purpose` Task agent with this prompt (substitute the actual proposed change for PROPOSED_CHANGE, and the analysis folder path for ANALYSIS_FOLDER):

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

Run: `.syskit/scripts/manifest-snapshot.sh .syskit/analysis/{{DATE}}_<change_name>/`

Clean up the draft staging directory:

```bash
rm -rf .syskit/analysis/_draft/
```

### Step 6: Next Step

Present the summary counts to the user and tell them:

"Impact analysis complete. Results saved to `.syskit/analysis/<folder>/impact.md`.

Next step: run `/syskit-propose` to propose specific changes to the affected documents.

Tip: Start a new conversation before running the next command to free up context."
