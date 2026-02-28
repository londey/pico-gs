#!/bin/bash
# Generate SystemVerilog and Rust register definitions from SystemRDL source.
#
# Prerequisites: pip install peakrdl peakrdl-regblock peakrdl-rust
#
# Generated outputs are checked into the repository — run this script
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
    echo "Install with: pip install peakrdl peakrdl-regblock peakrdl-rust"
    exit 1
fi

# -------------------------------------------------------------------
# SystemVerilog generation
# -------------------------------------------------------------------
echo "Generating SystemVerilog → ${SV_OUT_DIR}/"
mkdir -p "${SV_OUT_DIR}"
peakrdl regblock "${RDL_FILE}" -o "${SV_OUT_DIR}/" --cpuif passthrough

echo ""
echo "Generated SV files:"
ls -la "${SV_OUT_DIR}/"
echo ""

# -------------------------------------------------------------------
# Rust crate generation
# -------------------------------------------------------------------
RUST_TEMP=$(mktemp -d)
trap 'rm -rf "${RUST_TEMP}"' EXIT

echo "Generating Rust crate → ${REG_DIR}/src/"
peakrdl rust "${RDL_FILE}" -o "${RUST_TEMP}/" \
    --crate-name gpu_registers \
    --force

GENERATED="${RUST_TEMP}/gpu_registers"

# Replace src/ with generated code
rm -rf "${REG_DIR}/src"
cp -r "${GENERATED}/src" "${REG_DIR}/src"

# Replace tests/ with generated tests
rm -rf "${REG_DIR}/tests"
cp -r "${GENERATED}/tests" "${REG_DIR}/tests"

echo ""
echo "Generated Rust files:"
find "${REG_DIR}/src" -type f | sort
echo ""
find "${REG_DIR}/tests" -type f | sort
echo ""

echo "Done. Review changes with: git diff"
