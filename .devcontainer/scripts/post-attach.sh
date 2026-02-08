#!/bin/bash
set -e

echo "=== syskit Post-Attach Setup ==="

# Always install/update syskit to ensure latest version
echo "  Installing syskit..."
cd /workspaces/pico-gs
bash /opt/syskit-installer.sh
echo "  syskit installed successfully"

echo "=== Post-Attach Setup Complete ==="
