#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    $serverPath = Join-Path $PSScriptRoot 'server.py'
    $probePath = Join-Path $PSScriptRoot 'check-python.py'
    $runtimePath = Join-Path $PSScriptRoot 'python-runtime.json'
    foreach ($required in @($serverPath, $probePath, $runtimePath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Coremail MCP runtime file not found: $required"
        }
    }

    try {
        $runtime = Get-Content -LiteralPath $runtimePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Coremail Python runtime descriptor is invalid: $($_.Exception.Message)"
    }
    if ([int]$runtime.schema_version -ne 1) {
        throw 'Unsupported Coremail Python runtime descriptor schema.'
    }
    $pythonExecutable = [IO.Path]::GetFullPath([string]$runtime.executable)
    if (-not (Test-Path -LiteralPath $pythonExecutable -PathType Leaf)) {
        throw "The Python executable selected during installation is no longer available: $pythonExecutable"
    }
    $expectedHash = [string]$runtime.executable_sha256
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The Coremail Python runtime descriptor has an invalid executable hash.'
    }
    $actualHash = (Get-FileHash -LiteralPath $pythonExecutable -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) {
        throw 'The Python executable selected during installation changed. Run INSTALL.cmd again to revalidate and pin the runtime.'
    }
    & $pythonExecutable -B -I $probePath
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -eq 10) {
        throw 'Python 3.10 or newer is required by the pinned interpreter.'
    }
    if ($probeExitCode -ne 0) {
        throw "Unable to validate the pinned Python interpreter (exit code $probeExitCode)."
    }

    & $pythonExecutable -B -I $serverPath
    exit $LASTEXITCODE
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
