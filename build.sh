#!/bin/bash
# Unified build script for pico-gs project
# Builds FPGA bitstream, RP2350 firmware, runs tests, and collects outputs

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directories
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_CRATE="${REPO_ROOT}/crates/pico-gs-rp2350"
SPI_GPU="${REPO_ROOT}/spi_gpu"
OUTPUT_DIR="${REPO_ROOT}/build"

# Default build targets
BUILD_FIRMWARE=true
BUILD_FPGA=true
BUILD_TEST=true
RELEASE_MODE=false
FLASH_FIRMWARE=false
FLASH_FPGA=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --assets-only)
            # Assets are built automatically by pico-gs-rp2350/build.rs during cargo build.
            # This flag triggers a firmware build which includes asset conversion.
            BUILD_FPGA=false
            shift
            ;;
        --firmware-only)
            BUILD_FPGA=false
            shift
            ;;
        --fpga-only)
            BUILD_FIRMWARE=false
            shift
            ;;
        --pc-only)
            BUILD_FIRMWARE=false
            BUILD_FPGA=false
            BUILD_PC=true
            shift
            ;;
        --registers-only)
            BUILD_FIRMWARE=false
            BUILD_FPGA=false
            BUILD_REGISTERS=true
            shift
            ;;
        --test-only)
            BUILD_FIRMWARE=false
            BUILD_FPGA=false
            shift
            ;;
        --no-test)
            BUILD_TEST=false
            shift
            ;;
        --release)
            RELEASE_MODE=true
            shift
            ;;
        --flash-firmware)
            FLASH_FIRMWARE=true
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
            echo "  --assets-only       Build firmware (assets are converted automatically by build.rs)"
            echo "  --firmware-only     Build only RP2350 firmware (skips FPGA)"
            echo "  --fpga-only         Build only FPGA bitstream"
            echo "  --pc-only           Build only PC debug host (pico-gs-pc)"
            echo "  --registers-only    Regenerate register definitions from SystemRDL"
            echo "  --test-only         Run tests only (skip all builds)"
            echo "  --no-test           Skip tests (build only)"
            echo "  --release           Build in release mode (optimized)"
            echo "  --flash-firmware    Flash firmware to RP2350 after build"
            echo "  --flash-fpga        Program FPGA after build"
            echo "  --help              Show this help message"
            echo ""
            echo "Default: Build everything and run all tests"
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

# Step 0: Regenerate register definitions (if requested)
if [ "${BUILD_REGISTERS:-false}" = true ]; then
    echo -e "${YELLOW}Regenerating register definitions from SystemRDL...${NC}"
    "${REPO_ROOT}/registers/scripts/generate.sh"
    echo -e "${GREEN}✓ Register definitions regenerated${NC}"
    echo ""
fi

# Step 1: Build RP2350 firmware (asset conversion happens automatically via build.rs)
if [ "$BUILD_FIRMWARE" = true ]; then
    echo -e "${YELLOW}[1/5] Building RP2350 firmware (includes asset conversion)...${NC}"
    cd "${REPO_ROOT}"
    if [ "$RELEASE_MODE" = true ]; then
        cargo build --release -p pico-gs-rp2350 --target thumbv8m.main-none-eabihf
        FIRMWARE_ELF="${REPO_ROOT}/target/thumbv8m.main-none-eabihf/release/pico-gs-rp2350"
    else
        cargo build -p pico-gs-rp2350 --target thumbv8m.main-none-eabihf
        FIRMWARE_ELF="${REPO_ROOT}/target/thumbv8m.main-none-eabihf/debug/pico-gs-rp2350"
    fi
    echo -e "${GREEN}✓ Firmware built: ${FIRMWARE_ELF}${NC}"
    echo ""
fi

# Step 1b: Build PC debug host
if [ "${BUILD_PC:-false}" = true ]; then
    echo -e "${YELLOW}Building PC debug host...${NC}"
    cd "${REPO_ROOT}"
    if [ "$RELEASE_MODE" = true ]; then
        cargo build --release -p pico-gs-pc
        PC_BINARY="${REPO_ROOT}/target/release/pico-gs-pc"
    else
        cargo build -p pico-gs-pc
        PC_BINARY="${REPO_ROOT}/target/debug/pico-gs-pc"
    fi
    echo -e "${GREEN}✓ PC debug host built${NC}"
    echo ""
fi

# Step 2: Build FPGA bitstream
if [ "$BUILD_FPGA" = true ]; then
    echo -e "${YELLOW}[2/5] Building FPGA bitstream...${NC}"
    cd "${SPI_GPU}"
    make bitstream
    FPGA_BITSTREAM="${SPI_GPU}/build/gpu_top.bit"
    echo -e "${GREEN}✓ Bitstream built: ${FPGA_BITSTREAM}${NC}"
    echo ""
fi

# Step 3: Rust tests
if [ "$BUILD_TEST" = true ]; then
    echo -e "${YELLOW}[3/5] Running Rust tests...${NC}"
    cd "${REPO_ROOT}"
    cargo test -p pico-gs-core
    echo -e "${GREEN}✓ Rust tests passed${NC}"
    echo ""
fi

# Step 4: RTL tests (lint + unit testbenches + golden image tests if approved)
if [ "$BUILD_TEST" = true ]; then
    echo -e "${YELLOW}[4/5] Running RTL tests (lint + unit testbenches + golden image tests)...${NC}"
    cd "${SPI_GPU}"
    make test
    echo -e "${GREEN}✓ RTL tests passed${NC}"
    echo ""
fi

# Step 5: Collect build outputs into structured directory
echo -e "${YELLOW}[5/5] Collecting build outputs...${NC}"
mkdir -p "${OUTPUT_DIR}/firmware" "${OUTPUT_DIR}/fpga" "${OUTPUT_DIR}/pc" "${OUTPUT_DIR}/tests"

if [ "$BUILD_FIRMWARE" = true ] && [ -n "${FIRMWARE_ELF:-}" ] && [ -f "$FIRMWARE_ELF" ]; then
    cp "$FIRMWARE_ELF" "${OUTPUT_DIR}/firmware/pico-gs-rp2350.elf"
    echo "  Firmware: ${OUTPUT_DIR}/firmware/pico-gs-rp2350.elf"
fi

if [ "$BUILD_FPGA" = true ] && [ -f "${SPI_GPU}/build/gpu_top.bit" ]; then
    cp "${SPI_GPU}/build/gpu_top.json"   "${OUTPUT_DIR}/fpga/" 2>/dev/null || true
    cp "${SPI_GPU}/build/gpu_top.config" "${OUTPUT_DIR}/fpga/" 2>/dev/null || true
    cp "${SPI_GPU}/build/gpu_top.bit"    "${OUTPUT_DIR}/fpga/"
    cp "${SPI_GPU}/build/yosys.log"      "${OUTPUT_DIR}/fpga/" 2>/dev/null || true
    echo "  FPGA Bitstream:  ${OUTPUT_DIR}/fpga/gpu_top.bit"
    echo "  FPGA Synthesis:  ${OUTPUT_DIR}/fpga/gpu_top.json"
    echo "  FPGA PNR:        ${OUTPUT_DIR}/fpga/gpu_top.config"
    echo "  FPGA Log:        ${OUTPUT_DIR}/fpga/yosys.log"
fi

if [ "${BUILD_PC:-false}" = true ] && [ -n "${PC_BINARY:-}" ] && [ -f "$PC_BINARY" ]; then
    cp "$PC_BINARY" "${OUTPUT_DIR}/pc/pico-gs-pc"
    echo "  PC Debug Host: ${OUTPUT_DIR}/pc/pico-gs-pc"
fi

echo -e "${GREEN}✓ Build outputs collected in ${OUTPUT_DIR}/${NC}"
echo ""

# Optional: Flash firmware
if [ "$FLASH_FIRMWARE" = true ]; then
    echo -e "${YELLOW}Flashing firmware to RP2350...${NC}"
    cd "${REPO_ROOT}"
    cargo run --release -p pico-gs-rp2350 --target thumbv8m.main-none-eabihf
    echo -e "${GREEN}✓ Firmware flashed${NC}"
fi

# Optional: Program FPGA
if [ "$FLASH_FPGA" = true ]; then
    echo -e "${YELLOW}Programming FPGA...${NC}"
    cd "${SPI_GPU}"
    make program
    echo -e "${GREEN}✓ FPGA programmed${NC}"
fi

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo "Ready for deployment to ICEpi dev board"
