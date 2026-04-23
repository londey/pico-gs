# REQ-000: Template

This is a template file. Create new requirements using:

```bash
.syskit/scripts/new-req.sh <requirement_name>
```

Or copy this template and modify.

---

## Requirement

When [condition/trigger], the system SHALL [observable behavior/response].

Format: **When** [condition], the system **SHALL/SHOULD/MAY** [behavior].

- Each requirement must have a testable trigger condition and observable outcome
- Describe capabilities/behaviors, not data layout or encoding
- For struct fields, byte formats, protocols → create an interface (INT-NNN) and reference it

## Rationale

<Why this requirement exists. Keep to ≤ 2 sentences; explain the *why*, do not restate the requirement or enumerate all design options.>

## Parent Requirements

- REQ-NNN (<parent requirement name>)
- Or "None" if this is a top-level requirement
- Child requirements use hierarchical IDs: REQ-NNN.NN (e.g., REQ-004.01 is a child of REQ-004)

## Interfaces

- INT-NNN (<interface name>)

## Verification Method

<How this requirement will be verified: Test | Analysis | Inspection | Demonstration. VER docs that cover this requirement list it in their "Verifies Requirements" section — do not mirror that list here.>

## Notes

<Optional. Include only if there is genuine context, caveat, or open question to add — do not restate the requirement or title.>
