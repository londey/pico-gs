# UNIT-000: Template

This is a template file. Create new design units using:

```bash
.syskit/scripts/new-unit.sh <unit_name>
```

Or copy this template and modify.

---

## Purpose

<What this unit does and why it exists>

A design unit is a cohesive piece of the system that can be implemented and tested somewhat independently. It might be:
- A Verilog module
- A C source file or library
- A class or module in higher-level languages
- A logical grouping of closely related code

## Implements Requirements

- REQ-NNN (<requirement name>)

List all requirements this unit helps satisfy.

## Interfaces

### Provides

- INT-NNN (<interface name>)

Interfaces this unit implements (is the provider of).

### Consumes

- INT-NNN (<interface name>)

Interfaces this unit uses (is a consumer of).

### Internal Interfaces

- Connects to UNIT-NNN via <description>

Internal connections not formally specified as interfaces.

## Design Description

<How this unit works>

### Inputs

<Input signals, parameters, or data>

### Outputs

<Output signals, parameters, or data>

### Internal State

<Any internal state maintained by this unit>

### Algorithm / Behavior

<Description of the unit's behavior, state machines, data flow>

## Implementation

- `<filepath>`: <description>

List all source files that implement this unit.

## Verification

- `<test filepath>`: <what it tests>

List all test files for this unit.

## Design Notes

<Additional design considerations>

Consider documenting:
- Alternatives considered and why they were rejected
- Performance characteristics
- Resource usage (for FPGA: LUTs, registers, BRAM)
- Known limitations
- Future improvement ideas
