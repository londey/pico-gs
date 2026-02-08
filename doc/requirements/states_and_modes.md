# States and Modes

This document defines the operational states and modes of the system.

## Definitions

- **State:** A condition of the system characterized by specific behaviors and capabilities
- **Mode:** A variant of operation that affects how the system behaves within a state

## System States

### State: <state name>

- **Description:** <what this state means>
- **Entry Conditions:** <how the system enters this state>
- **Exit Conditions:** <how the system leaves this state>
- **Capabilities:** <what the system can do in this state>
- **Restrictions:** <what the system cannot do in this state>

## Operational Modes

### Mode: <mode name>

- **Description:** <what this mode means>
- **Applicable States:** <which states this mode applies to>
- **Configuration:** <how this mode is selected>
- **Behavior Differences:** <how behavior differs from other modes>

## State Transition Diagram

```
                    ┌─────────────┐
         ┌─────────▶│   State A   │─────────┐
         │          └─────────────┘         │
         │                │                 │
    [condition]      [condition]       [condition]
         │                │                 │
         │                ▼                 │
    ┌────┴────┐     ┌─────────────┐         │
    │ State C │◀────│   State B   │◀────────┘
    └─────────┘     └─────────────┘
```

## State Transition Table

| Current State | Event / Condition | Next State | Actions |
|---------------|-------------------|------------|---------|
| <state> | <trigger> | <state> | <actions> |

## Mode Compatibility Matrix

| Mode | State A | State B | State C |
|------|---------|---------|---------|
| Mode 1 | ✓ | ✓ | ✗ |
| Mode 2 | ✓ | ✗ | ✓ |
