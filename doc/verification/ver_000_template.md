# VER-000: Template

This is a template file. Create new verification documents using:

```bash
.syskit/scripts/new-ver.sh <verification_name>
```

Or copy this template and modify.

---

## Verification Method

Test | Analysis | Inspection | Demonstration

## Verifies Requirements

- REQ-NNN (<requirement name>)

List all requirements this verification procedure covers.

## Verified Design Units

- UNIT-NNN (<unit name>)

List all design units exercised by this verification.

## Preconditions

<Only list setup specific to this verification (pre-loaded fixtures, unusual configuration, dependencies on other verifications). Do not restate the shared Verilator/toolchain preconditions — see `test_strategy.md`.>

## Procedure

<Step-by-step verification procedure. End each step with an explicit `**Pass:** …` clause stating the observable outcome that means the step passed. A separate "Fail Criteria" list is not required — anything that violates a Pass clause is a fail.>

1. **<Short step title>.**
   <What the step does.>
   **Pass:** <observable outcome that means this step is satisfied.>

2. ...

For automated tests, describe what the test does at a level useful for understanding intent, not line-by-line code walkthrough.

## Test Implementation

- `<test filepath>`: <description of what this test file does>

List all test source files that implement this verification.
Each test file listed here should contain a `Ver-ref` comment pointing back to this document.
See `.syskit/ref/ver-ref.md` for the Ver-ref format and workflow.

## Notes

<Optional. Edge cases, known limitations, or context that does not belong in the Procedure.>
