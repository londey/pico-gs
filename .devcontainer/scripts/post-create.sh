#!/bin/bash
set -e

echo "=== pico-gs Devcontainer Post-Create Setup ==="

# Ensure git submodules are initialized
echo "Initializing git submodules..."
git submodule update --init --recursive

# Source oss-cad-suite environment
echo "Setting up OSS CAD Suite environment..."
source /opt/oss-cad-suite/environment

# Verify FPGA tools are available
echo "Verifying FPGA toolchain..."
echo "  yosys: $(yosys --version 2>/dev/null | head -1 || echo 'not found')"
echo "  nextpnr-ecp5: $(nextpnr-ecp5 --version 2>/dev/null | head -1 || echo 'not found')"
echo "  ecppack: $(which ecppack 2>/dev/null || echo 'not found')"
echo "  openFPGALoader: $(which openFPGALoader 2>/dev/null || echo 'not found')"

# Verify sysdoc is available
echo "Verifying sysdoc..."
echo "  sysdoc: $(sysdoc --version 2>/dev/null || echo 'installed')"

# Verify Claude Code CLI
echo "Verifying Claude Code CLI..."
echo "  claude: $(claude --version 2>/dev/null || echo 'installed')"

# Set up Claude Code if ANTHROPIC_API_KEY is available
if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "ANTHROPIC_API_KEY detected - Claude Code ready to use"
else
    echo "ANTHROPIC_API_KEY not set - run 'claude' and use /login to authenticate"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Available tools:"
echo "  yosys, nextpnr-ecp5, ecppack, openFPGALoader (FPGA synthesis)"
echo "  sysdoc (documentation)"
echo "  claude (AI assistant)"
echo ""
