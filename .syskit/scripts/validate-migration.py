#!/usr/bin/env python3
"""
Validate speckit to syskit migration.

Checks:
- Document count
- Cross-reference integrity
- Required fields populated
- Traceability completeness
- Content migration completeness
"""

import re
from pathlib import Path
from typing import Dict, List, Set, Tuple

# Project root
ROOT_DIR = Path(__file__).parent.parent.parent
DOC_DIR = ROOT_DIR / "doc"
REQ_DIR = DOC_DIR / "requirements"
INT_DIR = DOC_DIR / "interfaces"
UNIT_DIR = DOC_DIR / "design"
SPECS_DIR = ROOT_DIR / "specs"


# ============================================================================
# Helper Functions
# ============================================================================

def find_all_docs(doc_dir: Path, prefix: str) -> List[Path]:
    """Find all documents with given prefix."""
    return sorted([p for p in doc_dir.glob(f"{prefix}_*.md") if p.stem != f"{prefix}_000_template"])


def extract_doc_id(doc_path: Path) -> str:
    """Extract document ID (e.g., REQ-001, INT-010, UNIT-005)."""
    name = doc_path.stem
    match = re.match(r'(req|int|unit)_(\d+)', name)
    if match:
        prefix_map = {"req": "REQ", "int": "INT", "unit": "UNIT"}
        return f"{prefix_map[match.group(1)]}-{match.group(2)}"
    return None


def find_all_references(content: str, ref_type: str) -> Set[str]:
    """Find all references of a given type in content."""
    pattern = rf'\b{ref_type}-\d+\b'
    return set(re.findall(pattern, content))


def check_tbd_presence(content: str) -> List[str]:
    """Check for TBD markers in content."""
    tbd_sections = []
    # Look for lines that are just "TBD" or "TBD (...)"
    matches = re.finditer(r'^(TBD[^\n]*)$', content, re.MULTILINE)
    for match in matches:
        tbd_sections.append(match.group(1))
    return tbd_sections


def has_section(content: str, section_name: str) -> bool:
    """Check if a section exists and has content."""
    pattern = rf'##\s+{re.escape(section_name)}\s*\n\n(.+?)(?=##|\Z)'
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        return False
    section_content = match.group(1).strip()
    return len(section_content) > 0 and not section_content.startswith("TBD")


# ============================================================================
# Validation Checks
# ============================================================================

def check_document_count() -> Tuple[bool, str]:
    """Check if all expected documents exist."""
    print("Checking document count...")

    req_docs = find_all_docs(REQ_DIR, "req")
    int_docs = find_all_docs(INT_DIR, "int")
    unit_docs = find_all_docs(UNIT_DIR, "unit")

    req_count = len(req_docs)
    int_count = len(int_docs)
    unit_count = len(unit_docs)
    total = req_count + int_count + unit_count

    print(f"  REQ: {req_count}")
    print(f"  INT: {int_count}")
    print(f"  UNIT: {unit_count}")
    print(f"  Total: {total}")

    # We expect approximately 99 documents (some variation is OK)
    if total < 90:
        return False, f"Expected ~99 documents, found {total}"

    return True, f"Document count: {total}"


def check_cross_reference_integrity() -> Tuple[bool, str]:
    """Check that all cross-references point to existing documents."""
    print("Checking cross-reference integrity...")

    # Get all existing document IDs
    existing_reqs = {extract_doc_id(d) for d in find_all_docs(REQ_DIR, "req")}
    existing_ints = {extract_doc_id(d) for d in find_all_docs(INT_DIR, "int")}
    existing_units = {extract_doc_id(d) for d in find_all_docs(UNIT_DIR, "unit")}

    broken_refs = []

    # Check all documents
    for doc_dir, prefix in [(REQ_DIR, "req"), (INT_DIR, "int"), (UNIT_DIR, "unit")]:
        for doc in find_all_docs(doc_dir, prefix):
            content = doc.read_text()
            doc_id = extract_doc_id(doc)

            # Find all references
            req_refs = find_all_references(content, "REQ")
            int_refs = find_all_references(content, "INT")
            unit_refs = find_all_references(content, "UNIT")

            # Check if referenced documents exist
            for ref in req_refs:
                if ref not in existing_reqs:
                    broken_refs.append(f"{doc_id} → {ref} (not found)")

            for ref in int_refs:
                if ref not in existing_ints:
                    broken_refs.append(f"{doc_id} → {ref} (not found)")

            for ref in unit_refs:
                if ref not in existing_units:
                    broken_refs.append(f"{doc_id} → {ref} (not found)")

    if broken_refs:
        return False, f"Found {len(broken_refs)} broken references:\n  " + "\n  ".join(broken_refs[:10])

    return True, "All cross-references are valid"


def check_required_fields() -> Tuple[bool, str]:
    """Check that required fields are populated in all documents."""
    print("Checking required fields...")

    issues = []

    # Check REQ documents
    for req_doc in find_all_docs(REQ_DIR, "req"):
        content = req_doc.read_text()
        req_id = extract_doc_id(req_doc)

        if not has_section(content, "Requirement"):
            issues.append(f"{req_id}: Missing Requirement section")
        if not has_section(content, "Rationale"):
            issues.append(f"{req_id}: Missing Rationale section")
        if not has_section(content, "Allocated To"):
            issues.append(f"{req_id}: Missing Allocated To section")

        # Check for TBD in critical sections
        allocated_to_match = re.search(r'##\s+Allocated To\s*\n\n(.+?)(?=##|\Z)', content, re.DOTALL)
        if allocated_to_match and "TBD" in allocated_to_match.group(1):
            issues.append(f"{req_id}: Allocated To still contains TBD")

    # Check INT documents
    for int_doc in find_all_docs(INT_DIR, "int"):
        content = int_doc.read_text()
        int_id = extract_doc_id(int_doc)

        if not has_section(content, "Type"):
            issues.append(f"{int_id}: Missing Type section")
        if not has_section(content, "Specification"):
            issues.append(f"{int_id}: Missing Specification section")

        # Check for TBD in Parties (unless external)
        parties_match = re.search(r'##\s+Parties\s*\n\n(.+?)(?=##|\Z)', content, re.DOTALL)
        if parties_match and "TBD" in parties_match.group(1):
            # Allow TBD for external interfaces
            if "External" not in parties_match.group(1):
                issues.append(f"{int_id}: Parties still contains TBD")

    # Check UNIT documents
    for unit_doc in find_all_docs(UNIT_DIR, "unit"):
        content = unit_doc.read_text()
        unit_id = extract_doc_id(unit_doc)

        if not has_section(content, "Purpose"):
            issues.append(f"{unit_id}: Missing Purpose section")
        if not has_section(content, "Implementation"):
            issues.append(f"{unit_id}: Missing Implementation section")

        # Check for TBD in Implements Requirements
        impl_match = re.search(r'##\s+Implements Requirements\s*\n\n(.+?)(?=##|\Z)', content, re.DOTALL)
        if impl_match and "TBD" in impl_match.group(1):
            issues.append(f"{unit_id}: Implements Requirements still contains TBD")

    if issues:
        return False, f"Found {len(issues)} missing/incomplete fields:\n  " + "\n  ".join(issues[:10])

    return True, "All required fields are populated"


def check_traceability_completeness() -> Tuple[bool, str]:
    """Check that traceability is complete (REQ↔UNIT, INT↔REQ)."""
    print("Checking traceability completeness...")

    issues = []

    # Check that every REQ is allocated to at least one UNIT
    for req_doc in find_all_docs(REQ_DIR, "req"):
        content = req_doc.read_text()
        req_id = extract_doc_id(req_doc)

        unit_refs = find_all_references(content, "UNIT")
        if not unit_refs:
            issues.append(f"{req_id}: Not allocated to any UNIT")

    # Check that every UNIT implements at least one REQ
    for unit_doc in find_all_docs(UNIT_DIR, "unit"):
        content = unit_doc.read_text()
        unit_id = extract_doc_id(unit_doc)

        req_refs = find_all_references(content, "REQ")
        if not req_refs:
            issues.append(f"{unit_id}: Does not implement any REQ")

    # Check that every INT is referenced by at least one REQ or UNIT
    for int_doc in find_all_docs(INT_DIR, "int"):
        content = int_doc.read_text()
        int_id = extract_doc_id(int_doc)

        # Look for references in Referenced By section
        ref_by_match = re.search(r'##\s+Referenced By\s*\n\n(.+?)(?=##|\Z)', content, re.DOTALL)
        if ref_by_match:
            req_refs = find_all_references(ref_by_match.group(1), "REQ")
            if not req_refs:
                # It's OK if external standard isn't directly referenced
                if "External Standard" not in content:
                    issues.append(f"{int_id}: Not referenced by any REQ")

    if issues:
        return False, f"Found {len(issues)} traceability gaps:\n  " + "\n  ".join(issues[:10])

    return True, "Traceability is complete"


def check_content_migration() -> Tuple[bool, str]:
    """Check that content was migrated from speckit."""
    print("Checking content migration...")

    issues = []

    # Count user stories in source specs
    if SPECS_DIR.exists():
        gpu_spec = SPECS_DIR / "001-spi-gpu" / "spec.md"
        host_spec = SPECS_DIR / "002-rp2350-host-software" / "spec.md"
        asset_spec = SPECS_DIR / "003-asset-data-prep" / "spec.md"

        total_us = 0
        for spec_file in [gpu_spec, host_spec, asset_spec]:
            if spec_file.exists():
                content = spec_file.read_text()
                us_count = len(re.findall(r'###\s+US-\d+:', content))
                total_us += us_count

        # Check corresponding REQ documents exist
        req_us_docs = [d for d in find_all_docs(REQ_DIR, "req") if extract_doc_id(d) in
                       ["REQ-001", "REQ-002", "REQ-003", "REQ-004", "REQ-005", "REQ-006", "REQ-007",
                        "REQ-008", "REQ-009", "REQ-010", "REQ-011", "REQ-012", "REQ-013", "REQ-014",
                        "REQ-015", "REQ-016", "REQ-100", "REQ-101", "REQ-102", "REQ-103", "REQ-104",
                        "REQ-105", "REQ-200", "REQ-201", "REQ-202"]]

        if len(req_us_docs) < total_us:
            issues.append(f"Expected {total_us} user story REQs, found {len(req_us_docs)}")

    # Count contracts
    contract_count = 0
    if SPECS_DIR.exists():
        for contracts_dir in SPECS_DIR.glob("*/contracts"):
            contract_count += len(list(contracts_dir.glob("*.md")))

        # Check corresponding INT documents (internal contracts)
        int_internal_docs = [d for d in find_all_docs(INT_DIR, "int") if extract_doc_id(d) in
                             ["INT-010", "INT-011", "INT-012", "INT-020", "INT-021", "INT-030", "INT-031"]]

        if len(int_internal_docs) < contract_count:
            issues.append(f"Expected at least {contract_count} internal INT docs, found {len(int_internal_docs)}")

    if issues:
        return False, f"Content migration issues:\n  " + "\n  ".join(issues)

    return True, "Content migration is complete"


# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    print("=" * 70)
    print("MIGRATION VALIDATION")
    print("=" * 70)
    print()

    checks = [
        check_document_count,
        check_cross_reference_integrity,
        check_required_fields,
        check_traceability_completeness,
        check_content_migration,
    ]

    results = []
    for check in checks:
        print()
        success, message = check()
        results.append((check.__name__, success, message))

    print("\n" + "=" * 70)
    print("VALIDATION SUMMARY")
    print("=" * 70)

    all_passed = True
    for name, success, message in results:
        status = "✓ PASS" if success else "✗ FAIL"
        print(f"\n{status} - {name}")
        print(f"  {message}")
        if not success:
            all_passed = False

    print("\n" + "=" * 70)
    if all_passed:
        print("✓ ALL CHECKS PASSED")
        print("=" * 70)
        print("\nMigration is complete and valid!")
        print("\nNext steps:")
        print("  1. Perform manual review (see plan)")
        print("  2. Update CLAUDE.md and README.md")
        print("  3. Run .syskit/scripts/manifest.sh")
        print("  4. Remove specs/ folder")
        print("  5. Commit changes")
        return 0
    else:
        print("✗ SOME CHECKS FAILED")
        print("=" * 70)
        print("\nPlease address the issues above before proceeding.")
        return 1


if __name__ == "__main__":
    exit(main())
