---
description: Propose scoped specification changes based on impact analysis
arguments:
  - name: scope
    description: "Scope of documents to refine: 'requirements', 'interfaces', 'design', or comma-separated doc IDs (e.g., 'REQ-001,INT-003')"
    required: true
  - name: analysis
    description: Name of the analysis folder (optional, uses most recent if not specified)
    required: false
---

# Refine Specifications (Scoped)

You are proposing specification changes for a targeted subset of documents, based on a completed impact analysis.

## Instructions

### Step 0: Context Check

If this conversation already contains output from a previous syskit command (look for IMPACT_SUMMARY, PROPOSE_SUMMARY, CHUNK_SUMMARY, PLAN_SUMMARY, IMPLEMENT_SUMMARY, or REFINE_SUMMARY markers, or previous `/syskit-*` command invocations), STOP and tell the user:

"This conversation already has syskit command history in context. Start a fresh conversation to run `/syskit-refine` — all progress is saved to disk and will be picked up automatically."

If the user explicitly included `--continue` in their command, skip this check and proceed.

### Step 1: Check Git Status

Run `git status -- doc/` to check for uncommitted changes in the doc directory.

If there are uncommitted changes in `doc/`, **stop and tell the user:**

"There are uncommitted changes in `doc/`. Please commit or stash them before running `/syskit-refine`, so that proposed changes can be reviewed with `git diff` and reverted cleanly if needed."

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

### Step 4: Parse Scope and Filter Documents

Parse `$ARGUMENTS.scope`:

- **"requirements"**: Filter to documents with filenames matching `req_*` (REQ-NNN IDs)
- **"interfaces"**: Filter to documents with filenames matching `int_*` (INT-NNN IDs)
- **"design"**: Filter to documents with filenames matching `unit_*` (UNIT-NNN IDs)
- **Comma-separated IDs** (e.g., "REQ-001,INT-003"): Filter to exactly those document IDs by matching them against filenames in the impact summary

From the impact summary, identify which affected documents (Action Required of "modify" or "review") fall within the scope.

If no affected documents match the scope, tell the user:

"No documents with required changes match scope '$ARGUMENTS.scope'. The following scopes have pending changes: \<list scopes with pending docs\>."

### Step 5: Load Refine Status

Check if `.syskit/analysis/<folder>/refine_status.md` exists.

If it exists, read it. Note which scopes have already been refined and approved. If the current scope is already marked "Approved", warn the user:

"Scope '$ARGUMENTS.scope' was already refined and approved. Re-running will overwrite those changes. Continue? (yes/no)"

If it does not exist, this is the first refinement iteration — you will create it in Step 8.

### Step 6: Delegate Scoped Change Drafting

Count the affected documents in scope.

**8 or fewer documents (typical for scoped work):** Launch a single subagent.

Launch a `general-purpose` Task agent with **model: sonnet** and this prompt (substitute ANALYSIS_FOLDER, PROPOSED_CHANGE, SCOPE_FILTER, and SCOPE_NAME with actual values):

> Read your full instructions from `.syskit/prompts/refine-single.md`.
>
> Use these values for placeholders in the prompt file:
> - `{{PROPOSED_CHANGE}}`: PROPOSED_CHANGE
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
> - `{{SCOPE_FILTER}}`: SCOPE_FILTER (the list of specific filenames to modify)
> - `{{SCOPE_NAME}}`: SCOPE_NAME (e.g., "requirements", "interfaces", "design", or "custom")
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

The subagent will return a summary in `REFINE_SUMMARY_START`/`REFINE_SUMMARY_END` format.

**More than 8 documents:** Use the same chunked approach as propose — launch multiple subagents with `.syskit/prompts/propose-chunk.md`, passing only the scoped file list as `{{ASSIGNED_FILES}}`. Launch all chunk agents in parallel. After all complete, assemble results with `.syskit/scripts/assemble-chunks.sh`.

### Step 7: Validate Proposed Changes

After the subagent(s) return:

1. Parse the summary to verify all scoped documents were edited
2. Note any quality warnings reported
3. If the subagent failed or returned incomplete results, tell the user and offer to re-run

If the scoped change set affects 5 or more documents, launch a validation Task agent with **model: haiku**:

> Read your full instructions from `.syskit/prompts/propose-validate.md`.
>
> Use this value for placeholders in the prompt file:
> - `{{ANALYSIS_FOLDER}}`: ANALYSIS_FOLDER
>
> Follow the instructions in the prompt file. Return ONLY the compact summary described at the end.

The subagent will return a summary in `VALIDATION_SUMMARY_START`/`VALIDATION_SUMMARY_END` format.

### Step 8: Update Refine Status

Create or update `.syskit/analysis/<folder>/refine_status.md` with the following format:

```markdown
# Refinement Status

Analysis: <folder name>
Change: <change description>
Status: In Progress

## Iterations

### <scope_name> (Iteration <n>)
- Scope: <scope description>
- Documents: <comma-separated filenames>
- Status: Pending Approval
- Refinement file: refine_<scope_name>.md
```

Include all previous iterations (from any existing refine_status.md) with their current statuses. Add the current scope as a new iteration entry with `Status: Pending Approval`.

Add a `## Remaining Scopes` section listing any scopes that still have affected documents not yet refined:

```markdown
## Remaining Scopes

- <scope>: <n> documents with pending changes
```

Update the top-level `Status:` to "Complete" only when all affected documents across all scopes have been refined and approved.

### Step 9: Present Changes for Review

Tell the user:

"Scoped changes for **\<scope\>** have been applied to the doc files. Review using `git diff doc/` or the VSCode source control panel.

**Scope:** \<scope description\>
**Documents modified:** \<n\>
**Summary:**
\<paste the change summary table from the subagent's returned summary\>

**Quality warnings:** \<list any, or 'None'\>

Reply with:
- **'approve'** to keep all scoped changes
- **'approve \<filename\>'** to keep changes to a specific file and revert others
- **'revise \<filename\>'** to discuss modifications to a specific file
- **'reject'** to revert all scoped changes"

### Step 10: Handle Approval

- **approve:** Update the current scope's Status to "Approved" in `refine_status.md`. Proceed to Step 11.
- **approve \<filename\>:** Revert non-specified scoped files with `git checkout -- doc/<other scoped files>`, keep the specified file(s). Update status accordingly. Proceed to Step 11.
- **revise \<filename\>:** Discuss the specific file with the user, make adjustments, then re-present for review.
- **reject:** Run `git checkout -- <scoped files>` to revert only the scoped changes. Update scope Status to "Rejected" in `refine_status.md`.

### Step 11: Next Steps

After applying approved changes, check `refine_status.md` for remaining scopes with pending changes.

If there are remaining scopes, tell the user:

"Scoped refinement for **\<scope\>** approved.

**Refinement progress:**
\<list each scope and its status\>

Recommended next steps:
- Run `/syskit-impact --incremental` to re-analyze impacts with your approved \<scope\> changes incorporated
- Run `/syskit-refine --scope <next_scope>` to refine the next document type
- Run `/syskit-plan` if all refinement is complete

Tip: Start a new conversation before running the next command to free up context."

If all scopes are approved (top-level Status: Complete), tell the user:

"All document scopes have been refined and approved.

Next step: run `/syskit-plan` to create an implementation task breakdown.

Tip: Start a new conversation before running the next command to free up context."
