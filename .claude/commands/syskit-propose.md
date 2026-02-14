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

### Step 1: Check Git Status

Run `git status -- doc/` to check for uncommitted changes in the doc directory.

If there are uncommitted changes in `doc/`, **stop and tell the user:**

"There are uncommitted changes in `doc/`. Please commit or stash them before running `/syskit-propose`, so that proposed changes can be reviewed with `git diff` and reverted cleanly if needed."

### Step 2: Load the Impact Analysis

If `$ARGUMENTS.analysis` is provided:
- Load `.syskit/analysis/$ARGUMENTS.analysis/impact.md`
- Load `.syskit/analysis/$ARGUMENTS.analysis/snapshot.md`

Otherwise:
- Find the most recent folder in `.syskit/analysis/`
- Load `impact.md` and `snapshot.md` from that folder

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

From the impact analysis, count the number of documents with Action Required of "modify" or "review" (across Direct, Interface, and Dependent categories).

Note the list of affected filenames — you will use this to determine the delegation strategy.

### Step 5: Delegate Change Drafting

Choose the delegation strategy based on the count of affected documents:

- **8 or fewer affected documents:** Use a single subagent (Step 5a)
- **More than 8 affected documents:** Use chunked subagents (Step 5b)

#### Step 5a: Single Subagent

Launch a `general-purpose` Task agent with this prompt (substitute ANALYSIS_FOLDER with the actual path, and PROPOSED_CHANGE with the proposed change description from the impact analysis):

> You are drafting and applying proposed specification changes based on a completed impact analysis.
>
> ## Proposed Change
>
> PROPOSED_CHANGE
>
> ## Instructions
>
> 1. Read the impact analysis from: `ANALYSIS_FOLDER/impact.md`
>
> 2. Read each document listed as affected (DIRECT, INTERFACE, or DEPENDENT with Action Required of "modify" or "review"). Read them from the `doc/` directories.
>
> 3. For each affected document, **edit the file directly** with the proposed changes:
>    - Make the specific modifications needed to address the proposed change
>    - Ensure all cross-references (REQ-NNN, INT-NNN, UNIT-NNN) remain consistent
>    - For requirement documents, ensure every requirement uses the condition/response pattern: "When [condition], the system SHALL [observable behavior]."
>
> 4. While editing, validate each requirement you modify or create:
>    - **Format:** Must use condition/response pattern. If it lacks a trigger condition, add one.
>    - **Appropriate Level:** If it specifies data layout, register fields, byte encoding, packet structure, or wire protocol details, flag this — that detail belongs in an interface document.
>    - **Singular:** If it addresses multiple capabilities, split it into separate requirements.
>    - **Verifiable:** The condition must define a clear test setup and the behavior a clear pass criterion.
>
> 5. Write a change summary to `ANALYSIS_FOLDER/proposed_changes.md` in this format:
>
>    ```markdown
>    # Proposed Changes: <change name>
>
>    Based on: impact.md
>    Created: <timestamp>
>    Status: Pending Approval
>
>    ## Change Summary
>
>    | Document | Type | Change Description |
>    |----------|------|-------------------|
>    | <filename> | Modify | <brief description> |
>
>    ## Document: <filename>
>
>    ### Rationale
>
>    <why this change is needed>
>
>    ### Changes Made
>
>    <brief description of what was modified — the actual diff is in git>
>
>    ### Ripple Effects
>
>    - <any effects on other documents>
>
>    ---
>
>    (repeat for each affected document)
>
>    ## Quality Warnings
>
>    <list any requirement quality issues found, or "None.">
>    ```
>
> 6. After editing all documents and writing the summary, return ONLY this compact response (nothing else):
>
>    PROPOSE_SUMMARY_START
>    Documents edited: <n>
>    Files: <comma-separated filenames>
>    Quality warnings: <n> (<brief list or "None">)
>    Summary written to: ANALYSIS_FOLDER/proposed_changes.md
>    PROPOSE_SUMMARY_END

#### Step 5b: Chunked Subagents

Split the affected documents into groups of at most 8, keeping related documents together (e.g., a requirement and the interface it references in the same group). Use the cross-references from the impact analysis to determine grouping.

For each chunk, launch a `general-purpose` Task agent with this prompt (substitute ANALYSIS_FOLDER, PROPOSED_CHANGE, CHUNK_NUMBER, and ASSIGNED_FILES):

> You are drafting and applying proposed specification changes for a subset of affected documents.
>
> ## Proposed Change
>
> PROPOSED_CHANGE
>
> ## Your Assigned Documents
>
> ASSIGNED_FILES
>
> ## Instructions
>
> 1. Read the impact analysis from: `ANALYSIS_FOLDER/impact.md`
>
> 2. Read ONLY the documents assigned to you (listed above) from the `doc/` directories.
>
> 3. For each assigned document, **edit the file directly** with the proposed changes:
>    - Make the specific modifications needed to address the proposed change
>    - Ensure all cross-references (REQ-NNN, INT-NNN, UNIT-NNN) remain consistent
>    - For requirement documents, ensure every requirement uses the condition/response pattern: "When [condition], the system SHALL [observable behavior]."
>
> 4. While editing, validate each requirement you modify or create:
>    - **Format:** Must use condition/response pattern. If it lacks a trigger condition, add one.
>    - **Appropriate Level:** If it specifies data layout, register fields, byte encoding, packet structure, or wire protocol details, flag this — that detail belongs in an interface document.
>    - **Singular:** If it addresses multiple capabilities, split it into separate requirements.
>    - **Verifiable:** The condition must define a clear test setup and the behavior a clear pass criterion.
>
> 5. Write a chunk summary to `ANALYSIS_FOLDER/chunk_CHUNK_NUMBER.md` in this format:
>
>    ```markdown
>    ## Document: <filename>
>
>    ### Rationale
>
>    <why this change is needed>
>
>    ### Changes Made
>
>    <brief description of what was modified — the actual diff is in git>
>
>    ### Ripple Effects
>
>    - <any effects on other documents>
>
>    ---
>
>    (repeat for each assigned document)
>    ```
>
> 6. After editing all assigned documents and writing the chunk summary, return ONLY this compact response (nothing else):
>
>    CHUNK_SUMMARY_START
>    Chunk: CHUNK_NUMBER
>    Documents edited: <n>
>    Files: <comma-separated filenames>
>    Quality warnings: <n> (<brief list or "None">)
>    Written to: ANALYSIS_FOLDER/chunk_CHUNK_NUMBER.md
>    CHUNK_SUMMARY_END

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

If the change set affects 5 or more documents, launch a validation Task agent:

> You are reviewing proposed specification changes for quality.
>
> Read all modified files listed in `ANALYSIS_FOLDER/proposed_changes.md` from the `doc/` directories.
>
> Check each modified document for:
> 1. Requirement statements use condition/response format ("When X, the system SHALL Y")
> 2. No implementation details in requirements (data layouts, register fields belong in interfaces)
> 3. Each requirement is singular (not compound)
> 4. Cross-references (REQ-NNN, INT-NNN, UNIT-NNN) are valid and consistent
> 5. Changes align with the rationale described in proposed_changes.md
>
> If you find fixable issues, edit the doc files directly to correct them.
>
> Return ONLY this summary:
>
> VALIDATION_SUMMARY_START
> Documents reviewed: <n>
> Issues found: <n>
> Issues corrected: <n>
> Issues requiring human review: <n> — <brief descriptions if any>
> VALIDATION_SUMMARY_END

### Step 7: Present Changes for Review

Tell the user:

"Proposed changes have been applied directly to the doc files. Review the changes using `git diff doc/` or the VSCode source control panel.

**Summary:**
<paste the change summary table from proposed_changes.md or from the chunk summaries>

**Quality warnings:** <list any, or 'None'>

Reply with:
- **'approve'** to keep all changes and proceed to planning
- **'approve \<filename\>'** to keep changes to a specific file and revert others
- **'revise \<filename\>'** to discuss modifications to a specific file
- **'reject'** to revert all changes (`git checkout -- doc/`)"

### Step 8: Handle Approval

- **approve:** Update `Status: Pending Approval` to `Status: Approved` in `.syskit/analysis/<folder>/proposed_changes.md`. Proceed to Step 9.
- **approve \<filename\>:** Revert all other files with `git checkout -- doc/<other files>`, keep the specified file(s). Update `Status: Pending Approval` to `Status: Approved` in `.syskit/analysis/<folder>/proposed_changes.md`. Proceed to Step 9.
- **revise \<filename\>:** Discuss the specific file with the user, make adjustments, then re-present.
- **reject:** Run `git checkout -- doc/` to revert all changes. Tell the user the proposal has been discarded.

### Step 9: Next Step

After applying approved changes, tell the user:

"Proposed changes applied. Summary saved to `.syskit/analysis/<folder>/proposed_changes.md`.

Next step: run `/syskit-plan` to create an implementation task breakdown.

Tip: Start a new conversation before running the next command to free up context."
