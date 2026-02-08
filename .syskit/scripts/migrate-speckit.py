#!/usr/bin/env python3
"""
Migrate speckit specifications to syskit structure.

Extracts user stories, functional requirements, contracts, and modules from
speckit files and generates syskit REQ/INT/UNIT documents.
"""

import os
import re
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# Project root
ROOT_DIR = Path(__file__).parent.parent.parent

# Source and target directories
SPECS_DIR = ROOT_DIR / "specs"
DOC_DIR = ROOT_DIR / "doc"
REQ_DIR = DOC_DIR / "requirements"
INT_DIR = DOC_DIR / "interfaces"
UNIT_DIR = DOC_DIR / "design"

# Templates
REQ_TEMPLATE = REQ_DIR / "req_000_template.md"
INT_TEMPLATE = INT_DIR / "int_000_template.md"
UNIT_TEMPLATE = UNIT_DIR / "unit_000_template.md"


# ============================================================================
# Mapping Tables
# ============================================================================

US_TO_REQ = {
    "001-spi-gpu": {
        "US-1": ("001", "Basic Host Communication"),
        "US-2": ("002", "Framebuffer Management"),
        "US-3": ("003", "Flat Shaded Triangle"),
        "US-4": ("004", "Gouraud Shaded Triangle"),
        "US-5": ("005", "Depth Tested Triangle"),
        "US-6": ("006", "Textured Triangle"),
        "US-7": ("007", "Display Output"),
        "US-8": ("008", "Multi-Texture Rendering"),
        "US-9": ("009", "Texture Blend Modes"),
        "US-10": ("010", "Compressed Textures"),
        "US-11": ("011", "Swizzle Patterns"),
        "US-12": ("012", "UV Wrapping Modes"),
        "US-13": ("013", "Alpha Blending"),
        "US-14": ("014", "Enhanced Z-Buffer"),
        "US-15": ("015", "Memory Upload Interface"),
        "US-16": ("016", "Triangle-Based Clearing"),
    },
    "002-rp2350-host-software": {
        "US-1": ("100", "Flat-Shaded Triangle Demo"),
        "US-2": ("101", "Textured Triangle Demo"),
        "US-3": ("102", "Spinning Utah Teapot Demo"),
        "US-4": ("103", "USB Keyboard Demo Switching"),
        "US-5": ("104", "Dual-Core Render Pipeline"),
        "US-6": ("105", "Asynchronous GPU Communication"),
    },
    "003-asset-data-prep": {
        "US-1": ("200", "PNG to GPU Texture Format"),
        "US-2": ("201", "OBJ to Mesh Patches"),
        "US-3": ("202", "Seamless Build.rs Integration"),
    }
}

FR_TO_REQ = {
    "001-spi-gpu": {
        "FR-1": ("020", "SPI Electrical Interface"),
        "FR-2": ("021", "Command Buffer FIFO"),
        "FR-3": ("022", "Vertex Submission Protocol"),
        "FR-4": ("023", "Rasterization Algorithm"),
        "FR-5": ("024", "Texture Sampling"),
        "FR-6": ("025", "Framebuffer Format"),
        "FR-7": ("026", "Display Output Timing"),
        "FR-8": ("024", "Texture Sampling"),  # v2.0 multi-texture maps to FR-5
        "FR-13": ("027", "Z-Buffer Operations"),
        "FR-14": ("028", "Alpha Blending"),
        "FR-15": ("029", "Memory Upload Interface"),
    },
    "002-rp2350-host-software": {
        "FR-001": ("110", "GPU Initialization"),
        "FR-002": ("111", "Dual-Core Architecture"),
        "FR-003": ("112", "Scene Graph Management"),
        "FR-004": ("113", "USB Keyboard Input"),
        "FR-005": ("114", "Render Command Queue"),
        "FR-006": ("114", "Render Command Queue"),  # Same as FR-005
        "FR-007": ("115", "Render Mesh Patch"),
        "FR-008": ("115", "Render Mesh Patch"),  # Same as FR-007
        "FR-009": ("116", "Upload Texture"),
        "FR-010": ("117", "VSync Synchronization"),
        "FR-011": ("118", "Clear Framebuffer"),
        "FR-012": ("119", "GPU Flow Control"),
        "FR-013": ("120", "Async Data Loading"),
        "FR-014": ("121", "Async SPI Transmission"),
        "FR-015": ("122", "Default Demo Startup"),
        "FR-016": ("123", "Double-Buffered Rendering"),
    }
}

NFR_TO_REQ = [
    ("050", "Performance Targets"),
    ("051", "Resource Constraints"),
    ("052", "Reliability Requirements"),
]

CONTRACT_TO_INT = {
    "001-spi-gpu/contracts/register-map.md": ("010", "GPU Register Map", "Internal"),
    "001-spi-gpu/contracts/memory-map.md": ("011", "SRAM Memory Layout", "Internal"),
    "001-spi-gpu/contracts/spi-protocol.md": ("012", "SPI Transaction Format", "Internal"),
    "002-rp2350-host-software/contracts/gpu-driver.md": ("020", "GPU Driver API", "Internal"),
    "002-rp2350-host-software/contracts/render-commands.md": ("021", "Render Command Format", "Internal"),
    "003-asset-data-prep/contracts/cli-interface.md": ("030", "Asset Tool CLI Interface", "Internal"),
    "003-asset-data-prep/contracts/output-format.md": ("031", "Asset Binary Format", "Internal"),
}

EXTERNAL_INTERFACES = [
    ("001", "SPI Mode 0 Protocol", "SPI specification for Mode 0 electrical characteristics (CPOL=0, CPHA=0)."),
    ("002", "DVI TMDS Output", "DVI 1.0 specification for TMDS encoding at 640×480@60Hz."),
    ("003", "PNG Image Format", "PNG 1.2 specification for image decoding."),
    ("004", "Wavefront OBJ Format", "OBJ file format specification for mesh parsing."),
    ("005", "USB HID Keyboard", "USB HID specification for keyboard input."),
    ("013", "GPIO Status Signals", "GPIO signals for flow control (CMD_FULL, CMD_EMPTY, VSYNC)."),
]

MODULE_TO_UNIT = {
    "spi_gpu": [
        ("001", "SPI Slave Controller", "spi_gpu/src/spi/spi_slave.sv", "Receives 72-bit SPI transactions and writes to register file"),
        ("002", "Command FIFO", "spi_gpu/src/spi/command_fifo.sv", "Buffers GPU commands with flow control"),
        ("003", "Register File", "spi_gpu/src/spi/register_file.sv", "Stores GPU state and vertex data"),
        ("004", "Triangle Setup", "spi_gpu/src/render/triangle_setup.sv", "Prepares triangle for rasterization"),
        ("005", "Rasterizer", "spi_gpu/src/render/rasterizer.sv", "Edge-walking rasterization engine"),
        ("006", "Pixel Pipeline", "spi_gpu/src/render/pixel_pipeline.sv", "Texture sampling, blending, z-test, framebuffer write"),
        ("007", "SRAM Arbiter", "spi_gpu/src/memory/sram_arbiter.sv", "Arbitrates SRAM access between display and render"),
        ("008", "Display Controller", "spi_gpu/src/display/display_controller.sv", "Scanline FIFO and display pipeline"),
        ("009", "DVI TMDS Encoder", "spi_gpu/src/display/tmds_encoder.sv", "TMDS encoding and differential output"),
    ],
    "host_app": [
        ("020", "Core 0 Scene Manager", "host_app/src/scene/mod.rs", "Scene graph management and animation"),
        ("021", "Core 1 Render Executor", "host_app/src/main.rs:core1_main", "Render command queue consumer"),
        ("022", "GPU Driver Layer", "host_app/src/gpu/mod.rs", "SPI transaction handling and flow control"),
        ("023", "Transformation Pipeline", "host_app/src/render/transform.rs", "MVP matrix transforms"),
        ("024", "Lighting Calculator", "host_app/src/render/lighting.rs", "Gouraud shading calculations"),
        ("025", "USB Keyboard Handler", "host_app/src/usb/mod.rs", "USB HID keyboard input processing"),
        ("026", "Inter-Core Queue", "host_app/src/render/mod.rs:RenderQueue", "SPSC queue for Core 0→Core 1 commands"),
        ("027", "Demo State Machine", "host_app/src/demos/mod.rs", "Demo selection and switching logic"),
    ],
    "asset_build_tool": [
        ("030", "PNG Decoder", "asset_build_tool/src/png_converter.rs", "PNG file loading and RGBA conversion"),
        ("031", "OBJ Parser", "asset_build_tool/src/obj_converter.rs", "OBJ file parsing and geometry extraction"),
        ("032", "Mesh Patch Splitter", "asset_build_tool/src/mesh_patcher.rs", "Mesh splitting with vertex/index limits"),
        ("033", "Codegen Engine", "asset_build_tool/src/output_gen.rs", "Rust source and binary data generation"),
        ("034", "Build.rs Orchestrator", "asset_build_tool/src/lib.rs:build_assets", "Asset pipeline entry point"),
    ],
}


# ============================================================================
# Helper Functions
# ============================================================================

def ensure_dirs():
    """Ensure output directories exist."""
    REQ_DIR.mkdir(parents=True, exist_ok=True)
    INT_DIR.mkdir(parents=True, exist_ok=True)
    UNIT_DIR.mkdir(parents=True, exist_ok=True)


def snake_case(s: str) -> str:
    """Convert string to snake_case for filenames."""
    s = re.sub(r'[^a-zA-Z0-9\s]', '', s)
    s = re.sub(r'\s+', '_', s)
    return s.lower()


def extract_section(content: str, heading: str) -> Optional[str]:
    """Extract content under a markdown heading."""
    pattern = rf'^#{1,6}\s+{re.escape(heading)}.*?$\n(.*?)(?=^#{1,6}\s+|\Z)'
    match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
    if match:
        return match.group(1).strip()
    return None


def extract_user_stories(spec_file: Path, feature_key: str) -> List[Tuple[str, str, str, str, str]]:
    """Extract user stories from spec.md file.

    Returns: List of (req_num, title, description, priority, acceptance) tuples
    """
    content = spec_file.read_text()
    stories = []

    # Find each US-X: pattern across entire document (not just in one section)
    us_pattern = r'###\s+(US-\d+):\s*(.+?)\n\n(.+?)(?=###\s+(?:US-\d+|FR-)|##\s+|$)'
    matches = re.finditer(us_pattern, content, re.DOTALL)

    for match in matches:
        us_id = match.group(1)
        title = match.group(2).strip()
        body = match.group(3).strip()

        # Extract priority
        priority_match = re.search(r'\*\*Priority:\*\*\s*(P[123]|Essential|Important|Nice-to-have)', body)
        priority = priority_match.group(1) if priority_match else "P2"

        # Convert P1/P2/P3 to Essential/Important/Nice-to-have
        priority_map = {"P1": "Essential", "P2": "Important", "P3": "Nice-to-have"}
        priority = priority_map.get(priority, priority)

        # Extract user story statement (As a... I want... So that...)
        # Handle format: **As a** role  **I want to** action  **So that** benefit
        as_a_match = re.search(r'\*\*As a\*\*\s+(.+?)(?=\*\*I want|$)', body, re.DOTALL | re.IGNORECASE)
        want_match = re.search(r'\*\*I want( to)?\*\*\s+(.+?)(?=\*\*So that|$)', body, re.DOTALL | re.IGNORECASE)
        so_that_match = re.search(r'\*\*So that\*\*\s+(.+?)(?=\*\*|$)', body, re.DOTALL | re.IGNORECASE)

        if as_a_match and want_match:
            as_a = as_a_match.group(1).strip().replace('\n', ' ')
            want = want_match.group(2).strip().replace('\n', ' ')
            so_that = so_that_match.group(1).strip().replace('\n', ' ') if so_that_match else ""

            if so_that:
                description = f"As a {as_a}, I want to {want}, so that {so_that}"
            else:
                description = f"As a {as_a}, I want to {want}"
        else:
            # Fallback: try simple format
            story_match = re.search(r'(As a.*?(?:so that|\.))' , body, re.DOTALL | re.IGNORECASE)
            description = story_match.group(1).strip() if story_match else title

        # Extract acceptance criteria
        acceptance_match = re.search(r'\*\*Acceptance Criteria:\*\*(.*?)(?=\*\*|###|$)', body, re.DOTALL)
        acceptance = acceptance_match.group(1).strip() if acceptance_match else ""

        # Get REQ number from mapping
        if feature_key in US_TO_REQ and us_id in US_TO_REQ[feature_key]:
            req_num, req_title = US_TO_REQ[feature_key][us_id]
            stories.append((req_num, req_title, description, priority, acceptance))

    return stories


def generate_req_from_us(req_num: str, title: str, description: str, priority: str, acceptance: str) -> str:
    """Generate REQ document from user story."""

    # Convert acceptance criteria to SHALL statements
    verification = ""
    if acceptance:
        # Split by bullets or numbers
        criteria = re.split(r'\n\s*[-*\d]+\.?\s+', acceptance)
        criteria = [c.strip() for c in criteria if c.strip()]
        if criteria:
            verification = "**Demonstration:** The system SHALL meet the following acceptance criteria:\n\n"
            for criterion in criteria:
                verification += f"- {criterion}\n"

    if not verification:
        verification = "**Demonstration:** TBD - Define specific verification steps"

    # Generate requirement statement from description
    requirement = f"The system SHALL support the following capability: {description}"

    rationale = "This requirement enables the user story described above."

    content = f"""# REQ-{req_num}: {title}

## Classification

- **Priority:** {priority}
- **Stability:** Stable
- **Verification:** Demonstration

## Requirement

{requirement}

## Rationale

{rationale}

## Parent Requirements

None

## Allocated To

TBD (will be filled by establish-traceability.py)

## Interfaces

TBD (will be filled by establish-traceability.py)

## Verification Method

{verification}

## Notes

User Story: {description}
"""

    return content


def generate_req_from_fr(req_num: str, title: str, fr_content: str) -> str:
    """Generate REQ document from functional requirements group."""

    content = f"""# REQ-{req_num}: {title}

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Test

## Requirement

{fr_content}

## Rationale

This requirement defines the functional behavior of the {title.lower()} subsystem.

## Parent Requirements

None

## Allocated To

TBD (will be filled by establish-traceability.py)

## Interfaces

TBD (will be filled by establish-traceability.py)

## Verification Method

**Test:** Execute relevant test suite for {title.lower()}.

## Notes

Functional requirements grouped from specification.
"""

    return content


def generate_int_from_contract(int_num: str, title: str, int_type: str, contract_path: Path) -> str:
    """Generate INT document from contract file."""

    spec_content = contract_path.read_text()

    # Remove the title if it exists in the content
    spec_content = re.sub(r'^#\s+.*?\n', '', spec_content, count=1)

    content = f"""# INT-{int_num}: {title}

## Type

{int_type}

## Parties

TBD (will be filled by establish-traceability.py)

## Referenced By

TBD (will be filled by establish-traceability.py)

## Specification

{spec_content}

## Constraints

See specification details above.

## Notes

Migrated from speckit contract: {contract_path.relative_to(ROOT_DIR)}
"""

    return content


def generate_external_int(int_num: str, title: str, description: str) -> str:
    """Generate external interface document."""

    content = f"""# INT-{int_num}: {title}

## Type

External Standard

## External Specification

- **Standard:** {title}
- **Reference:** {description}

## Parties

- **Provider:** External
- **Consumer:** TBD (will be filled by establish-traceability.py)

## Referenced By

TBD (will be filled by establish-traceability.py)

## Specification

### Overview

This project uses a subset of the {title} standard.

### Usage

{description}

## Constraints

See external specification for full details.

## Notes

This is an external standard. Refer to the official specification for complete details.
"""

    return content


def generate_unit(unit_num: str, title: str, file_path: str, purpose: str) -> str:
    """Generate UNIT document."""

    content = f"""# UNIT-{unit_num}: {title}

## Purpose

{purpose}

## Implements Requirements

TBD (will be filled by establish-traceability.py)

## Interfaces

### Provides

TBD (will be filled by establish-traceability.py)

### Consumes

TBD (will be filled by establish-traceability.py)

### Internal Interfaces

TBD

## Design Description

### Inputs

TBD

### Outputs

TBD

### Internal State

TBD

### Algorithm / Behavior

TBD

## Implementation

- `{file_path}`: Main implementation

## Verification

TBD

## Design Notes

Migrated from speckit module specification.
"""

    return content


# ============================================================================
# Main Migration Functions
# ============================================================================

def migrate_user_stories():
    """Migrate user stories to REQ documents."""
    print("Migrating user stories...")

    for feature_key, us_map in US_TO_REQ.items():
        spec_file = SPECS_DIR / feature_key / "spec.md"
        if not spec_file.exists():
            print(f"  Warning: {spec_file} not found, skipping")
            continue

        print(f"  Processing {feature_key}...")
        stories = extract_user_stories(spec_file, feature_key)

        for req_num, title, description, priority, acceptance in stories:
            req_file = REQ_DIR / f"req_{req_num}_{snake_case(title)}.md"
            content = generate_req_from_us(req_num, title, description, priority, acceptance)
            req_file.write_text(content)
            print(f"    Created {req_file.name}")


def migrate_functional_requirements():
    """Migrate functional requirements to REQ documents."""
    print("Migrating functional requirements...")

    # For now, create stub documents for FR groups
    # A more sophisticated parser could extract actual FR content

    for feature_key, fr_map in FR_TO_REQ.items():
        seen = set()
        for fr_id, (req_num, title) in fr_map.items():
            if req_num in seen:
                continue
            seen.add(req_num)

            req_file = REQ_DIR / f"req_{req_num}_{snake_case(title)}.md"
            if req_file.exists():
                continue  # Skip if already created (e.g., from US or overlap)

            fr_content = f"The system SHALL implement {title.lower()} as specified in the functional requirements."
            content = generate_req_from_fr(req_num, title, fr_content)
            req_file.write_text(content)
            print(f"  Created {req_file.name}")


def migrate_nfrs():
    """Migrate non-functional requirements to REQ documents."""
    print("Migrating non-functional requirements...")

    for req_num, title in NFR_TO_REQ:
        req_file = REQ_DIR / f"req_{req_num}_{snake_case(title)}.md"

        # Create stub NFR documents
        content = f"""# REQ-{req_num}: {title}

## Classification

- **Priority:** Essential
- **Stability:** Stable
- **Verification:** Analysis

## Requirement

The system SHALL meet the {title.lower()} defined in the specification.

## Rationale

These targets ensure the system meets performance, resource, and reliability expectations.

## Parent Requirements

None

## Allocated To

TBD (will be filled by establish-traceability.py)

## Interfaces

TBD (will be filled by establish-traceability.py)

## Verification Method

**Analysis:** Measure actual performance/resource usage against targets.

## Notes

Non-functional requirement. See specifications for specific numeric targets.
"""

        req_file.write_text(content)
        print(f"  Created {req_file.name}")


def migrate_contracts():
    """Migrate contract files to INT documents."""
    print("Migrating contracts...")

    for contract_rel, (int_num, title, int_type) in CONTRACT_TO_INT.items():
        contract_path = SPECS_DIR / contract_rel
        if not contract_path.exists():
            print(f"  Warning: {contract_path} not found, skipping")
            continue

        int_file = INT_DIR / f"int_{int_num}_{snake_case(title)}.md"
        content = generate_int_from_contract(int_num, title, int_type, contract_path)
        int_file.write_text(content)
        print(f"  Created {int_file.name}")


def create_external_interfaces():
    """Create external interface documents."""
    print("Creating external interface documents...")

    for int_num, title, description in EXTERNAL_INTERFACES:
        int_file = INT_DIR / f"int_{int_num}_{snake_case(title)}.md"
        content = generate_external_int(int_num, title, description)
        int_file.write_text(content)
        print(f"  Created {int_file.name}")


def migrate_modules():
    """Migrate module definitions to UNIT documents."""
    print("Migrating modules to design units...")

    for component, units in MODULE_TO_UNIT.items():
        print(f"  Processing {component}...")
        for unit_num, title, file_path, purpose in units:
            unit_file = UNIT_DIR / f"unit_{unit_num}_{snake_case(title)}.md"
            content = generate_unit(unit_num, title, file_path, purpose)
            unit_file.write_text(content)
            print(f"    Created {unit_file.name}")


def extract_design_decisions():
    """Extract design decisions from research.md files and append to design_decisions.md."""
    print("Extracting design decisions...")

    dd_file = UNIT_DIR / "design_decisions.md"

    # Read existing content
    if dd_file.exists():
        existing = dd_file.read_text()
    else:
        existing = "# Architecture Decision Records\n\n"

    # Common research topics to extract
    research_files = [
        SPECS_DIR / "001-spi-gpu" / "research.md",
        SPECS_DIR / "002-rp2350-host-software" / "research.md",
        SPECS_DIR / "003-asset-data-prep" / "research.md",
    ]

    adrs = []
    adr_num = 1

    for research_file in research_files:
        if not research_file.exists():
            continue

        content = research_file.read_text()

        # Look for major decision topics (sections starting with ##)
        sections = re.findall(r'^##\s+(.+?)\n(.*?)(?=^##|\Z)', content, re.MULTILINE | re.DOTALL)

        for section_title, section_content in sections[:3]:  # Limit to first 3 per file
            adr = f"""
## DD-{adr_num:03d}: {section_title}

**Date:** 2026-02-08
**Status:** Accepted

### Context

{section_content[:500].strip()}...

### Decision

See research documentation for full details.

### Rationale

Extracted from research.md: {research_file.relative_to(ROOT_DIR)}

### Consequences

TBD - Document specific trade-offs and implications.

---
"""
            adrs.append(adr)
            adr_num += 1

    # Append ADRs to file
    if adrs:
        updated = existing + "\n" + "\n".join(adrs)
        dd_file.write_text(updated)
        print(f"  Added {len(adrs)} ADRs to {dd_file.name}")


# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    print("=" * 70)
    print("SPECKIT TO SYSKIT MIGRATION")
    print("=" * 70)

    ensure_dirs()

    migrate_user_stories()
    migrate_functional_requirements()
    migrate_nfrs()
    migrate_contracts()
    create_external_interfaces()
    migrate_modules()
    extract_design_decisions()

    print("\n" + "=" * 70)
    print("MIGRATION COMPLETE")
    print("=" * 70)
    print(f"\nGenerated documents in:")
    print(f"  - {REQ_DIR}")
    print(f"  - {INT_DIR}")
    print(f"  - {UNIT_DIR}")
    print(f"\nNext steps:")
    print(f"  1. Run: python .syskit/scripts/establish-traceability.py")
    print(f"  2. Run: python .syskit/scripts/validate-migration.py")


if __name__ == "__main__":
    main()
