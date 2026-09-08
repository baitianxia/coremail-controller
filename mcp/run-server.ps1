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
            throw "Mail MCP runtime file not found: $required"
        }
    }

    try {
        $runtime = Get-Content -LiteralPath $runtimePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Mail Python runtime descriptor is invalid: $($_.Exception.Message)"
    }
    if ([int]$runtime.schema_version -ne 1 -or [string]$runtime.kind -ne 'python' -or
        -not [bool]$runtime.bundled -or [int]$runtime.pointer_bits -ne 64) {
        throw 'Unsupported mail Python runtime descriptor schema.'
    }
    if ([string]$runtime.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        $null -eq $runtime.PSObject.Properties['version_info'] -or
        @($runtime.version_info).Count -lt 3 -or
        [int]$runtime.version_info[0] -ne [int](([string]$runtime.version).Split('.')[0]) -or
        [int]$runtime.version_info[1] -ne [int](([string]$runtime.version).Split('.')[1]) -or
        [int]$runtime.version_info[2] -ne [int](([string]$runtime.version).Split('.')[2])) {
        throw 'The mail Python runtime descriptor has an invalid version record.'
    }
    $pythonExecutable = [IO.Path]::GetFullPath([string]$runtime.executable)
    if (-not (Test-Path -LiteralPath $pythonExecutable -PathType Leaf)) {
        throw "The Python executable selected during installation is no longer available: $pythonExecutable"
    }
    $pythonItem = Get-Item -LiteralPath $pythonExecutable -Force -ErrorAction Stop
    if (($pythonItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The pinned Python executable is a link or junction.'
    }
    $expectedBundledExecutable = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\payload\runtime\python.exe'))
    if (-not [string]::Equals($pythonExecutable, $expectedBundledExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The mail MCP descriptor does not point to the package-bundled Windows x64 runtime.'
    }
    $expectedHash = [string]$runtime.executable_sha256
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The mail Python runtime descriptor has an invalid executable hash.'
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
