# INT-000: Template

This is a template file. Create new interfaces using:

```bash
.syskit/scripts/new-int.sh <interface_name>
```

Or copy this template and modify.

---

## Type

Internal | External Standard | External Service

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

<Detailed specification. See `doc/interfaces/README.md` for a completeness checklist by interface type.>

## Constraints

<Any constraints or limitations>

## Notes

<Optional. External consumers not covered by a UNIT (e.g., host-side drivers) may be listed here. Provider/consumer UNITs are declared by the UNIT docs themselves — do not mirror that list here. Reverse lists of REQs or UNITs that reference this interface are maintained by those documents, not here.>
