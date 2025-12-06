#!/bin/bash
# Script to rebuild Clay static libraries for various architectures
# Requires: zig, curl

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAY_H_URL="https://raw.githubusercontent.com/nicbarker/clay/main/clay.h"
TEMP_DIR="/tmp/clay-build-$(date +%s)"

echo "Rebuilding Clay libraries..."
echo "Temp dir: $TEMP_DIR"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# Download clay.h
echo "Downloading clay.h..."
curl -s -o clay.h "$CLAY_H_URL"

# Create implementation file
echo "#define CLAY_IMPLEMENTATION" > clay_impl.c
echo "#include \"clay.h\"" >> clay_impl.c

# Check for zig
if ! command -v zig &> /dev/null; then
    echo "Error: 'zig' is required to build cross-platform libraries."
    exit 1
fi

# Function to build
build_lib() {
    TARGET=$1
    OUTPUT_DIR=$2
    OUTPUT_FILE=$3
    FORMAT=$4 # "a" or "lib"

    echo "Building for $TARGET..."
    mkdir -p "$SCRIPT_DIR/$OUTPUT_DIR"
    
    # Compile object file
    zig cc -target $TARGET -c clay_impl.c -o clay.o
    
    # Create archive
    # Note: 'zig ar' wraps llvm-ar, which can handle both formats
    zig ar rcs "$SCRIPT_DIR/$OUTPUT_DIR/$OUTPUT_FILE" clay.o
    
    rm clay.o
}

# Build for supported targets
# Directory naming: {os}-{arch} where arch is amd64 or arm64

# Linux AMD64
build_lib "x86_64-linux-gnu" "linux-amd64" "clay.a" "a"

# Linux ARM64
build_lib "aarch64-linux-gnu" "linux-arm64" "clay.a" "a"

# Windows AMD64 (MSVC)
build_lib "x86_64-windows-msvc" "windows-amd64" "clay.lib" "lib"

# Windows ARM64 (MSVC)
build_lib "aarch64-windows-msvc" "windows-arm64" "clay.lib" "lib"

# macOS AMD64
build_lib "x86_64-macos" "macos-amd64" "clay.a" "a"

# macOS ARM64
build_lib "aarch64-macos" "macos-arm64" "clay.a" "a"

# Clean up
cd "$SCRIPT_DIR"
rm -rf "$TEMP_DIR"

echo "✅ Libraries rebuilt successfully!"

