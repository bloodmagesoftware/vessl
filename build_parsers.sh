#!/bin/bash
set -e

# Build tree-sitter and all language parsers
# This script should be run from the repository root

cd "$(dirname "$0")/vendor/odin-tree-sitter"

echo "=== Installing tree-sitter ==="
odin run build -- install -clean

echo "=== Installing Odin parser ==="
odin run build -- install-parser -parser:https://github.com/tree-sitter-grammars/tree-sitter-odin -yes

echo "=== Installing C parser ==="
odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-c -yes

echo "=== Installing C++ parser ==="
odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-cpp -yes

echo "=== Installing JavaScript parser ==="
odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-javascript -yes

echo "=== Installing Go parser ==="
odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-go -yes

echo "=== Installing TypeScript parser ==="
odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-typescript -path:typescript -yes

echo "=== Installing TSX parser ==="
odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-typescript -path:tsx -name:tsx -yes

echo "=== All parsers installed successfully ==="

