# ==============================================================================
# AMNESIAX — Windows Host Simulation & Acceptance Runner (PowerShell)
# ==============================================================================
[CmdletBinding()]
param (
    [switch]$SimulateCrashOnly
)

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  AMNESIAX Isolation & Leak-Prevention Host Simulation Harness" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

$AppVmScript = Join-Path $PSScriptRoot "..\appvm\leak_test.py"
$PythonExe = (Get-Command python.exe -ErrorAction SilentlyContinue).Source

if (-not $PythonExe) {
    Write-Warning "Python 3 was not found in PATH. Please ensure Python is installed."
    exit 1
}

if ($SimulateCrashOnly) {
    Write-Host "[*] Executing Fail-Closed Crash State Verification..." -ForegroundColor Yellow
    & $PythonExe $AppVmScript --simulate-crash
} else {
    Write-Host "[*] Executing Standard AMNESIAX Network Boundary Checks..." -ForegroundColor Green
    & $PythonExe $AppVmScript

    Write-Host "`n[*] Executing Fail-Closed State Simulation (Tor Daemon Halt)..." -ForegroundColor Yellow
    & $PythonExe $AppVmScript --simulate-crash
}
