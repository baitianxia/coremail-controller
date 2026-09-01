#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipConnectionCheck,
    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$commonScript = Join-Path $PSScriptRoot 'windows-lifecycle-common.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    throw 'The Coremail lifecycle support script is missing.'
}
. $commonScript

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDirectory = Join-Path ([IO.Path]::GetTempPath()) 'CoremailController'
    $LogPath = Join-Path $logDirectory (
        'CONFIGURE-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'
    )
}
Initialize-CoremailLifecycleLog -Path $LogPath

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Coremail account configuration can run only on Windows.'
    }

    $localRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $installedRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude\skills\coremail-controller'
    if (Test-Path -LiteralPath (Join-Path $installedRoot 'scripts\setup-account.ps1') -PathType Leaf) {
        $pluginRoot = $installedRoot
    }
    else {
        $pluginRoot = $localRoot
    }

    $setupScript = Join-Path $pluginRoot 'scripts\setup-account.ps1'
    $smokeTest = Join-Path $pluginRoot 'tests\smoke-mcp.ps1'
    if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
        throw "Account setup script not found: $setupScript"
    }
    if (-not (Test-Path -LiteralPath $smokeTest -PathType Leaf)) {
        throw "MCP verification script not found: $smokeTest"
    }

    & $setupScript -LogPath $LogPath
    & $smokeTest
    if (-not $SkipConnectionCheck) {
        try {
            & $smokeTest -TimeoutMilliseconds 60000 -CheckConnection
        }
        catch {
            Write-Warning "Account settings were saved, but the live connection check did not pass: $($_.Exception.Message)"
            Write-Warning 'For interface mode, keep Coremail logged in and check its MAPI registration/bitness. For protocol mode, review server addresses, password, network access, and administrator policy.'
        }
    }

    Write-Host ''
    Write-Host 'Coremail account configuration completed.' -ForegroundColor Green
    Write-Host "Diagnostic log: $LogPath"
    Write-Host 'Restart Claude Code or run /reload-plugins, then ask Claude to check the Coremail connection.'
    exit 0
}
catch {
    Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'account configuration launcher'
    Write-Host ''
    Write-Host "Account configuration stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Diagnostic log: $LogPath"
    exit 1
}
