#!/bin/bash
set -e

echo "=== syskit Post-Attach Setup ==="

# Download and install latest syskit from master branch
echo "  Installing latest syskit..."
cd /workspaces/pico-gs
curl -fsSL https://raw.githubusercontent.com/londey/syskit/refs/heads/master/install_syskit.sh | bash
echo "  syskit installed successfully"

echo "=== Post-Attach Setup Complete ==="
