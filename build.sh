#!/bin/bash
# Unified build script for pico-gs project
# Builds FPGA bitstream and runs RTL tests

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directories
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION="${REPO_ROOT}/integration"
MAKEFLAGS="-j$(nproc)"
OUTPUT_DIR="${REPO_ROOT}/build"

# Default build targets
BUILD_FPGA=true
BUILD_DT=true
BUILD_TEST=true
FLASH_FPGA=false
CLEAN=false
DT_ONLY=false
CHECK_ONLY=false
RESOURCES_ONLY=false
DT_VERIFY=false
PIPELINE_ONLY=false
CONTRACTS_ONLY=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --fpga-only)
            BUILD_DT=false
            BUILD_TEST=false
            shift
            ;;
        --dt-only)
            DT_ONLY=true
            BUILD_FPGA=false
            BUILD_TEST=false
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --pipeline)
            PIPELINE_ONLY=true
            shift
            ;;
        --contracts)
            CONTRACTS_ONLY=true
            shift
            ;;
        --resources)
            RESOURCES_ONLY=true
            shift
            ;;
        --dt-verify)
            DT_VERIFY=true
            BUILD_FPGA=false
            BUILD_TEST=false
            shift
            ;;
        --test-only)
            BUILD_FPGA=false
            shift
            ;;
        --no-test)
            BUILD_TEST=false
            shift
            ;;
        --no-dt)
            BUILD_DT=false
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --flash-fpga)
            FLASH_FPGA=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --fpga-only         Build only FPGA bitstream (skip DT and RTL tests)"
            echo "  --check             Quick check: Verilator lint, cargo fmt, cargo check, cargo clippy"
            echo "  --pipeline          Validate pipeline model and generate D2 diagrams"
            echo "  --contracts         Run all contract conformance testbenches (properties + trace diff)"
            echo "  --resources         Per-module ECP5 resource utilization report"
            echo "  --dt-only           Build and test digital twin only"
            echo "  --dt-verify         Verify RTL modules against digital twin (DT-generated test vectors)"
            echo "  --test-only         Run tests only (skip FPGA build)"
            echo "  --no-test           Skip RTL tests (build only)"
            echo "  --no-dt             Skip digital twin build and tests"
            echo "  --clean             Clean build artifacts before building"
            echo "  --flash-fpga        Program FPGA after build"
            echo "  --help              Show this help message"
            echo ""
            echo "Default: Build FPGA bitstream, digital twin, and run all tests"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}=== pico-gs Build System ===${NC}"
echo ""

# Clean build artifacts
if [ "$CLEAN" = true ]; then
    echo -e "${YELLOW}Cleaning previous build artifacts...${NC}"
    cd "${INTEGRATION}"
    make clean
    find "${OUTPUT_DIR}" -type f -delete 2>/dev/null || true
    echo -e "${GREEN}Cleaned files in ${OUTPUT_DIR}/${NC}"
    echo ""
fi

# Generate shared .hex test scripts from Python generators.
# These are consumed by both the Verilator harness and the digital twin.
echo -e "${YELLOW}Generating .hex test scripts...${NC}"
python3 "${INTEGRATION}/scripts/gen/generate_all.py"
echo -e "${GREEN}.hex test scripts generated${NC}"
echo ""

# Quick check mode: lint + cargo check + clippy, then exit
if [ "$CHECK_ONLY" = true ]; then
    echo -e "${YELLOW}[1/5] Verilator lint...${NC}"
    cd "${INTEGRATION}"
    make lint
    echo -e "${GREEN}Verilator lint passed${NC}"
    echo ""

    echo -e "${YELLOW}[2/5] cargo fmt --check...${NC}"
    cd "${REPO_ROOT}"
    cargo fmt --check
    echo -e "${GREEN}cargo fmt passed${NC}"
    echo ""

    echo -e "${YELLOW}[3/5] cargo check...${NC}"
    cargo check
    echo -e "${GREEN}cargo check passed${NC}"
    echo ""

    echo -e "${YELLOW}[4/5] cargo clippy...${NC}"
    cargo clippy -- -D warnings
    echo -e "${GREEN}cargo clippy passed${NC}"
    echo ""

    echo -e "${YELLOW}[5/5] Pipeline validation...${NC}"
    python3 "${REPO_ROOT}/pipeline/validate.py"
    echo -e "${GREEN}Pipeline validation passed${NC}"
    echo ""

    echo -e "${GREEN}=== Check Complete ===${NC}"
    exit 0
fi

# Resource utilization report mode
if [ "$RESOURCES_ONLY" = true ]; then
    echo -e "${YELLOW}Generating per-module ECP5 resource utilization report...${NC}"
    cd "${INTEGRATION}"
    make resources
    echo ""
    echo -e "${GREEN}=== Resource Report Complete ===${NC}"
    echo "Report saved to ${OUTPUT_DIR}/fpga/resource_report.txt"
    exit 0
fi

# Pipeline model validation + diagram generation
if [ "$PIPELINE_ONLY" = true ]; then
    echo -e "${YELLOW}Validating pipeline model...${NC}"
    python3 "${REPO_ROOT}/pipeline/validate.py"
    echo ""

    echo -e "${YELLOW}Generating pipeline diagrams...${NC}"
    python3 "${REPO_ROOT}/pipeline/gen_diagrams.py" --output-dir "${OUTPUT_DIR}/pipeline"
    echo ""

    echo -e "${GREEN}=== Pipeline Complete ===${NC}"
    exit 0
fi

# Contract conformance mode: lint contracts + run every conformance TB
if [ "$CONTRACTS_ONLY" = true ]; then
    echo -e "${YELLOW}[1/2] Linting contracts layer...${NC}"
    cd "${INTEGRATION}"
    make lint-contracts
    echo -e "${GREEN}Contract lint passed${NC}"
    echo ""

    echo -e "${YELLOW}[2/2] Running contract conformance testbenches...${NC}"
    make test-contracts-all
    echo -e "${GREEN}All contract conformance testbenches passed${NC}"
    echo ""

    echo -e "${GREEN}=== Contracts Complete ===${NC}"
    exit 0
fi

# DT-verify mode: generate test vectors from DT, run RTL against them
if [ "$DT_VERIFY" = true ]; then
    echo -e "${YELLOW}[1/2] Building and testing digital twin...${NC}"
    cd "${REPO_ROOT}"
    cargo build -p gs-twin -p gs-twin-cli
    cargo test -p gs-rasterizer
    echo -e "${GREEN}Digital twin tests passed${NC}"
    echo ""

    echo -e "${YELLOW}[2/2] Verifying RTL against digital twin...${NC}"
    cd "${INTEGRATION}"
    make test-raster-dt-all
    make test-texture-dt-all
    make test-cc-dt-all
    echo -e "${GREEN}All DT-verified RTL testbenches passed${NC}"
    echo ""

    echo -e "${GREEN}=== DT Verify Complete ===${NC}"
    exit 0
fi

# Step 1: Build FPGA bitstream
if [ "$BUILD_FPGA" = true ]; then
    echo -e "${YELLOW}[1/3] Building FPGA bitstream...${NC}"
    cd "${INTEGRATION}"
    make bitstream
    FPGA_BITSTREAM="${REPO_ROOT}/build/fpga/gpu_top.bit"
    echo -e "${GREEN}Bitstream built: ${FPGA_BITSTREAM}${NC}"
    SYNTH_SUMMARY="${REPO_ROOT}/build/fpga/synth_summary.txt"
    if [ -f "$SYNTH_SUMMARY" ]; then
        echo ""
        cat "$SYNTH_SUMMARY"
    fi
    echo ""
fi

# Step 2: Digital twin build + tests
if [ "$BUILD_DT" = true ]; then
    echo -e "${YELLOW}[2/3] Building and testing digital twin (gs-twin)...${NC}"
    cd "${REPO_ROOT}"
    cargo build -p gs-twin -p gs-twin-cli
    cargo test -p gs-twin
    cargo test -p gs-rasterizer
    echo -e "${GREEN}Digital twin tests passed${NC}"

    # Generate golden reference images for all VER-010 through VER-022 scenes.
    # The gs-twin integration tests (cargo test -p gs-twin) also produce these
    # images, including Z-buffer variants for VER-014 and VER-016.
    DT_OUT="${OUTPUT_DIR}/dt_out"
    mkdir -p "${DT_OUT}"
    for scene in ver_010 ver_011 ver_012 ver_013 ver_014 ver_015 ver_016 \
                 ver_017 ver_018 ver_019 ver_020 ver_021 ver_022; do
        # Determine output filename from scene name
        case "${scene}" in
            ver_010) name="ver_010_gouraud_triangle" ;;
            ver_011) name="ver_011_depth_test" ;;
            ver_012) name="ver_012_textured_triangle" ;;
            ver_013) name="ver_013_color_combined" ;;
            ver_014) name="ver_014_textured_cube" ;;
            ver_015) name="ver_015_size_grid" ;;
            ver_016) name="ver_016_perspective_road" ;;
            ver_017) name="ver_017_bc1_texture" ;;
            ver_018) name="ver_018_bc2_texture" ;;
            ver_019) name="ver_019_bc3_texture" ;;
            ver_020) name="ver_020_bc4_texture" ;;
            ver_021) name="ver_021_rgba8888_texture" ;;
            ver_022) name="ver_022_r8_texture" ;;
        esac
        cargo run -p gs-twin-cli -- render --scene "${scene}" \
            --output "${DT_OUT}/${name}.png" --width 512 --height 480
    done
    echo -e "${GREEN}Golden references generated in ${DT_OUT}/${NC}"
    echo ""
fi

# Step 3: RTL tests (lint + unit testbenches + golden image tests if approved)
if [ "$BUILD_TEST" = true ]; then
    echo -e "${YELLOW}[3/3] Running RTL tests (lint + unit testbenches + golden image tests)...${NC}"
    cd "${INTEGRATION}"
    make test
    echo -e "${GREEN}RTL tests passed${NC}"
    echo ""
fi

# Collect build outputs into structured directory
echo -e "${YELLOW}Collecting build outputs...${NC}"
mkdir -p "${OUTPUT_DIR}/fpga"

if [ "$BUILD_FPGA" = true ] && [ -f "${OUTPUT_DIR}/fpga/gpu_top.bit" ]; then
    echo "  FPGA Bitstream:  ${OUTPUT_DIR}/fpga/gpu_top.bit"
    echo "  FPGA Synthesis:  ${OUTPUT_DIR}/fpga/gpu_top.json"
    echo "  FPGA PNR:        ${OUTPUT_DIR}/fpga/gpu_top.config"
    echo "  FPGA Log:        ${OUTPUT_DIR}/fpga/yosys.log"
fi

echo -e "${GREEN}Build outputs collected in ${OUTPUT_DIR}/${NC}"
echo ""

# Optional: Program FPGA
if [ "$FLASH_FPGA" = true ]; then
    echo -e "${YELLOW}Programming FPGA...${NC}"
    cd "${INTEGRATION}"
    make program
    echo -e "${GREEN}FPGA programmed${NC}"
fi

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo "Ready for deployment to ICEpi dev board"
