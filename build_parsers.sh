#!/bin/bash
set -e

# Build tree-sitter and all language parsers
# This script should be run from the repository root

cd "$(dirname "$0")/vendor/odin-tree-sitter"

echo "=== Installing tree-sitter ==="
odin run build -- install -clean

echo "=== Pre-compiling build tool for parallel use ==="
odin build build -out:build.bin

echo "=== Installing parsers in parallel ==="

# Array of parser install commands (using pre-compiled binary)
declare -a parsers=(
    "Odin:./build.bin install-parser -parser:https://github.com/tree-sitter-grammars/tree-sitter-odin -yes"
    "C:./build.bin install-parser -parser:https://github.com/tree-sitter/tree-sitter-c -yes"
    "C++:./build.bin install-parser -parser:https://github.com/tree-sitter/tree-sitter-cpp -yes"
    "JavaScript:./build.bin install-parser -parser:https://github.com/tree-sitter/tree-sitter-javascript -yes"
    "Go:./build.bin install-parser -parser:https://github.com/tree-sitter/tree-sitter-go -yes"
    "TypeScript:./build.bin install-parser -parser:https://github.com/tree-sitter/tree-sitter-typescript -path:typescript -yes"
    "TSX:./build.bin install-parser -parser:https://github.com/tree-sitter/tree-sitter-typescript -path:tsx -name:tsx -yes"
)

# Track background job PIDs and their names
declare -a pids=()
declare -a names=()

# Start all parser installs in parallel
for entry in "${parsers[@]}"; do
    name="${entry%%:*}"
    cmd="${entry#*:}"
    echo "Starting: $name parser..."
    $cmd &
    pids+=($!)
    names+=("$name")
done

# Wait for all jobs and collect results
failed=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        echo "✓ ${names[$i]} parser installed successfully"
    else
        echo "✗ ${names[$i]} parser failed to install"
        failed=1
    fi
done

# Clean up the pre-compiled binary
rm -f build.bin

if [ $failed -eq 0 ]; then
    echo "=== All parsers installed successfully ==="
else
    echo "=== Some parsers failed to install ==="
    exit 1
fi
