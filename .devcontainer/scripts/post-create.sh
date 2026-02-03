#!/bin/bash
set -e

echo "=== pico-gs Devcontainer Post-Create Setup ==="

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

# Verify spec-kit is available
echo "Verifying spec-kit..."
if command -v specify &> /dev/null; then
    echo "  specify: $(specify --version 2>/dev/null || echo 'installed')"

    # Initialize spec-kit for the project if not already initialized
    if [ ! -d "/workspaces/pico-gs/.specify" ]; then
        echo "Initializing spec-kit for pico-gs..."
        cd /workspaces/pico-gs
        specify init --here --ai claude || echo "  (manual initialization may be needed)"
    else
        echo "  spec-kit already initialized"
    fi
else
    echo "  specify: not found (install with: uv tool install specify-cli --from git+https://github.com/github/spec-kit.git)"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Available tools:"
echo "  yosys, nextpnr-ecp5, ecppack, openFPGALoader (FPGA synthesis)"
echo "  sysdoc (documentation)"
echo "  claude (AI assistant)"
echo "  specify (spec-driven development)"
echo ""
