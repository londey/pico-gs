# INT-000: Template

This is a template file. Create new interfaces using:

```bash
.syskit/scripts/new-int.sh <interface_name>
```

Or copy this template and modify.

---

## Type

Choose one:
- **Internal:** Defined by this project
- **External Standard:** Defined by an external specification (e.g., PNG, SPI, USB)
- **External Service:** Defined by an external service (e.g., REST API)

## External Specification

<!-- Include this section only for external interfaces -->

- **Standard:** <name and version, e.g., "SPI Mode 0", "PNG 1.2">
- **Reference:** <URL or document reference>

## Specification

<!-- For internal interfaces: This section IS the specification -->
<!-- For external interfaces: Document your usage subset and constraints -->

### Overview

<Brief description of what this interface is for>

### Details

<Detailed specification>

For hardware interfaces, consider:
- Signal definitions
- Timing requirements
- Electrical characteristics

For data formats, consider:
- Field definitions
- Encoding
- Constraints and valid ranges

For APIs, consider:
- Endpoints / functions
- Parameters
- Return values
- Error conditions

## Constraints

<Any constraints or limitations>

## Notes

<Additional context, rationale for choices, compatibility considerations>
