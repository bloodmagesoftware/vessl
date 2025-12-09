#!/bin/bash
# Script to build libvterm static libraries for various architectures
# Requires: git, make, zig (for cross-compilation)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="/tmp/libvterm-build-$(date +%s)"
VTERM_REPO="https://github.com/neovim/libvterm.git"

echo "Building libvterm libraries..."
echo "Temp dir: $TEMP_DIR"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# Clone libvterm
echo "Cloning libvterm..."
git clone --depth 1 "$VTERM_REPO" libvterm
cd libvterm

# Function to build for the current platform
build_native() {
    OUTPUT_DIR=$1
    
    echo "Building native library..."
    make clean 2>/dev/null || true
    make
    
    mkdir -p "$SCRIPT_DIR/$OUTPUT_DIR"
    cp .libs/libvterm.a "$SCRIPT_DIR/$OUTPUT_DIR/"
    
    echo "Built: $SCRIPT_DIR/$OUTPUT_DIR/libvterm.a"
}

# Function to cross-compile with zig
build_with_zig() {
    TARGET=$1
    OUTPUT_DIR=$2
    
    echo "Building for $TARGET (cross-compilation)..."
    
    # Clean previous build
    make clean 2>/dev/null || true
    
    # Set CC to zig cc with target
    CC="zig cc -target $TARGET" make
    
    mkdir -p "$SCRIPT_DIR/$OUTPUT_DIR"
    cp .libs/libvterm.a "$SCRIPT_DIR/$OUTPUT_DIR/"
    
    echo "Built: $SCRIPT_DIR/$OUTPUT_DIR/libvterm.a"
}

# Detect current platform and build native
case "$(uname -s)" in
    Darwin)
        case "$(uname -m)" in
            arm64)
                build_native "macos-arm64"
                ;;
            x86_64)
                build_native "macos-amd64"
                ;;
        esac
        ;;
    Linux)
        case "$(uname -m)" in
            aarch64)
                build_native "linux-arm64"
                ;;
            x86_64)
                build_native "linux-amd64"
                ;;
        esac
        ;;
esac

# If zig is available, try cross-compilation
if command -v zig &> /dev/null; then
    echo ""
    echo "Zig found - attempting cross-compilation..."
    
    # Only cross-compile for platforms we're not on
    case "$(uname -s)" in
        Darwin)
            # Cross-compile for Linux
            build_with_zig "x86_64-linux-gnu" "linux-amd64" 2>/dev/null || echo "Linux amd64 cross-compile failed (may need glibc headers)"
            build_with_zig "aarch64-linux-gnu" "linux-arm64" 2>/dev/null || echo "Linux arm64 cross-compile failed"
            
            # Cross-compile for other macOS arch
            if [ "$(uname -m)" = "arm64" ]; then
                build_with_zig "x86_64-macos" "macos-amd64" 2>/dev/null || echo "macOS amd64 cross-compile failed"
            else
                build_with_zig "aarch64-macos" "macos-arm64" 2>/dev/null || echo "macOS arm64 cross-compile failed"
            fi
            ;;
        Linux)
            # Cross-compile for macOS (usually fails without SDK)
            echo "Note: Cross-compiling for macOS from Linux typically requires the macOS SDK"
            
            # Cross-compile for other Linux arch
            if [ "$(uname -m)" = "x86_64" ]; then
                build_with_zig "aarch64-linux-gnu" "linux-arm64" 2>/dev/null || echo "Linux arm64 cross-compile failed"
            else
                build_with_zig "x86_64-linux-gnu" "linux-amd64" 2>/dev/null || echo "Linux amd64 cross-compile failed"
            fi
            ;;
    esac
else
    echo ""
    echo "Note: Install 'zig' for cross-compilation support"
fi

# Note about Windows
echo ""
echo "Note: Windows build requires running this script on Windows with MSVC or MinGW"
echo "Windows libraries should be placed in: $SCRIPT_DIR/windows-amd64/vterm.lib"

# Clean up
cd "$SCRIPT_DIR"
rm -rf "$TEMP_DIR"

echo ""
echo "Build complete! Check the output directories for library files."
echo ""
echo "Expected files:"
echo "  - macos-arm64/libvterm.a"
echo "  - macos-amd64/libvterm.a"
echo "  - linux-amd64/libvterm.a"
echo "  - linux-arm64/libvterm.a"
echo "  - windows-amd64/vterm.lib (must be built on Windows)"

