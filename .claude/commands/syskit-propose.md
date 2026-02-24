---
description: Propose specific modifications to specifications based on impact analysis
arguments:
  - name: analysis
    description: Name of the analysis folder (optional, uses most recent if not specified)
    required: false
---

# Propose Specification Changes

You are proposing specific modifications to specifications based on a completed impact analysis.

## Instructions

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for IMPACT_SUMMARY, PROPOSE_SUMMARY, CHUNK_SUMMARY, PLAN_SUMMARY, or IMPLEMENT_SUMMARY markers, or previous `/syskit-*` command invocations), STOP and tell the user:

"This conversation already has syskit command history in context. Start a fresh conversation to run `/syskit-propose` — all progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Check Git Status

Run `git status -- doc/` to check for uncommitted changes in the doc directory.

If there are uncommitted changes in `doc/`, **stop and tell the user:**

"There are uncommitted changes in `doc/`. Please commit or stash them before running `/syskit-propose`, so that proposed changes can be reviewed with `git diff` and reverted cleanly if needed."

### Step 2: Load the Impact Analysis

If `$ARGUMENTS.analysis` is provided:

- Find the analysis folder: `.syskit/analysis/$ARGUMENTS.analysis/`

Otherwise:

- Find the most recent folder in `.syskit/analysis/`

Read ONLY the `## Summary` section from `impact.md` (the last ~15 lines) to get document counts and the list of affected filenames. Do NOT load the full impact.md into context.

Also note the proposed change description from the first few lines of impact.md.

Note the analysis folder path — you will pass it to subagents.

### Step 3: Check Freshness

Run the freshness check script:

```bash
.syskit/scripts/manifest-check.sh .syskit/analysis/<folder>/snapshot.md
```

- If any affected documents have changed (exit code 1), warn the user
- Recommend re-running impact analysis if changes are significant
- Proceed with caution if user confirms

### Step 4: Count Affected Documents

From the summary counts, determine the number of documents with Action Required of "modify" or "review" (across Direct, Interface, and Dependent categories).

### Step 5: Delegate Change Drafting

Choose the delegation strategy based on the count of affected documents:

- **8 or fewer affected documents:** Use a single subagent (Step 5a)
- **More than 8 affected documents:** Use chunked subagents (Step 5b)

#### Step 5a: Single Subagent

Launch a `general-purpose` Task agent with **model: sonnet** and this prompt (substitute ANALYSIS_FOLDER and PROPOSED_CHANGE):

> Read your full instructions from `.syskit/prompts/propose-single.md`.
>
> Use these values for placeholders in the prompt file:
> - `{{PROPOSED_CHANGE}}`: PROPOSED_CHANGE
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

The subagent will return a summary in `PROPOSE_SUMMARY_START`/`PROPOSE_SUMMARY_END` format.

#### Step 5b: Chunked Subagents

Split the affected documents into groups of at most 8, keeping related documents together (e.g., a requirement and the interface it references in the same group).

For each chunk, launch a `general-purpose` Task agent with **model: sonnet** and this prompt (substitute ANALYSIS_FOLDER, PROPOSED_CHANGE, CHUNK_NUMBER, and ASSIGNED_FILES):

> Read your full instructions from `.syskit/prompts/propose-chunk.md`.
>
> Use these values for placeholders in the prompt file:
> - `{{PROPOSED_CHANGE}}`: PROPOSED_CHANGE
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
> - `{{CHUNK_NUMBER}}`: CHUNK_NUMBER
> - `{{ASSIGNED_FILES}}`: ASSIGNED_FILES
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

Launch all chunk agents in parallel where possible.

After ALL chunk agents complete, assemble the final summary:

1. Create the header for `proposed_changes.md` with the change name, timestamp, status, and a change summary table built from the chunk summaries
2. Use bash to assemble: `.syskit/scripts/assemble-chunks.sh .syskit/analysis/<folder>/proposed_changes.md .syskit/analysis/<folder>/ "chunk_*.md"`
3. Prepend the header to the assembled file

### Step 6: Validate Proposed Changes

After the subagent(s) return:

1. Parse the summary to verify all affected documents were edited
2. Note any quality warnings reported
3. If the subagent failed or returned incomplete results, tell the user and offer to re-run

If the change set affects 5 or more documents, launch a validation Task agent with **model: haiku**:

> Read your full instructions from `.syskit/prompts/propose-validate.md`.
>
> Use this value for placeholders in the prompt file:
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

The subagent will return a summary in `VALIDATION_SUMMARY_START`/`VALIDATION_SUMMARY_END` format.

### Step 7: Present Changes for Review

Tell the user:

"Proposed changes have been applied directly to the doc files. Review the changes using `git diff doc/` or the VSCode source control panel.

**Summary:**
<paste the change summary table from the subagent's returned summary>

**Quality warnings:** <list any, or 'None'>

Reply with:
- **'approve'** to keep all changes and proceed to planning
- **'approve \<filename\>'** to keep changes to a specific file and revert others
- **'revise \<filename\>'** to discuss modifications to a specific file
- **'reject'** to revert all changes (`git checkout -- doc/`)

Or review at your leisure and use these commands in a new session:
- **`/syskit-refine --feedback \"<your feedback>\"`** to iterate on the proposed changes
- **`/syskit-approve`** to approve when ready"

### Step 8: Handle Approval

- **approve:** Update `Status: Pending Approval` to `Status: Approved` in `.syskit/analysis/<folder>/proposed_changes.md`. Proceed to Step 9.
- **approve \<filename\>:** Revert all other files with `git checkout -- doc/<other files>`, keep the specified file(s). Update `Status: Pending Approval` to `Status: Approved` in `.syskit/analysis/<folder>/proposed_changes.md`. Proceed to Step 9.
- **revise \<filename\>:** Discuss the specific file with the user, make adjustments, then re-present.
- **reject:** Run `git checkout -- doc/` to revert all changes. Tell the user the proposal has been discarded.

### Step 9: Next Steps

After applying approved changes, tell the user:

"Changes approved. Summary saved to `.syskit/analysis/<folder>/proposed_changes.md`.

Next step: run `/syskit-plan` to create an implementation task breakdown.

Tip: Start a new conversation before running the next command to free up context."
