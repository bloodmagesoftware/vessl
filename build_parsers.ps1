# Build tree-sitter and all language parsers
# This script should be run from the repository root
# On Windows, run this from the Developer Command Prompt bundled with Visual Studio

$ErrorActionPreference = "Stop"

Push-Location "$PSScriptRoot\vendor\odin-tree-sitter"

try {
    Write-Host "=== Installing tree-sitter ===" -ForegroundColor Cyan
    odin run build -- install -clean
    if ($LASTEXITCODE -ne 0) { throw "Failed to install tree-sitter" }

    Write-Host "=== Installing Odin parser ===" -ForegroundColor Cyan
    odin run build -- install-parser -parser:https://github.com/tree-sitter-grammars/tree-sitter-odin -yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to install Odin parser" }

    Write-Host "=== Installing C parser ===" -ForegroundColor Cyan
    odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-c -yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to install C parser" }

    Write-Host "=== Installing C++ parser ===" -ForegroundColor Cyan
    odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-cpp -yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to install C++ parser" }

    Write-Host "=== Installing JavaScript parser ===" -ForegroundColor Cyan
    odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-javascript -yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to install JavaScript parser" }

    Write-Host "=== Installing Go parser ===" -ForegroundColor Cyan
    odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-go -yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to install Go parser" }

    Write-Host "=== Installing TypeScript parser ===" -ForegroundColor Cyan
    odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-typescript -path:typescript -yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to install TypeScript parser" }

    Write-Host "=== Installing TSX parser ===" -ForegroundColor Cyan
    odin run build -- install-parser -parser:https://github.com/tree-sitter/tree-sitter-typescript -path:tsx -name:tsx -yes
    if ($LASTEXITCODE -ne 0) { throw "Failed to install TSX parser" }

    Write-Host "=== All parsers installed successfully ===" -ForegroundColor Green
}
finally {
    Pop-Location
}

