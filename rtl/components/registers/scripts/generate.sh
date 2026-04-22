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
REPO_ROOT="$(cd "$REG_DIR/../../.." && pwd)"
TWIN_DIR="${REPO_ROOT}/twin/components/registers"

RDL_FILE="${REG_DIR}/rdl/gpu_regs.rdl"
SV_OUT_DIR="${REG_DIR}/generated"

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

echo "Generating Rust components → ${TWIN_DIR}/src/"
peakrdl rust "${RDL_FILE}" -o "${RUST_TEMP}/" --force

# Replace only the generated components (lib.rs, encode.rs, etc. are hand-maintained)
rm -rf "${TWIN_DIR}/src/components" "${TWIN_DIR}/src/components.rs"
cp -r "${RUST_TEMP}/components" "${TWIN_DIR}/src/components"
cp "${RUST_TEMP}/components.rs" "${TWIN_DIR}/src/components.rs"

# Format generated Rust code
rustfmt "${TWIN_DIR}/src/components.rs"
find "${TWIN_DIR}/src/components" -name '*.rs' -exec rustfmt {} +

echo ""
echo "Generated Rust files:"
find "${TWIN_DIR}/src/components" -type f | sort
echo ""

echo "Done. Review changes with: git diff"
