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

### Step 1: Load All Documents

Read all files in:
- `doc/requirements/`
- `doc/interfaces/`
- `doc/design/`

Also read `.syskit/manifest.md` for current file hashes.

### Step 2: Analyze Each Document

For each document, determine if it would be affected by the proposed change.

Categorize impacts as:

- **DIRECT**: The document itself describes something being changed
- **INTERFACE**: The document defines or uses an interface affected by the change
- **DEPENDENT**: The document depends on something being changed (via REQ/INT/UNIT references)
- **UNAFFECTED**: The document is not impacted (state why)

### Step 3: Create Analysis Folder

Create `.syskit/analysis/{{DATE}}_<change_name>/` with:

1. `impact.md` — The impact report (format below)
2. `snapshot.md` — SHA256 of each analyzed document from manifest

### Step 4: Output Impact Report

Use this format for `impact.md`:

```markdown
# Impact Analysis: <brief change summary>

Created: <timestamp>
Status: Pending Review

## Proposed Change

<detailed description of the change>

## Direct Impacts

### <filename>
- **ID:** <REQ/INT/UNIT-NNN>
- **Impact:** <what specifically is affected>
- **Action Required:** <modify/review/no change>

## Interface Impacts

### <filename>
- **ID:** <INT-NNN>
- **Impact:** <what specifically is affected>
- **Consumers:** <list of units that consume this interface>
- **Providers:** <list of units that provide this interface>
- **Action Required:** <modify/review/no change>

## Dependent Impacts

### <filename>
- **ID:** <REQ/INT/UNIT-NNN>
- **Dependency:** <what it depends on that is changing>
- **Impact:** <what specifically is affected>
- **Action Required:** <modify/review/no change>

## Unaffected Documents

| Document | ID | Reason Unaffected |
|----------|-----|-------------------|
| <filename> | <ID> | <brief reason> |

## Summary

- **Total Documents:** <n>
- **Directly Affected:** <n>
- **Interface Affected:** <n>
- **Dependently Affected:** <n>
- **Unaffected:** <n>

## Recommended Next Steps

1. <first action>
2. <second action>
...
```

### Step 5: Ask for Confirmation

After presenting the impact report, ask:

"Shall I proceed with proposing specific modifications to the affected documents?"
