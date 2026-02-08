#!/usr/bin/env python3
"""
Establish traceability between REQ, INT, and UNIT documents.

Populates TBD fields in documents with cross-references based on heuristics
and mapping rules.
"""

import re
from pathlib import Path
from typing import Dict, List, Set

# Project root
ROOT_DIR = Path(__file__).parent.parent.parent
DOC_DIR = ROOT_DIR / "doc"
REQ_DIR = DOC_DIR / "requirements"
INT_DIR = DOC_DIR / "interfaces"
UNIT_DIR = DOC_DIR / "design"


# ============================================================================
# Traceability Rules (Heuristics)
# ============================================================================

# Requirements that depend on specific interfaces
REQ_TO_INTS = {
    # SPI-related requirements
    "REQ-001": ["INT-001", "INT-010", "INT-012"],  # Basic Host Communication
    "REQ-020": ["INT-001", "INT-012"],  # SPI Electrical Interface

    # Framebuffer requirements
    "REQ-002": ["INT-011", "INT-010"],  # Framebuffer Management
    "REQ-025": ["INT-011"],  # Framebuffer Format

    # GPU rendering requirements
    "REQ-003": ["INT-010"],  # Flat Shaded Triangle
    "REQ-004": ["INT-010"],  # Gouraud Shaded Triangle
    "REQ-005": ["INT-010", "INT-011"],  # Depth Tested Triangle
    "REQ-006": ["INT-010", "INT-011"],  # Textured Triangle
    "REQ-007": ["INT-002"],  # Display Output

    # v2.0 GPU features
    "REQ-008": ["INT-010"],  # Multi-Texture Rendering
    "REQ-009": ["INT-010"],  # Texture Blend Modes
    "REQ-010": ["INT-010"],  # Compressed Textures
    "REQ-011": ["INT-010"],  # Swizzle Patterns
    "REQ-012": ["INT-010"],  # UV Wrapping Modes
    "REQ-013": ["INT-010"],  # Alpha Blending
    "REQ-014": ["INT-010", "INT-011"],  # Enhanced Z-Buffer
    "REQ-015": ["INT-010"],  # Memory Upload Interface
    "REQ-016": ["INT-010"],  # Triangle-Based Clearing

    # Host software requirements
    "REQ-100": ["INT-020"],  # Flat-Shaded Triangle Demo
    "REQ-101": ["INT-020", "INT-021"],  # Textured Triangle Demo
    "REQ-102": ["INT-020", "INT-021"],  # Spinning Utah Teapot Demo
    "REQ-103": ["INT-005", "INT-021"],  # USB Keyboard Demo Switching
    "REQ-104": ["INT-021"],  # Dual-Core Render Pipeline
    "REQ-105": ["INT-020"],  # Asynchronous GPU Communication

    # Host driver requirements
    "REQ-110": ["INT-010", "INT-020"],  # GPU Initialization
    "REQ-111": ["INT-021"],  # Dual-Core Architecture
    "REQ-114": ["INT-021"],  # Render Command Queue
    "REQ-115": ["INT-020", "INT-021"],  # Render Mesh Patch
    "REQ-116": ["INT-020"],  # Upload Texture
    "REQ-117": ["INT-020", "INT-013"],  # VSync Synchronization
    "REQ-118": ["INT-020", "INT-010"],  # Clear Framebuffer
    "REQ-119": ["INT-020", "INT-013"],  # GPU Flow Control

    # Asset pipeline requirements
    "REQ-200": ["INT-003", "INT-030", "INT-031"],  # PNG to GPU Texture Format
    "REQ-201": ["INT-004", "INT-030", "INT-031"],  # OBJ to Mesh Patches
    "REQ-202": ["INT-030"],  # Seamless Build.rs Integration
}

# Requirements implemented by specific units
REQ_TO_UNITS = {
    # GPU hardware implementation
    "REQ-001": ["UNIT-001", "UNIT-002", "UNIT-003"],  # Basic SPI communication
    "REQ-002": ["UNIT-007", "UNIT-008"],  # Framebuffer management
    "REQ-003": ["UNIT-004", "UNIT-005", "UNIT-006", "UNIT-007"],  # Flat triangle
    "REQ-004": ["UNIT-004", "UNIT-005", "UNIT-006"],  # Gouraud triangle
    "REQ-005": ["UNIT-005", "UNIT-006", "UNIT-007"],  # Depth tested triangle
    "REQ-006": ["UNIT-005", "UNIT-006"],  # Textured triangle
    "REQ-007": ["UNIT-008", "UNIT-009"],  # Display output
    "REQ-008": ["UNIT-006"],  # Multi-texture
    "REQ-009": ["UNIT-006"],  # Texture blend modes
    "REQ-010": ["UNIT-006"],  # Compressed textures
    "REQ-011": ["UNIT-006"],  # Swizzle patterns
    "REQ-012": ["UNIT-006"],  # UV wrapping
    "REQ-013": ["UNIT-006"],  # Alpha blending
    "REQ-014": ["UNIT-006", "UNIT-007"],  # Enhanced Z-buffer
    "REQ-015": ["UNIT-003", "UNIT-007"],  # Memory upload
    "REQ-016": ["UNIT-006"],  # Triangle clearing
    "REQ-020": ["UNIT-001"],  # SPI electrical interface
    "REQ-021": ["UNIT-002"],  # Command FIFO
    "REQ-022": ["UNIT-003"],  # Vertex submission
    "REQ-023": ["UNIT-004", "UNIT-005"],  # Rasterization
    "REQ-024": ["UNIT-006"],  # Texture sampling
    "REQ-025": ["UNIT-007", "UNIT-008"],  # Framebuffer format
    "REQ-026": ["UNIT-008", "UNIT-009"],  # Display timing
    "REQ-027": ["UNIT-006", "UNIT-007"],  # Z-buffer operations
    "REQ-028": ["UNIT-006"],  # Alpha blending
    "REQ-029": ["UNIT-003", "UNIT-007"],  # Memory upload

    # Host software implementation
    "REQ-100": ["UNIT-020", "UNIT-021", "UNIT-022"],  # Flat demo
    "REQ-101": ["UNIT-020", "UNIT-021", "UNIT-022"],  # Textured demo
    "REQ-102": ["UNIT-020", "UNIT-021", "UNIT-022", "UNIT-023", "UNIT-024"],  # Teapot demo
    "REQ-103": ["UNIT-025", "UNIT-027"],  # USB keyboard
    "REQ-104": ["UNIT-020", "UNIT-021", "UNIT-026"],  # Dual-core
    "REQ-105": ["UNIT-022"],  # Async GPU
    "REQ-110": ["UNIT-022"],  # GPU init
    "REQ-111": ["UNIT-020", "UNIT-021"],  # Dual-core arch
    "REQ-112": ["UNIT-020"],  # Scene graph
    "REQ-113": ["UNIT-025"],  # USB keyboard
    "REQ-114": ["UNIT-026"],  # Render queue
    "REQ-115": ["UNIT-021", "UNIT-022", "UNIT-023", "UNIT-024"],  # Render mesh
    "REQ-116": ["UNIT-021", "UNIT-022"],  # Upload texture
    "REQ-117": ["UNIT-021", "UNIT-022"],  # VSync
    "REQ-118": ["UNIT-021", "UNIT-022"],  # Clear framebuffer
    "REQ-119": ["UNIT-022"],  # GPU flow control
    "REQ-120": ["UNIT-020"],  # Async data loading
    "REQ-121": ["UNIT-022"],  # Async SPI
    "REQ-122": ["UNIT-027"],  # Default demo
    "REQ-123": ["UNIT-021", "UNIT-022"],  # Double buffering

    # Asset pipeline implementation
    "REQ-200": ["UNIT-030", "UNIT-033"],  # PNG conversion
    "REQ-201": ["UNIT-031", "UNIT-032", "UNIT-033"],  # OBJ conversion
    "REQ-202": ["UNIT-034"],  # Build.rs integration
}

# Interfaces provided/consumed by units
UNIT_TO_INTS = {
    # GPU hardware units
    "UNIT-001": {"provides": [], "consumes": ["INT-001", "INT-010", "INT-012"]},  # SPI slave
    "UNIT-002": {"provides": [], "consumes": []},  # Command FIFO
    "UNIT-003": {"provides": ["INT-010"], "consumes": []},  # Register file (provides register map)
    "UNIT-004": {"provides": [], "consumes": ["INT-010"]},  # Triangle setup
    "UNIT-005": {"provides": [], "consumes": ["INT-010"]},  # Rasterizer
    "UNIT-006": {"provides": [], "consumes": ["INT-010", "INT-011"]},  # Pixel pipeline
    "UNIT-007": {"provides": [], "consumes": ["INT-011"]},  # SRAM arbiter
    "UNIT-008": {"provides": [], "consumes": ["INT-011"]},  # Display controller
    "UNIT-009": {"provides": ["INT-002"], "consumes": []},  # TMDS encoder (provides DVI)

    # Host software units
    "UNIT-020": {"provides": [], "consumes": ["INT-021"]},  # Core 0 scene manager
    "UNIT-021": {"provides": [], "consumes": ["INT-020", "INT-021"]},  # Core 1 render executor
    "UNIT-022": {"provides": ["INT-020"], "consumes": ["INT-001", "INT-010", "INT-012", "INT-013"]},  # GPU driver (provides driver API)
    "UNIT-023": {"provides": [], "consumes": []},  # Transform pipeline
    "UNIT-024": {"provides": [], "consumes": []},  # Lighting calculator
    "UNIT-025": {"provides": [], "consumes": ["INT-005"]},  # USB keyboard
    "UNIT-026": {"provides": ["INT-021"], "consumes": []},  # Inter-core queue (provides command format)
    "UNIT-027": {"provides": [], "consumes": ["INT-021"]},  # Demo state machine

    # Asset pipeline units
    "UNIT-030": {"provides": [], "consumes": ["INT-003"]},  # PNG decoder
    "UNIT-031": {"provides": [], "consumes": ["INT-004"]},  # OBJ parser
    "UNIT-032": {"provides": [], "consumes": []},  # Mesh patcher
    "UNIT-033": {"provides": [], "consumes": []},  # Codegen
    "UNIT-034": {"provides": ["INT-030"], "consumes": ["INT-031"]},  # Build.rs orchestrator
}


# ============================================================================
# Helper Functions
# ============================================================================

def find_all_docs(doc_dir: Path, prefix: str) -> List[Path]:
    """Find all documents with given prefix."""
    return sorted(doc_dir.glob(f"{prefix}_*.md"))


def extract_doc_id(doc_path: Path) -> str:
    """Extract document ID (e.g., REQ-001, INT-010, UNIT-005)."""
    name = doc_path.stem
    # Extract number after prefix
    match = re.match(r'(req|int|unit)_(\d+)', name)
    if match:
        prefix_map = {"req": "REQ", "int": "INT", "unit": "UNIT"}
        return f"{prefix_map[match.group(1)]}-{match.group(2)}"
    return None


def extract_title_from_content(content: str) -> str:
    """Extract title from markdown content (first # heading)."""
    match = re.search(r'^#\s+[A-Z]+-\d+:\s+(.+)$', content, re.MULTILINE)
    if match:
        return match.group(1).strip()
    return "Unknown"


def replace_tbd_section(content: str, section_name: str, new_content: str) -> str:
    """Replace TBD content in a section."""
    # Match section until next ## or end of file
    pattern = rf'(##\s+{re.escape(section_name)}\s*\n\n)(TBD[^\n]*)'
    replacement = rf'\1{new_content}'
    return re.sub(pattern, replacement, content, count=1)


def replace_allocated_to(content: str, units: List[str], unit_titles: Dict[str, str]) -> str:
    """Replace Allocated To section."""
    if not units:
        return content
    lines = "\n".join([f"- {u} ({unit_titles.get(u, 'Unknown')})" for u in units])
    return replace_tbd_section(content, "Allocated To", lines)


def replace_interfaces(content: str, interfaces: List[str], int_titles: Dict[str, str]) -> str:
    """Replace Interfaces section."""
    if not interfaces:
        return content
    lines = "\n".join([f"- {i} ({int_titles.get(i, 'Unknown')})" for i in interfaces])
    return replace_tbd_section(content, "Interfaces", lines)


def replace_referenced_by(content: str, refs: List[str], req_titles: Dict[str, str]) -> str:
    """Replace Referenced By section."""
    if not refs:
        return content
    lines = "\n".join([f"- {r} ({req_titles.get(r, 'Unknown')})" for r in sorted(refs)])
    return replace_tbd_section(content, "Referenced By", lines)


def replace_parties(content: str, providers: List[str], consumers: List[str], unit_titles: Dict[str, str]) -> str:
    """Replace Parties section."""
    lines = []
    if providers:
        for p in providers:
            title = unit_titles.get(p, 'Unknown') if p != "External" else ""
            lines.append(f"- **Provider:** {p}" + (f" ({title})" if title else ""))
    else:
        lines.append("- **Provider:** External")

    if consumers:
        for c in consumers:
            lines.append(f"- **Consumer:** {c} ({unit_titles.get(c, 'Unknown')})")

    new_content = "\n".join(lines)
    return replace_tbd_section(content, "Parties", new_content)


def replace_implements_requirements(content: str, reqs: List[str], req_titles: Dict[str, str]) -> str:
    """Replace Implements Requirements section."""
    if not reqs:
        return content
    lines = "\n".join([f"- {r} ({req_titles.get(r, 'Unknown')})" for r in sorted(reqs)])
    return replace_tbd_section(content, "Implements Requirements", lines)


def replace_unit_interfaces(content: str, provides: List[str], consumes: List[str], int_titles: Dict[str, str]) -> str:
    """Replace Provides/Consumes in Interfaces section."""

    # Replace Provides
    if provides:
        provides_lines = "\n".join([f"- {i} ({int_titles.get(i, 'Unknown')})" for i in provides])
    else:
        provides_lines = "None"
    pattern_provides = r'(###\s+Provides\s*\n\n)TBD[^\n]*'
    content = re.sub(pattern_provides, rf'\1{provides_lines}', content, count=1)

    # Replace Consumes
    if consumes:
        consumes_lines = "\n".join([f"- {i} ({int_titles.get(i, 'Unknown')})" for i in consumes])
    else:
        consumes_lines = "None"
    pattern_consumes = r'(###\s+Consumes\s*\n\n)TBD[^\n]*'
    content = re.sub(pattern_consumes, rf'\1{consumes_lines}', content, count=1)

    return content


# ============================================================================
# Main Traceability Functions
# ============================================================================

def establish_req_to_int(req_docs: List[Path], int_titles: Dict[str, str]):
    """Populate Interfaces section in REQ documents."""
    print("Establishing REQ → INT links...")

    for req_doc in req_docs:
        req_id = extract_doc_id(req_doc)
        if not req_id or req_id not in REQ_TO_INTS:
            continue

        interfaces = REQ_TO_INTS[req_id]
        content = req_doc.read_text()
        updated = replace_interfaces(content, interfaces, int_titles)
        req_doc.write_text(updated)
        print(f"  {req_id}: {len(interfaces)} interfaces")


def establish_req_to_unit(req_docs: List[Path], unit_titles: Dict[str, str]):
    """Populate Allocated To section in REQ documents."""
    print("Establishing REQ → UNIT links...")

    for req_doc in req_docs:
        req_id = extract_doc_id(req_doc)
        if not req_id or req_id not in REQ_TO_UNITS:
            continue

        units = REQ_TO_UNITS[req_id]
        content = req_doc.read_text()
        updated = replace_allocated_to(content, units, unit_titles)
        req_doc.write_text(updated)
        print(f"  {req_id}: {len(units)} units")


def establish_int_to_req(int_docs: List[Path], req_docs: List[Path], req_titles: Dict[str, str]):
    """Populate Referenced By section in INT documents."""
    print("Establishing INT → REQ links...")

    # Build reverse mapping: INT -> [REQs]
    int_to_reqs: Dict[str, Set[str]] = {}
    for req_id, ints in REQ_TO_INTS.items():
        for int_id in ints:
            if int_id not in int_to_reqs:
                int_to_reqs[int_id] = set()
            int_to_reqs[int_id].add(req_id)

    for int_doc in int_docs:
        int_id = extract_doc_id(int_doc)
        if not int_id or int_id not in int_to_reqs:
            continue

        reqs = list(int_to_reqs[int_id])
        content = int_doc.read_text()
        updated = replace_referenced_by(content, reqs, req_titles)
        int_doc.write_text(updated)
        print(f"  {int_id}: {len(reqs)} requirements")


def establish_int_to_unit(int_docs: List[Path], unit_titles: Dict[str, str]):
    """Populate Parties section in INT documents."""
    print("Establishing INT → UNIT links...")

    # Build reverse mapping: INT -> {providers: [], consumers: []}
    int_to_units: Dict[str, Dict[str, List[str]]] = {}
    for unit_id, ints in UNIT_TO_INTS.items():
        for int_id in ints["provides"]:
            if int_id not in int_to_units:
                int_to_units[int_id] = {"providers": [], "consumers": []}
            int_to_units[int_id]["providers"].append(unit_id)
        for int_id in ints["consumes"]:
            if int_id not in int_to_units:
                int_to_units[int_id] = {"providers": [], "consumers": []}
            int_to_units[int_id]["consumers"].append(unit_id)

    for int_doc in int_docs:
        int_id = extract_doc_id(int_doc)
        if not int_id or int_id not in int_to_units:
            continue

        providers = int_to_units[int_id]["providers"]
        consumers = int_to_units[int_id]["consumers"]
        content = int_doc.read_text()
        updated = replace_parties(content, providers, consumers, unit_titles)
        int_doc.write_text(updated)
        print(f"  {int_id}: {len(providers)} providers, {len(consumers)} consumers")


def establish_unit_to_req(unit_docs: List[Path], req_titles: Dict[str, str]):
    """Populate Implements Requirements section in UNIT documents."""
    print("Establishing UNIT → REQ links...")

    # Build reverse mapping: UNIT -> [REQs]
    unit_to_reqs: Dict[str, Set[str]] = {}
    for req_id, units in REQ_TO_UNITS.items():
        for unit_id in units:
            if unit_id not in unit_to_reqs:
                unit_to_reqs[unit_id] = set()
            unit_to_reqs[unit_id].add(req_id)

    for unit_doc in unit_docs:
        unit_id = extract_doc_id(unit_doc)
        if not unit_id or unit_id not in unit_to_reqs:
            continue

        reqs = list(unit_to_reqs[unit_id])
        content = unit_doc.read_text()
        updated = replace_implements_requirements(content, reqs, req_titles)
        unit_doc.write_text(updated)
        print(f"  {unit_id}: {len(reqs)} requirements")


def establish_unit_to_int(unit_docs: List[Path], int_titles: Dict[str, str]):
    """Populate Provides/Consumes sections in UNIT documents."""
    print("Establishing UNIT → INT links...")

    for unit_doc in unit_docs:
        unit_id = extract_doc_id(unit_doc)
        if not unit_id or unit_id not in UNIT_TO_INTS:
            continue

        provides = UNIT_TO_INTS[unit_id]["provides"]
        consumes = UNIT_TO_INTS[unit_id]["consumes"]
        content = unit_doc.read_text()
        updated = replace_unit_interfaces(content, provides, consumes, int_titles)
        unit_doc.write_text(updated)
        print(f"  {unit_id}: {len(provides)} provides, {len(consumes)} consumes")


# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    print("=" * 70)
    print("ESTABLISHING TRACEABILITY")
    print("=" * 70)

    # Find all documents
    req_docs = find_all_docs(REQ_DIR, "req")
    int_docs = find_all_docs(INT_DIR, "int")
    unit_docs = find_all_docs(UNIT_DIR, "unit")

    print(f"\nFound {len(req_docs)} REQ, {len(int_docs)} INT, {len(unit_docs)} UNIT documents")

    # Build title mappings
    req_titles = {}
    for doc in req_docs:
        req_id = extract_doc_id(doc)
        if req_id:
            content = doc.read_text()
            req_titles[req_id] = extract_title_from_content(content)

    int_titles = {}
    for doc in int_docs:
        int_id = extract_doc_id(doc)
        if int_id:
            content = doc.read_text()
            int_titles[int_id] = extract_title_from_content(content)

    unit_titles = {}
    for doc in unit_docs:
        unit_id = extract_doc_id(doc)
        if unit_id:
            content = doc.read_text()
            unit_titles[unit_id] = extract_title_from_content(content)

    # Establish all relationships
    print()
    establish_req_to_int(req_docs, int_titles)
    print()
    establish_req_to_unit(req_docs, unit_titles)
    print()
    establish_int_to_req(int_docs, req_docs, req_titles)
    print()
    establish_int_to_unit(int_docs, unit_titles)
    print()
    establish_unit_to_req(unit_docs, req_titles)
    print()
    establish_unit_to_int(unit_docs, int_titles)

    print("\n" + "=" * 70)
    print("TRACEABILITY ESTABLISHED")
    print("=" * 70)
    print(f"\nNext step:")
    print(f"  Run: python .syskit/scripts/validate-migration.py")


if __name__ == "__main__":
    main()
