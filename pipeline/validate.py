#!/usr/bin/env python3
"""Validate GPU pipeline model against resource budgets and connectivity."""

import sys
from pathlib import Path

import yaml


def load_pipeline(path: Path) -> dict:
    """Load and return the pipeline YAML."""
    with open(path) as f:
        return yaml.safe_load(f)


def validate_budgets(data: dict, errors: list[str], warnings: list[str]) -> None:
    """Check DSP, EBR, and SERDES totals against device limits and project budget."""
    units = data["units"]
    device = data["device"]
    budget = data["budget"]

    total_dsp = sum(u.get("dsp", 0) for u in units.values())
    total_ebr = sum(u.get("ebr", 0) for u in units.values())
    total_lut4 = sum(u.get("lut4", 0) for u in units.values())
    total_serdes = sum(u.get("serdes", 0) for u in units.values())

    # DSP checks
    if total_dsp > device["dsp"]:
        errors.append(f"DSP total {total_dsp} exceeds device limit {device['dsp']}")
    elif total_dsp > budget["dsp"]:
        errors.append(f"DSP total {total_dsp} exceeds project budget {budget['dsp']}")
    elif total_dsp > budget["dsp"] * 0.9:
        warnings.append(
            f"DSP usage {total_dsp}/{budget['dsp']} is above 90% of budget"
        )

    # EBR checks
    if total_ebr > device["ebr"]:
        errors.append(f"EBR total {total_ebr} exceeds device limit {device['ebr']}")
    elif total_ebr > budget["ebr"]:
        errors.append(f"EBR total {total_ebr} exceeds project budget {budget['ebr']}")
    elif total_ebr > budget["ebr"] * 0.9:
        warnings.append(
            f"EBR usage {total_ebr}/{budget['ebr']} is above 90% of budget"
        )

    # LUT4 checks
    if total_lut4 > device["lut4"]:
        errors.append(
            f"LUT4 total {total_lut4} exceeds device limit {device['lut4']}"
        )

    # SERDES checks (ECP5-25K has 4 SERDES channels)
    if total_serdes > 4:
        errors.append(f"SERDES total {total_serdes} exceeds device limit 4")


def validate_sdram_ports(data: dict, errors: list[str]) -> None:
    """Check that all stall references name valid SDRAM ports."""
    num_ports = data["device"]["sdram_ports"]
    valid_ports = {f"sdram_port_{i}" for i in range(num_ports)}

    for uid, unit in data["units"].items():
        for stage in unit.get("stages", []):
            stall = stage.get("stall")
            if stall and stall not in valid_ports:
                errors.append(
                    f"Unit '{uid}' stage '{stage['id']}': "
                    f"invalid SDRAM port '{stall}' (valid: {sorted(valid_ports)})"
                )


def validate_schedule_refs(data: dict, errors: list[str]) -> None:
    """Check that all schedule group arrow unit references name valid units."""
    valid_units = set(data["units"].keys())

    for sid, schedule in data.get("schedules", {}).items():
        for group in schedule.get("groups", []):
            for arrow in group.get("arrows", []):
                unit_name = arrow.get("unit", "")
                if unit_name and unit_name not in valid_units:
                    errors.append(
                        f"Schedule '{sid}' group '{group['name']}': "
                        f"references unknown unit '{unit_name}'"
                    )


def validate_sdram_contention(data: dict, errors: list[str]) -> None:
    """Check no SDRAM port is used by two units in the same schedule cycle."""
    units = data["units"]

    for sid, schedule in data.get("schedules", {}).items():
        # Group arrows by their source cycle to detect contention
        cycle_units: dict[int, list[str]] = {}
        for group in schedule.get("groups", []):
            for arrow in group.get("arrows", []):
                unit_name = arrow.get("unit", "")
                if unit_name:
                    from_cycle = arrow["from"]["cycle"]
                    cycle_units.setdefault(from_cycle, []).append(unit_name)

        for cycle, unit_names in cycle_units.items():
            ports_used: dict[str, list[str]] = {}
            for unit_name in set(unit_names):
                unit = units.get(unit_name, {})
                for stage in unit.get("stages", []):
                    stall = stage.get("stall")
                    if stall:
                        ports_used.setdefault(stall, []).append(unit_name)

            for port, users in ports_used.items():
                if len(users) > 1:
                    errors.append(
                        f"Schedule '{sid}' cycle {cycle}: "
                        f"SDRAM port '{port}' contention between "
                        f"{', '.join(users)}"
                    )


def main() -> int:
    """Run all validation checks and report results."""
    pipeline_path = Path(__file__).parent / "pipeline.yaml"
    if not pipeline_path.exists():
        print(f"ERROR: {pipeline_path} not found", file=sys.stderr)
        return 1

    data = load_pipeline(pipeline_path)
    errors: list[str] = []
    warnings: list[str] = []

    validate_budgets(data, errors, warnings)
    validate_sdram_ports(data, errors)
    validate_schedule_refs(data, errors)
    validate_sdram_contention(data, errors)

    # Print summary
    units = data["units"]
    device = data["device"]
    budget = data["budget"]

    total_dsp = sum(u.get("dsp", 0) for u in units.values())
    total_ebr = sum(u.get("ebr", 0) for u in units.values())
    total_lut4 = sum(u.get("lut4", 0) for u in units.values())
    total_serdes = sum(u.get("serdes", 0) for u in units.values())

    print("Pipeline Validation")
    print("=" * 50)
    print()
    print("Resource Budget")
    print("-" * 50)
    print(f"{'':12s} {'Used':>6s} {'Budget':>8s} {'Device':>8s}  Status")
    for label, used, bgt, dev in [
        ("DSP", total_dsp, budget["dsp"], device["dsp"]),
        ("EBR", total_ebr, budget["ebr"], device["ebr"]),
        ("LUT4", total_lut4, None, device["lut4"]),
        ("SERDES", total_serdes, None, 4),
    ]:
        bgt_str = str(bgt) if bgt is not None else "-"
        if dev and used > dev:
            status = "OVER DEVICE"
        elif bgt and used > bgt:
            status = "OVER BUDGET"
        else:
            status = "OK"
        print(f"{label:12s} {used:6d} {bgt_str:>8s} {dev:8d}  {status}")

    print()

    if warnings:
        print("Warnings:")
        for w in warnings:
            print(f"  WARNING: {w}")
        print()

    if errors:
        print("Errors:")
        for e in errors:
            print(f"  ERROR: {e}")
        print()
        print("VALIDATION FAILED")
        return 1

    print("VALIDATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
