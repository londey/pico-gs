#!/bin/bash
# Generate SystemVerilog register definitions from SystemRDL source.
#
# Prerequisites: pip install peakrdl peakrdl-regblock
#
# The Rust crate (registers/src/lib.rs) is maintained by hand to preserve
# the flat-constant API.  PeakRDL-rust generates a struct-based abstraction
# that would require rewriting all consumers.
#
# Generated SV outputs are checked into the repository — run this script
# manually when gpu_regs.rdl changes, then review the diff before committing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$REG_DIR")"

RDL_FILE="${REG_DIR}/rdl/gpu_regs.rdl"
SV_OUT_DIR="${REPO_ROOT}/spi_gpu/src/spi/generated"

echo "=== GPU Register Code Generation ==="
echo "Source: ${RDL_FILE}"
echo ""

# Check that peakrdl is installed
if ! command -v peakrdl &> /dev/null; then
    echo "ERROR: peakrdl not found."
    echo "Install with: pip install peakrdl peakrdl-regblock"
    exit 1
fi

# Generate SystemVerilog package + register file module
echo "Generating SystemVerilog → ${SV_OUT_DIR}/"
mkdir -p "${SV_OUT_DIR}"
peakrdl regblock "${RDL_FILE}" -o "${SV_OUT_DIR}/" --cpuif passthrough

echo ""
echo "Generated files:"
ls -la "${SV_OUT_DIR}/"
echo ""
echo "NOTE: Rust crate (registers/src/lib.rs) is maintained by hand."
echo "      Verify that register addresses match between lib.rs and gpu_regs.rdl."
echo ""
echo "Done. Review changes with: git diff"
