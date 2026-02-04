#!/bin/bash
# Unified build script for pico-gs project
# Builds FPGA bitstream, RP2350 firmware, and processes assets

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directories
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_APP="${REPO_ROOT}/host_app"
SPI_GPU="${REPO_ROOT}/spi_gpu"
OUTPUT_DIR="${REPO_ROOT}/build"

# Default build targets
BUILD_FIRMWARE=true
BUILD_FPGA=true
RELEASE_MODE=false
FLASH_FIRMWARE=false
FLASH_FPGA=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --assets-only)
            # Assets are now built automatically by host_app/build.rs during cargo build.
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
            echo "  --release           Build in release mode (optimized)"
            echo "  --flash-firmware    Flash firmware to RP2350 after build"
            echo "  --flash-fpga        Program FPGA after build"
            echo "  --help              Show this help message"
            echo ""
            echo "Default: Build everything in debug mode"
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

# Step 1: Build RP2350 firmware (asset conversion happens automatically via build.rs)
if [ "$BUILD_FIRMWARE" = true ]; then
    echo -e "${YELLOW}[1/3] Building RP2350 firmware (includes asset conversion)...${NC}"
    cd "${REPO_ROOT}"
    if [ "$RELEASE_MODE" = true ]; then
        cargo build --release -p pico-gs-host --target thumbv8m.main-none-eabihf
        FIRMWARE_ELF="${REPO_ROOT}/target/thumbv8m.main-none-eabihf/release/pico-gs-host"
    else
        cargo build -p pico-gs-host --target thumbv8m.main-none-eabihf
        FIRMWARE_ELF="${REPO_ROOT}/target/thumbv8m.main-none-eabihf/debug/pico-gs-host"
    fi
    echo -e "${GREEN}✓ Firmware built: ${FIRMWARE_ELF}${NC}"
    echo ""
fi

# Step 2: Build FPGA bitstream
if [ "$BUILD_FPGA" = true ]; then
    echo -e "${YELLOW}[2/3] Building FPGA bitstream...${NC}"
    cd "${SPI_GPU}"
    make clean
    make bitstream
    FPGA_BITSTREAM="${SPI_GPU}/build/gpu_top.bit"
    echo -e "${GREEN}✓ Bitstream built: ${FPGA_BITSTREAM}${NC}"
    echo ""
fi

# Step 3: Copy outputs to unified build directory
echo -e "${YELLOW}[3/3] Collecting build outputs...${NC}"
mkdir -p "${OUTPUT_DIR}"

if [ "$BUILD_FIRMWARE" = true ] && [ -f "$FIRMWARE_ELF" ]; then
    cp "$FIRMWARE_ELF" "${OUTPUT_DIR}/pico-gs-host.elf"
    echo "  Firmware: ${OUTPUT_DIR}/pico-gs-host.elf"
fi

if [ "$BUILD_FPGA" = true ] && [ -f "$FPGA_BITSTREAM" ]; then
    cp "$FPGA_BITSTREAM" "${OUTPUT_DIR}/gpu_top.bit"
    echo "  FPGA Bitstream: ${OUTPUT_DIR}/gpu_top.bit"
fi

echo -e "${GREEN}✓ Build outputs collected in ${OUTPUT_DIR}${NC}"
echo ""

# Optional: Flash firmware
if [ "$FLASH_FIRMWARE" = true ]; then
    echo -e "${YELLOW}Flashing firmware to RP2350...${NC}"
    cd "${HOST_APP}"
    cargo run --release --target thumbv8m.main-none-eabihf
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
