param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$serverPath = Join-Path $PSScriptRoot 'server.py'
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Coremail MCP server not found: $serverPath")
    exit 1
}
$versionProbePath = Join-Path $PSScriptRoot 'check-python.py'
if (-not (Test-Path -LiteralPath $versionProbePath -PathType Leaf)) {
    [Console]::Error.WriteLine("Coremail Python version probe not found: $versionProbePath")
    exit 1
}

$pythonCommand = $null
$pythonPrefix = @()

if (-not [string]::IsNullOrWhiteSpace($env:COREMAIL_PYTHON)) {
    try {
        $pythonCommand = (Get-Command $env:COREMAIL_PYTHON -ErrorAction Stop).Source
    }
    catch {
        [Console]::Error.WriteLine("COREMAIL_PYTHON cannot be resolved: $($env:COREMAIL_PYTHON)")
        exit 1
    }
}
else {
    $launcher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($null -ne $launcher) {
        $pythonCommand = $launcher.Source
        $pythonPrefix = @('-3')
    }
    else {
        foreach ($name in @('python.exe', 'python3.exe', 'python', 'python3')) {
            $candidate = Get-Command $name -ErrorAction SilentlyContinue
            if ($null -ne $candidate) {
                $pythonCommand = $candidate.Source
                break
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($pythonCommand)) {
    [Console]::Error.WriteLine(
        'Python 3.10 or newer was not found. Install Python for the current user or set COREMAIL_PYTHON to python.exe.'
    )
    exit 1
}

& $pythonCommand @pythonPrefix -I $versionProbePath
$versionProbeExitCode = $LASTEXITCODE
if ($versionProbeExitCode -eq 10) {
    [Console]::Error.WriteLine('Python 3.10 or newer is required by the selected interpreter.')
    exit 1
}
if ($versionProbeExitCode -ne 0) {
    [Console]::Error.WriteLine(
        "Unable to validate the selected Python interpreter (probe exit code $versionProbeExitCode): $pythonCommand"
    )
    exit 1
}

& $pythonCommand @pythonPrefix -I $serverPath
exit $LASTEXITCODE
