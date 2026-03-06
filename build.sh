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
SPI_GPU="${REPO_ROOT}/spi_gpu"
MAKEFLAGS="-j$(nproc)"
OUTPUT_DIR="${REPO_ROOT}/build"

# Default build targets
BUILD_FPGA=true
BUILD_TEST=true
FLASH_FPGA=false
CLEAN=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --fpga-only)
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
            echo "  --fpga-only         Build only FPGA bitstream"
            echo "  --test-only         Run tests only (skip FPGA build)"
            echo "  --no-test           Skip tests (build only)"
            echo "  --clean             Clean build artifacts before building"
            echo "  --flash-fpga        Program FPGA after build"
            echo "  --help              Show this help message"
            echo ""
            echo "Default: Build FPGA bitstream and run all tests"
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

# Clean build directory unless incremental
if [ "$CLEAN" = true ]; then
    echo -e "${YELLOW}Cleaning previous build artifacts...${NC}"
    cd "${SPI_GPU}"
    make clean
    echo ""
fi

# Step 1: Build FPGA bitstream
if [ "$BUILD_FPGA" = true ]; then
    echo -e "${YELLOW}[1/2] Building FPGA bitstream...${NC}"
    cd "${SPI_GPU}"
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

# Step 2: RTL tests (lint + unit testbenches + golden image tests if approved)
if [ "$BUILD_TEST" = true ]; then
    echo -e "${YELLOW}[2/2] Running RTL tests (lint + unit testbenches + golden image tests)...${NC}"
    cd "${SPI_GPU}"
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
    cd "${SPI_GPU}"
    make program
    echo -e "${GREEN}FPGA programmed${NC}"
fi

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo "Ready for deployment to ICEpi dev board"
