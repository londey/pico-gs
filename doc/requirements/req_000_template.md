# REQ-000: Template

This is a template file. Create new requirements using:

```bash
.syskit/scripts/new-req.sh <requirement_name>
```

Or copy this template and modify.

---

## Classification

- **Priority:** Essential | Important | Nice-to-have
- **Stability:** Stable | Evolving | Volatile
- **Verification:** Test | Analysis | Inspection | Demonstration

## Requirement

When [condition/trigger], the system SHALL [observable behavior/response].

Format: **When** [condition], the system **SHALL/SHOULD/MAY** [behavior].

- Each requirement must have a testable trigger condition and observable outcome
- Describe capabilities/behaviors, not data layout or encoding
- For struct fields, byte formats, protocols → create an interface (INT-NNN) and reference it

## Rationale

<Why this requirement exists. What problem does it solve? What drives this need?>

## Parent Requirements

- REQ-NNN (<parent requirement name>)
- Or "None" if this is a top-level requirement
- Child requirements use hierarchical IDs: REQ-NNN.NN (e.g., REQ-004.01 is a child of REQ-004)

## Allocated To

- UNIT-NNN (<unit name>)

## Interfaces

- INT-NNN (<interface name>)

## Verification Method

<How this requirement will be verified>

- **Test:** Verified by executing a test procedure
- **Analysis:** Verified by technical evaluation
- **Inspection:** Verified by examination
- **Demonstration:** Verified by operation

## Verified By

- VER-NNN (<verification name>)

## Notes

<Additional context, open questions, or references>
