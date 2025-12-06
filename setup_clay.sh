#!/bin/bash
# Setup script for Clay Odin bindings
# This script downloads the official Clay Odin bindings and places them in vendor/clay-odin/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAY_DIR="$SCRIPT_DIR/vendor/clay-odin"
TEMP_DIR="/tmp/clay-$(date +%s)"

echo "Setting up Clay Odin bindings..."
echo "Target directory: $CLAY_DIR"

# Create vendor directory if it doesn't exist
mkdir -p "$CLAY_DIR"

# Clone Clay repository (sparse checkout to only get what we need)
echo "Cloning Clay repository..."
git clone --depth 1 --filter=blob:none --sparse https://github.com/nicbarker/clay.git "$TEMP_DIR"
cd "$TEMP_DIR"
git sparse-checkout set bindings/odin/clay-odin

# Check if bindings directory exists
if [ ! -d "bindings/odin/clay-odin" ]; then
    echo "Error: Clay bindings directory not found!"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Copy bindings to vendor directory
echo "Copying bindings to $CLAY_DIR..."
cp -r bindings/odin/clay-odin/* "$CLAY_DIR/"

# Clean up
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

echo "✅ Clay Odin bindings installed successfully!"
echo ""
echo "You can now import Clay in your Odin code with:"
echo "  import clay \"vendor/clay-odin\""
echo ""
echo "Note: Files in vendor/clay-odin/ should never be manually modified."

