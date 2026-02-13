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

### Step 1: Load the Impact Analysis

If `$ARGUMENTS.analysis` is provided:
- Load `.syskit/analysis/$ARGUMENTS.analysis/impact.md`
- Load `.syskit/analysis/$ARGUMENTS.analysis/snapshot.md`

Otherwise:
- Find the most recent folder in `.syskit/analysis/`
- Load `impact.md` and `snapshot.md` from that folder

### Step 2: Check Freshness

Run the freshness check script:

```bash
.syskit/scripts/manifest-check.sh .syskit/analysis/<folder>/snapshot.md
```

- If any affected documents have changed (exit code 1), warn the user
- Recommend re-running impact analysis if changes are significant
- Proceed with caution if user confirms

### Step 3: Delegate Change Drafting

Use the Task tool to launch a subagent that reads the affected documents and drafts proposed changes. This keeps the full document contents out of your context window.

Launch a `general-purpose` Task agent with this prompt (substitute the actual impact.md content for IMPACT_CONTENT below, and the proposed change description for PROPOSED_CHANGE):

> You are drafting proposed specification changes based on a completed impact analysis.
>
> ## Proposed Change
>
> PROPOSED_CHANGE
>
> ## Impact Analysis
>
> IMPACT_CONTENT
>
> ## Instructions
>
> 1. Read each document listed as affected (DIRECT, INTERFACE, or DEPENDENT) in the impact analysis above. Read them from the `doc/` directories.
>
> 2. For each affected document, draft specific modifications:
>    - Extract the relevant current content (the sections that need to change)
>    - Write the proposed new content
>    - Explain the rationale for the change
>    - Note any ripple effects to other documents
>
> 3. For any proposed changes to requirement documents, validate each requirement statement:
>    - **Format:** Must use the condition/response pattern: "When [condition], the system SHALL [observable behavior]." If a proposed requirement lacks a trigger condition, identify one and rewrite it.
>    - **Appropriate Level:** If the proposed requirement specifies data layout, register fields, byte encoding, packet structure, or wire protocol details, flag this and recommend creating/updating an interface document instead, with the requirement referencing it.
>    - **Singular:** If a proposed requirement addresses multiple capabilities, recommend splitting it.
>    - **Verifiable:** The condition must define a clear test setup and the behavior a clear pass criterion.
>    If any proposed requirement fails validation, include the quality issue in the Rationale section and present a corrected version alongside the original.
>
> 4. Return your draft in EXACTLY this structured format:
>
> PROPOSED_CHANGES_START
>
> ## Document: filename
>
> ### Current Content (relevant section)
>
> (paste the relevant current content here)
>
> ### Proposed Content
>
> (paste the proposed new content here)
>
> ### Rationale
>
> (why this change is needed)
>
> ### Ripple Effects
>
> - (any effects on other documents)
>
> ---
>
> ## Document: next filename
>
> (repeat for each affected document)
>
> ---
>
> ## Change Summary
>
> | Document | Type | Change Description |
> |----------|------|-------------------|
> | filename | Modify | brief description |
>
> ## Quality Warnings
>
> (list any requirement quality issues found, or "None.")
>
> PROPOSED_CHANGES_END
>
> Include all affected documents. If a document needs review but no content changes, note that in its Rationale section.

### Step 4: Review Agent Draft

After the subagent returns:

1. Extract the content between the `PROPOSED_CHANGES_START` and `PROPOSED_CHANGES_END` markers
2. Review the draft for completeness — ensure all affected documents from the impact analysis are covered
3. Review quality warnings and ensure requirement validation was thorough
4. If the subagent failed or returned incomplete results, tell the user and offer to fall back to direct analysis

### Step 5: Write Proposed Changes

Create/update `.syskit/analysis/<folder>/proposed_changes.md` using the agent's draft:

```markdown
# Proposed Changes: <change name>

Based on: impact.md
Created: <timestamp>
Status: Pending Approval

## Document: <filename>

### Current Content (relevant section)

```
<current content>
```

### Proposed Content

```
<proposed content>
```

### Rationale

<why this change is needed>

### Ripple Effects

- <any effects on other documents>

---

## Document: <next filename>

...

---

## Change Summary

| Document | Type | Change Description |
|----------|------|-------------------|
| <filename> | Modify | <brief description> |
| <filename> | Add Section | <brief description> |
| <filename> | Remove | <brief description> |

## Approval Checklist

- [ ] Requirements changes reviewed
- [ ] Interface changes reviewed
- [ ] Design changes reviewed
- [ ] No unintended impacts identified
- [ ] Ready to apply changes
```

### Step 6: Request Approval

Present a summary of all proposed changes and ask:

"Please review the proposed changes above. Reply with:
- 'approve' to apply all changes
- 'approve <filename>' to apply changes to a specific file
- 'revise <filename>' to discuss modifications
- 'reject' to discard this proposal"

### Step 7: Next Step

After applying approved changes, tell the user:

"Proposed changes applied. Results saved to `.syskit/analysis/<folder>/proposed_changes.md`.

Next step: run `/syskit-plan` to create an implementation task breakdown.

Tip: Start a new conversation before running the next command to free up context."
