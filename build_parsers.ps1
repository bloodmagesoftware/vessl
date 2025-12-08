# Build tree-sitter and all language parsers
# This script should be run from the repository root
# On Windows, run this from the Developer Command Prompt bundled with Visual Studio

$ErrorActionPreference = "Stop"

Push-Location "$PSScriptRoot\vendor\odin-tree-sitter"

try {
    Write-Host "=== Installing tree-sitter ===" -ForegroundColor Cyan
    odin run build -- install -clean
    if ($LASTEXITCODE -ne 0) { throw "Failed to install tree-sitter" }

    Write-Host "=== Pre-compiling build tool for parallel use ===" -ForegroundColor Cyan
    odin build build -out:build.exe
    if ($LASTEXITCODE -ne 0) { throw "Failed to compile build tool" }

    Write-Host "=== Installing parsers in parallel ===" -ForegroundColor Cyan

    # Define parsers to install (using pre-compiled binary)
    $parsers = @(
        @{ Name = "Odin"; Args = @("install-parser", "-parser:https://github.com/tree-sitter-grammars/tree-sitter-odin", "-yes") }
        @{ Name = "C"; Args = @("install-parser", "-parser:https://github.com/tree-sitter/tree-sitter-c", "-yes") }
        @{ Name = "C++"; Args = @("install-parser", "-parser:https://github.com/tree-sitter/tree-sitter-cpp", "-yes") }
        @{ Name = "JavaScript"; Args = @("install-parser", "-parser:https://github.com/tree-sitter/tree-sitter-javascript", "-yes") }
        @{ Name = "Go"; Args = @("install-parser", "-parser:https://github.com/tree-sitter/tree-sitter-go", "-yes") }
        @{ Name = "TypeScript"; Args = @("install-parser", "-parser:https://github.com/tree-sitter/tree-sitter-typescript", "-path:typescript", "-yes") }
        @{ Name = "TSX"; Args = @("install-parser", "-parser:https://github.com/tree-sitter/tree-sitter-typescript", "-path:tsx", "-name:tsx", "-yes") }
    )

    # Start all parser installs as background jobs
    $jobs = @()
    $buildExe = Join-Path (Get-Location) "build.exe"
    foreach ($parser in $parsers) {
        Write-Host "Starting: $($parser.Name) parser..." -ForegroundColor Yellow
        $job = Start-Job -ScriptBlock {
            param($exe, $argList)
            & $exe $argList 2>&1 | Out-Null
            return $LASTEXITCODE
        } -ArgumentList $buildExe, $parser.Args
        $jobs += @{ Job = $job; Name = $parser.Name }
    }

    # Wait for all jobs and collect results
    $failed = $false
    foreach ($jobInfo in $jobs) {
        $result = Receive-Job -Job $jobInfo.Job -Wait
        Remove-Job -Job $jobInfo.Job
        if ($result -eq 0) {
            Write-Host "✓ $($jobInfo.Name) parser installed successfully" -ForegroundColor Green
        } else {
            Write-Host "✗ $($jobInfo.Name) parser failed to install" -ForegroundColor Red
            $failed = $true
        }
    }

    # Clean up the pre-compiled binary
    Remove-Item -Force -ErrorAction SilentlyContinue "build.exe"

    if ($failed) {
        throw "Some parsers failed to install"
    }

    Write-Host "=== All parsers installed successfully ===" -ForegroundColor Green
}
finally {
    Pop-Location
}
