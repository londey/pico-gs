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

### Step 1: Read Manifest

Read `.syskit/manifest.md` to get the current list of all specification documents and their hashes.

Count the total number of specification documents listed (excluding any with `_000_template` in the name). You will use this count to validate the subagent's output.

### Step 2: Create Analysis Folder

Create the analysis folder: `.syskit/analysis/{{DATE}}_<change_name>/`

Also create a draft staging directory: `.syskit/analysis/_draft/`

### Step 3: Delegate Document Analysis

Use the Task tool to launch a subagent that reads and analyzes all specification documents. This keeps the full document contents out of your context window.

Launch a `general-purpose` Task agent with this prompt (substitute the actual proposed change for PROPOSED_CHANGE below, and the analysis folder path for ANALYSIS_FOLDER):

> You are analyzing the impact of a proposed change on specification documents.
>
> ## Proposed Change
>
> PROPOSED_CHANGE
>
> ## Instructions
>
> 1. Read ALL markdown files in these directories:
>    - `doc/requirements/`
>    - `doc/interfaces/`
>    - `doc/design/`
>
>    Skip any files with `_000_template` in the name.
>
> 2. For each document, extract:
>    - The document ID (from the H1 heading, e.g., "REQ-001", "INT-003", "UNIT-007")
>    - The document title (from the H1 heading after the ID)
>    - All cross-references to other documents (REQ-NNN, INT-NNN, UNIT-NNN mentions)
>    - A brief summary of what the document specifies (1-2 sentences)
>
> 3. Analyze each document against the proposed change. Categorize as:
>    - **DIRECT**: The document itself describes something being changed
>    - **INTERFACE**: The document defines or uses an interface affected by the change
>    - **DEPENDENT**: The document depends on something being changed (via REQ/INT/UNIT references to a DIRECT or INTERFACE document)
>    - **UNAFFECTED**: The document is not impacted
>
>    When tracing dependencies:
>    - If a requirement is DIRECT, check which design units have it in "Implements Requirements" (those are DEPENDENT)
>    - If a requirement is DIRECT, check which interfaces it lists under "Interfaces" (those are INTERFACE)
>    - If an interface is DIRECT or INTERFACE, check which units list it under "Provides" or "Consumes" (those are DEPENDENT)
>    - If a design unit is DIRECT, check which requirements it implements (review for DEPENDENT impact)
>
> 4. Write your complete analysis to `ANALYSIS_FOLDER/impact.md` in this format:
>
>    ```markdown
>    # Impact Analysis: <brief change summary>
>
>    Created: <timestamp>
>    Status: Pending Review
>
>    ## Proposed Change
>
>    <detailed description of the change>
>
>    ## Direct Impacts
>
>    ### <filename>
>    - **ID:** <REQ/INT/UNIT-NNN>
>    - **Title:** <document title>
>    - **Impact:** <what specifically is affected, 1-2 sentences>
>    - **Action Required:** <modify/review/no change>
>    - **Key References:** <cross-referenced IDs found in this document>
>
>    ## Interface Impacts
>
>    ### <filename>
>    - **ID:** <INT-NNN>
>    - **Title:** <document title>
>    - **Impact:** <what specifically is affected>
>    - **Consumers:** <UNIT-NNN that consume this interface>
>    - **Providers:** <UNIT-NNN that provide this interface>
>    - **Action Required:** <modify/review/no change>
>
>    ## Dependent Impacts
>
>    ### <filename>
>    - **ID:** <REQ/INT/UNIT-NNN>
>    - **Title:** <document title>
>    - **Dependency:** <what it depends on that is changing, with specific ID>
>    - **Impact:** <what specifically is affected>
>    - **Action Required:** <modify/review/no change>
>
>    ## Unaffected Documents
>
>    | Document | ID | Reason Unaffected |
>    |----------|-----|-------------------|
>    | <filename> | <ID> | <brief reason> |
>
>    ## Summary
>
>    - **Total Documents:** <n>
>    - **Directly Affected:** <n>
>    - **Interface Affected:** <n>
>    - **Dependently Affected:** <n>
>    - **Unaffected:** <n>
>
>    ## Recommended Next Steps
>
>    1. <first action>
>    2. <second action>
>    ```
>
>    If a category has no documents, include the heading with "None." underneath.
>
> 5. After writing the file, return ONLY this compact summary (nothing else):
>
>    IMPACT_SUMMARY_START
>    Total: <n> documents analyzed
>    Direct: <n> — <comma-separated filenames>
>    Interface: <n> — <comma-separated filenames>
>    Dependent: <n> — <comma-separated filenames>
>    Unaffected: <n>
>    Written to: ANALYSIS_FOLDER/impact.md
>    IMPACT_SUMMARY_END

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
