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
ASSETS_SOURCE="${REPO_ROOT}/host_app/assets"
ASSETS_COMPILED="${REPO_ROOT}/assets/compiled"
HOST_APP_ASSETS="${REPO_ROOT}/host_app/src/assets"
BUILD_TOOL="${REPO_ROOT}/asset_build_tool"
HOST_APP="${REPO_ROOT}/host_app"
SPI_GPU="${REPO_ROOT}/spi_gpu"
OUTPUT_DIR="${REPO_ROOT}/build"

# Default build targets
BUILD_ASSETS=true
BUILD_FIRMWARE=true
BUILD_FPGA=true
RELEASE_MODE=false
FLASH_FIRMWARE=false
FLASH_FPGA=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --assets-only)
            BUILD_FIRMWARE=false
            BUILD_FPGA=false
            shift
            ;;
        --firmware-only)
            BUILD_ASSETS=false
            BUILD_FPGA=false
            shift
            ;;
        --fpga-only)
            BUILD_ASSETS=false
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
            echo "  --assets-only       Build only asset conversion tool and process assets"
            echo "  --firmware-only     Build only RP2350 firmware (skips assets and FPGA)"
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

# Step 1: Build asset preparation tool
if [ "$BUILD_ASSETS" = true ]; then
    echo -e "${YELLOW}[1/5] Building asset preparation tool...${NC}"
    cd "${REPO_ROOT}"
    if [ "$RELEASE_MODE" = true ]; then
        cargo build --release -p asset-prep
        ASSET_TOOL_BIN="${REPO_ROOT}/target/release/asset-prep"
    else
        cargo build -p asset-prep
        ASSET_TOOL_BIN="${REPO_ROOT}/target/debug/asset-prep"
    fi
    echo -e "${GREEN}✓ Asset tool built${NC}"
    echo ""
fi

# Step 2: Process source assets
if [ "$BUILD_ASSETS" = true ]; then
    echo -e "${YELLOW}[2/5] Processing source assets...${NC}"

    # Create output directories
    mkdir -p "${ASSETS_COMPILED}/meshes"
    mkdir -p "${ASSETS_COMPILED}/textures"
    mkdir -p "${HOST_APP_ASSETS}"

    # Convert meshes (.obj → .rs + .bin)
    if ls "${ASSETS_SOURCE}"/meshes/*.obj 1> /dev/null 2>&1; then
        for obj_file in "${ASSETS_SOURCE}"/meshes/*.obj; do
            echo "  Converting $(basename "$obj_file")..."
            "${ASSET_TOOL_BIN}" mesh "$obj_file" -o "${ASSETS_COMPILED}/meshes" || echo "  Warning: mesh conversion not yet implemented"
        done
    fi

    # Convert textures (.png → .rs + .bin)
    if ls "${ASSETS_SOURCE}"/textures/*.png 1> /dev/null 2>&1; then
        for png_file in "${ASSETS_SOURCE}"/textures/*.png; do
            echo "  Converting $(basename "$png_file")..."
            "${ASSET_TOOL_BIN}" texture "$png_file" -o "${ASSETS_COMPILED}/textures" || echo "  Warning: texture conversion not yet implemented"
        done
    fi

    # Copy generated .rs files to firmware assets folder
    if ls "${ASSETS_COMPILED}"/meshes/*.rs 1> /dev/null 2>&1; then
        cp "${ASSETS_COMPILED}"/meshes/*.rs "${HOST_APP_ASSETS}/" 2>/dev/null || true
    fi
    if ls "${ASSETS_COMPILED}"/textures/*.rs 1> /dev/null 2>&1; then
        cp "${ASSETS_COMPILED}"/textures/*.rs "${HOST_APP_ASSETS}/" 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Assets processed${NC}"
    echo ""
fi

# Step 3: Build RP2350 firmware
if [ "$BUILD_FIRMWARE" = true ]; then
    echo -e "${YELLOW}[3/5] Building RP2350 firmware...${NC}"
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

# Step 4: Build FPGA bitstream
if [ "$BUILD_FPGA" = true ]; then
    echo -e "${YELLOW}[4/5] Building FPGA bitstream...${NC}"
    cd "${SPI_GPU}"
    make clean
    make bitstream
    FPGA_BITSTREAM="${SPI_GPU}/build/gpu_top.bit"
    echo -e "${GREEN}✓ Bitstream built: ${FPGA_BITSTREAM}${NC}"
    echo ""
fi

# Step 5: Copy outputs to unified build directory
echo -e "${YELLOW}[5/5] Collecting build outputs...${NC}"
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
