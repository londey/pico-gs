---
description: Show traceability tree for any syskit ID with links and summaries
arguments:
  - name: id
    description: "A syskit ID to trace (e.g., REQ-001, INT-002, UNIT-003, VER-004, REQ-001.01)"
    required: true
---

# Traceability Trace

You are showing the traceability tree for a syskit specification ID.

## Target ID

$ARGUMENTS.id

## Instructions

### Step 1: Run Trace Script

Run the trace helper script:

```bash
.syskit/scripts/trace.sh "$ARGUMENTS.id"
```

If the script exits with code 2 (ID not found), show the user the list of available IDs from the error output and stop.

If the script exits with code 1 (error), show the error and stop.

### Step 2: Parse Trace Data

Parse the structured output between `TRACE_DATA_START` and `TRACE_DATA_END`. The format is:

- `NODE <depth> <ID>` — a traced item (depth 0 = root, depth 1 = neighbor)
- `  FILE <path>` — relative file path for the node
- `  TITLE <name>` — human-readable title
- `  SUMMARY <text>` — brief summary extracted from the document
- `  SECTION <name>` — a relationship category
- `    LINK <ID> | <path> | <title>` — a related item within that section
- `    IMPL <path>` — an implementation source file (for design units)

### Step 3: Read Root Document

Read the root node's file (the depth-0 NODE) to get a richer understanding of its purpose. Extract:

- For **REQ-**: the full requirement statement and rationale
- For **UNIT-**: the purpose and key design decisions
- For **INT-**: the type and specification overview
- For **VER-**: the verification method and expected results

Keep this concise — one or two sentences per item.

### Step 4: Present Traceability Tree

Present the results as a visual tree. Use this format:

```
<ID>: <Title>
<file_path>
<Brief description of what this is and why it exists>

Traces:
├── <Section Name>
│   ├── <ID>: <Title>  (<file_path>)
│   │   <One-line summary>
│   └── <ID>: <Title>  (<file_path>)
│       <One-line summary>
├── <Section Name>
│   └── <ID>: <Title>  (<file_path>)
│       <One-line summary>
└── <Section Name>
    └── <ID>: <Title>  (<file_path>)
        <One-line summary>
```

For each linked item, include:
1. The ID and title
2. The file path (so the user can navigate to it)
3. A one-line summary from the trace data (SUMMARY field), or from the TITLE if no summary was extracted

For **UNIT-** nodes that have implementation files, add an "Implementation Files" section showing the source file paths.

### Step 5: Coverage Assessment

After the tree, provide a brief coverage assessment:

1. **Trace completeness** — Flag any sections that are empty or contain only placeholders (TBD, None, etc.). For example:
   - A requirement with no "Allocated To" unit → "Not yet allocated to a design unit"
   - A requirement with no "Verified By" → "No verification defined"
   - A design unit with no "Implements Requirements" → "No requirements traced"
   - An interface with no provider or consumer → "Missing party assignments"

2. **Orphan check** — If the root item is not referenced by ANY other document (based on the depth-1 neighbors' back-links), flag it as potentially orphaned.

Keep the assessment brief — just list the gaps, don't elaborate.

### Formatting Notes

- Use tree-drawing characters (├── └── │) for the visual tree
- Show file paths to help the user navigate
- Keep summaries to one line each — this is an overview, not a full report
- If there are no traces in any direction, say "No traces found — this item is isolated."
