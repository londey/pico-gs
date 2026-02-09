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

### Step 3: Load Affected Documents

Load the full content of all documents marked as affected in the impact analysis.

### Step 4: Propose Changes

For each affected document, propose specific modifications:

1. Show the relevant current content
2. Explain what needs to change and why
3. Show the proposed new content
4. Note any ripple effects to other documents

### Step 5: Write Proposed Changes

Create/update `.syskit/analysis/<folder>/proposed_changes.md`:

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
