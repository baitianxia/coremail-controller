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
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = [string]$env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'The current Windows LocalAppData directory could not be resolved.' }
    $runtimeRoot = $null
    $userConfig = Resolve-CoremailClaudeUserConfigPath -UserProfile ([Environment]::GetFolderPath('UserProfile'))
    if (Test-Path -LiteralPath $userConfig -PathType Leaf) {
        try {
            $payload = Get-Content -LiteralPath $userConfig -Raw | ConvertFrom-Json
            $servers = $payload.PSObject.Properties['mcpServers']
            $entry = $null
            if ($null -ne $servers -and $null -ne $servers.Value) {
                $entry = $servers.Value.PSObject.Properties['coremail-controller']
            }
            if ($null -ne $entry -and $null -ne $entry.Value) {
                $args = @($entry.Value.args | ForEach-Object { [string]$_ })
                for ($index = 0; $index -lt $args.Count - 1; $index++) {
                    if ($args[$index] -ieq '-File') {
                        $runtimeRoot = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $args[$index + 1])))
                        break
                    }
                }
            }
        }
        catch { $runtimeRoot = $null }
    }
    $releaseRoot = Join-Path ([IO.Path]::GetFullPath($localAppData)) 'CoremailController\releases'
    if ($runtimeRoot -and
        $runtimeRoot.StartsWith(([IO.Path]::GetFullPath($localAppData)).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath (Join-Path $runtimeRoot 'scripts\setup-account.ps1') -PathType Leaf)) {
        $pluginRoot = $runtimeRoot
    }
    elseif (Test-Path -LiteralPath $releaseRoot -PathType Container) {
        $candidateRelease = Get-ChildItem -LiteralPath $releaseRoot -Directory |
            Where-Object { $_.Name -like 'coremail-controller-*' } |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($null -ne $candidateRelease) { $pluginRoot = $candidateRelease.FullName }
        else { $pluginRoot = $localRoot }
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
    if (-not $?) { throw 'Installed MCP smoke test failed.' }
    if (-not $SkipConnectionCheck) {
        try {
            & $smokeTest -TimeoutMilliseconds 60000 -CheckConnection
            if (-not $?) { throw 'Live Coremail connection smoke test failed.' }
        }
        catch {
            Write-Warning "Account settings were saved, but the live connection check did not pass: $($_.Exception.Message)"
            Write-Warning 'For interface mode, keep Coremail logged in and check its MAPI registration/bitness. For protocol mode, review server addresses, password, network access, and administrator policy.'
        }
    }

    Write-Host ''
    Write-Host 'Coremail account configuration completed.' -ForegroundColor Green
    Write-Host "Diagnostic log: $LogPath"
    Write-Host 'Restart Claude Code, then ask Claude to check the Coremail connection.'
    exit 0
}
catch {
    Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'account configuration launcher'
    Write-Host ''
    Write-Host "Account configuration stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Diagnostic log: $LogPath"
    exit 1
}
