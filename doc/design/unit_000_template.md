# UNIT-000: Template

This is a template file. Create new design units using:

```bash
.syskit/scripts/new-unit.sh <unit_name>
```

Or copy this template and modify.

---

## Purpose

<What this unit does and why it exists>

## Implements Requirements

- REQ-NNN (<requirement name>)

List all requirements this unit helps satisfy.

## Interfaces

### Provides

- INT-NNN (<interface name>)

### Consumes

- INT-NNN (<interface name>)

### Internal Interfaces

- Connects to UNIT-NNN via <description>

## Design Description

<How this unit works. Describe inputs, outputs, internal state, and algorithm together — add the sub-headings below only when the content would otherwise be hard to navigate. Do not keep empty headings as placeholders.>

## Implementation

- `<filepath>`: <description>

List all source files that implement this unit.

## Design Notes

<Optional. Document non-obvious alternatives considered, performance characteristics, or known limitations. Do not duplicate bit-accurate algorithms from the digital twin, register layouts from `gpu_regs.rdl`, or resource budgets from `pipeline/pipeline.yaml` — link to the authoritative source instead.>
