#!/usr/bin/env python3
"""Generate D2 diagrams and summary table from GPU pipeline model."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

# Status -> D2 fill color
STATUS_COLORS = {
    "verified": "#c8e6c9",     # green
    "implemented": "#bbdefb",  # blue
    "in_progress": "#fff9c4",  # yellow
    "planned": "#ffccbc",      # orange
}


def load_pipeline(path: Path) -> dict:
    """Load and return the pipeline YAML."""
    with open(path) as f:
        return yaml.safe_load(f)


def gen_dataflow(data: dict, output_dir: Path) -> Path:
    """Generate dataflow.d2 showing units grouped by pipeline with data flow edges."""
    units = data["units"]
    lines: list[str] = []
    lines.append("# GPU Pipeline Data Flow (generated)")
    lines.append("direction: right")
    lines.append("")

    # Group units by pipeline
    pipelines: dict[str, list[tuple[str, dict]]] = {}
    for uid, unit in units.items():
        pipe = unit.get("pipeline", "unknown")
        pipelines.setdefault(pipe, []).append((uid, unit))

    # Define pipeline flow orders
    flow_orders = {
        "geometry": [
            "triangle_setup",
            "block_rasterize",
            "hiz_test",
            "fragment_rasterize",
        ],
        "pixel": [
            "stipple",
            "z_cache",
            "tex_sampler",
            "color_combiner",
            "alpha_test",
            "alpha_blend",
            "dither",
            "pixel_output",
        ],
        "display": ["scanout", "color_grade", "dvi_output"],
    }

    for pipe_name, unit_list in pipelines.items():
        safe_pipe = pipe_name.replace("-", "_")
        lines.append(f"{safe_pipe}: {{")
        lines.append(f'  label: "{pipe_name.title()} Pipeline"')
        lines.append("")

        for uid, unit in unit_list:
            color = STATUS_COLORS.get(unit.get("status", ""), "#e0e0e0")
            dsp = unit.get("dsp", 0)
            ebr = unit.get("ebr", 0)
            status = unit.get("status", "unknown")
            label_parts = [unit["name"]]
            if dsp or ebr:
                res_parts = []
                if dsp:
                    res_parts.append(f"{dsp} DSP")
                if ebr:
                    res_parts.append(f"{ebr} EBR")
                label_parts.append(", ".join(res_parts))
            label_parts.append(f"[{status}]")
            label = "\\n".join(label_parts)
            lines.append(f"  {uid}: {{")
            lines.append(f'    label: "{label}"')
            lines.append(f"    style.fill: \"{color}\"")
            lines.append("  }")
            lines.append("")

        # Add flow edges within this pipeline
        order = flow_orders.get(pipe_name, [])
        existing = [uid for uid in order if uid in dict(unit_list)]
        for i in range(len(existing) - 1):
            lines.append(f"  {existing[i]} -> {existing[i + 1]}")

        lines.append("}")
        lines.append("")

    # Cross-pipeline edge: geometry feeds pixel
    lines.append("geometry.fragment_rasterize -> pixel.stipple: {")
    lines.append('  label: "fragment"')
    lines.append("  style.stroke-dash: 3")
    lines.append("}")

    out = output_dir / "dataflow.d2"
    out.write_text("\n".join(lines) + "\n")
    print(f"  Generated {out}")
    return out


def _cycle_id(c: int) -> str:
    """Return D2-safe participant ID for a cycle number (supports negative)."""
    if c < 0:
        return f"CN{abs(c)}"
    return f"C{c}"


def gen_cyclemaps(data: dict, output_dir: Path) -> list[Path]:
    """Generate one cyclemap D2 sequence diagram per schedule.

    Each clock cycle is a participant (column).  Units appear as labeled
    arrows between cycle.span endpoints, grouped into named pipeline phases.
    """
    schedules = data.get("schedules", {})
    generated: list[Path] = []

    for sid, schedule in schedules.items():
        lines: list[str] = []
        lines.append(f"# Cycle Map: {schedule['name']} (generated)")
        lines.append("")
        lines.append("shape: sequence_diagram")
        lines.append("")

        # Collect all referenced cycle numbers to determine participant range
        all_cycles: set[int] = set()
        for entry in schedule.get("lead_in", []):
            all_cycles.add(entry["from"])
            all_cycles.add(entry["to"])
        for group in schedule.get("groups", []):
            for arrow in group.get("arrows", []):
                all_cycles.add(arrow["from"]["cycle"])
                all_cycles.add(arrow["to"]["cycle"])

        # Declare cycle participants in order
        for c in sorted(all_cycles):
            lines.append(f'{_cycle_id(c)}: "Cycle {c}"')
        lines.append("")

        # Lead-in arrows
        for entry in schedule.get("lead_in", []):
            fc = _cycle_id(entry["from"])
            tc = _cycle_id(entry["to"])
            span = entry.get("span", "")
            label = entry.get("label", "")
            if span:
                lines.append(f'{fc} -> {tc}.{span}: "{label}"')
            else:
                lines.append(f'{fc} -> {tc}: "{label}"')
        if schedule.get("lead_in"):
            lines.append("")

        # Groups with arrows
        for group in schedule.get("groups", []):
            group_name = group["name"]
            lines.append(f'"{group_name}": {{')
            for arrow in group.get("arrows", []):
                f_cycle = _cycle_id(arrow["from"]["cycle"])
                f_span = arrow["from"]["span"]
                t_cycle = _cycle_id(arrow["to"]["cycle"])
                t_span = arrow["to"]["span"]
                label = arrow.get("label", "")
                lines.append(f'  {f_cycle}.{f_span} -> {t_cycle}.{t_span}: "{label}"')
            lines.append("}")
            lines.append("")

        out = output_dir / f"cyclemap_{sid}.d2"
        out.write_text("\n".join(lines) + "\n")
        generated.append(out)
        print(f"  Generated {out}")

    return generated


def print_summary(data: dict) -> None:
    """Print ASCII summary table to stdout."""
    units = data["units"]
    device = data["device"]
    budget = data["budget"]

    total_dsp = sum(u.get("dsp", 0) for u in units.values())
    total_ebr = sum(u.get("ebr", 0) for u in units.values())
    total_lut4 = sum(u.get("lut4", 0) for u in units.values())
    total_serdes = sum(u.get("serdes", 0) for u in units.values())

    print()
    print("Resource Budget")
    w = 55
    print("=" * w)
    print(f"{'':14s} {'Used':>6s} {'Budget':>8s} {'Device':>8s}  Status")
    print("-" * w)
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
        print(f"{label:14s} {used:6d} {bgt_str:>8s} {dev:8d}  {status}")

    print()
    print("Unit Summary")
    print("=" * w)
    print(f"{'Unit':<24s} {'Pipeline':<16s} {'DSP':>4s} {'EBR':>4s}  Status")
    print("-" * w)
    for uid, unit in units.items():
        name = unit["name"]
        if len(name) > 22:
            name = name[:22]
        pipe = unit.get("pipeline", "?")
        dsp = unit.get("dsp", 0)
        ebr = unit.get("ebr", 0)
        status = unit.get("status", "?")
        print(f"{name:<24s} {pipe:<16s} {dsp:4d} {ebr:4d}  {status}")

    print()
    print("Schedules")
    print("=" * w)
    for sid, schedule in data.get("schedules", {}).items():
        cpp = schedule.get("cycles_per_pixel", "?")
        print(f"  {schedule['name']}  ({cpp} cycles/pixel)")
    print()


def render_d2(d2_files: list[Path]) -> bool:
    """Render .d2 files to SVG and PNG using the d2 CLI. Returns True if all succeed."""
    d2_bin = shutil.which("d2")
    if not d2_bin:
        print("  d2 not installed, skipping SVG/PNG rendering")
        return True

    ok = True
    for d2_file in d2_files:
        for fmt in ("svg", "png"):
            out = d2_file.with_suffix(f".{fmt}")
            result = subprocess.run(
                [d2_bin, str(d2_file), str(out)],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                print(f"  ERROR: d2 failed for {out}: {result.stderr.strip()}")
                ok = False
            else:
                print(f"  Rendered {out}")
    return ok


def main() -> int:
    """Generate diagrams, render to SVG/PNG, and print summary."""
    parser = argparse.ArgumentParser(description="Generate pipeline diagrams")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).parent.parent / "build" / "pipeline",
        help="Directory for generated .d2 and rendered files",
    )
    parser.add_argument(
        "--no-render",
        action="store_true",
        help="Skip SVG/PNG rendering (generate .d2 only)",
    )
    args = parser.parse_args()

    pipeline_path = Path(__file__).parent / "pipeline.yaml"
    if not pipeline_path.exists():
        print(f"ERROR: {pipeline_path} not found", file=sys.stderr)
        return 1

    data = load_pipeline(pipeline_path)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    print("Generating pipeline diagrams...")
    d2_files: list[Path] = []
    d2_files.append(gen_dataflow(data, args.output_dir))
    d2_files.extend(gen_cyclemaps(data, args.output_dir))

    if not args.no_render:
        print("Rendering SVG and PNG...")
        if not render_d2(d2_files):
            return 1

    print_summary(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
