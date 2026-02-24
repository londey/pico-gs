# VER-000: Template

This is a template file. Create new verification documents using:

```bash
.syskit/scripts/new-ver.sh <verification_name>
```

Or copy this template and modify.

---

## Verification Method

Choose one:
- **Test:** Verified by executing a test procedure
- **Analysis:** Verified by technical evaluation
- **Inspection:** Verified by examination
- **Demonstration:** Verified by operation

## Verifies Requirements

- REQ-NNN (<requirement name>)

List all requirements this verification procedure covers.

## Verified Design Units

- UNIT-NNN (<unit name>)

List all design units exercised by this verification.

## Preconditions

<What must be true before this verification can be executed>

- System state, configuration, or environment required
- Dependencies on other verifications completing first
- Required test data or fixtures

## Procedure

<Step-by-step verification procedure>

1. <Step 1>
2. <Step 2>
3. ...

For automated tests, describe what the test does at a level useful for understanding intent, not line-by-line code walkthrough.

## Expected Results

<What constitutes a pass>

- **Pass Criteria:** <observable outcome that means the requirement is satisfied>
- **Fail Criteria:** <observable outcome that means the requirement is NOT satisfied>

## Test Implementation

- `<test filepath>`: <description of what this test file does>

List all test source files that implement this verification.

## Notes

<Additional context, edge cases, known limitations of this verification>
