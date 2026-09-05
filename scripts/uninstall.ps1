#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PythonExecutable = '',
    [string]$ClaudeCommand = '',
    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$commonScript = Join-Path $PSScriptRoot 'windows-lifecycle-common.ps1'
$discoveryScript = Join-Path $PSScriptRoot 'windows-tool-discovery.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf) -or
    -not (Test-Path -LiteralPath $discoveryScript -PathType Leaf)) {
    throw 'The Coremail lifecycle support scripts are missing.'
}
. $commonScript
. $discoveryScript

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDirectory = Join-Path ([IO.Path]::GetTempPath()) 'CoremailController'
    $LogPath = Join-Path $logDirectory (
        'UNINSTALL-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'
    )
}
Initialize-CoremailLifecycleLog -Path $LogPath

$mcpServerName = 'coremail-controller'
$userProfile = $null
$localAppData = $null
$agentRoot = $null
$lockPath = $null
$lockStream = $null
$claudeUserConfigPath = $null
$snapshotDirectory = $null
$claudeUserConfigSnapshot = $null
$configMutationStarted = $false
$uninstallCommitted = $false
$claudeInvocation = $null
$pythonRuntime = $null
$registeredRuntime = $null

function Get-CoremailUserMcpEntry {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }
    try { $payload = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { throw "Claude user configuration is not valid JSON: $ConfigPath" }
    $serversProperty = $payload.PSObject.Properties['mcpServers']
    if ($null -eq $serversProperty -or $null -eq $serversProperty.Value) { return $null }
    $entryProperty = $serversProperty.Value.PSObject.Properties[$mcpServerName]
    if ($null -eq $entryProperty -or $null -eq $entryProperty.Value) { return $null }
    return $entryProperty.Value
}

function Get-CoremailRegisteredRuntimeHint {
    param([Parameter(Mandatory = $true)][object]$Entry)
    try {
        $argsProperty = $Entry.PSObject.Properties['args']
        if ($null -eq $argsProperty -or $null -eq $argsProperty.Value) { return $null }
        $arguments = @($argsProperty.Value | ForEach-Object { [string]$_ })
        for ($index = 0; $index -lt $arguments.Count - 1; $index++) {
            if ([string]::Equals($arguments[$index], '-File', [StringComparison]::OrdinalIgnoreCase)) {
                $scriptPath = [IO.Path]::GetFullPath($arguments[$index + 1])
                return [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $scriptPath)))
            }
        }
    }
    catch { return $null }
    return $null
}

function Invoke-CoremailUserMcpRemoval {
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    $registrar = Join-Path $sourceRoot 'scripts\register_claude_user_mcp.py'
    if (-not (Test-Path -LiteralPath $registrar -PathType Leaf)) { throw "The Coremail MCP registrar is missing: $registrar" }
    $arguments = @(
        '-B', '-I', $registrar, 'unregister',
        '--claude-executable', [string]$claudeInvocation.Executable,
        '--server-name', $mcpServerName,
        '--user-config', $claudeUserConfigPath,
        '--backup', $BackupPath
    )
    foreach ($prefix in @($claudeInvocation.Prefix)) { $arguments += @('--claude-prefix', [string]$prefix) }
    Invoke-CoremailExternalChecked -Executable ([string]$pythonRuntime.Executable) -Prefix @($pythonRuntime.Prefix) -Arguments $arguments `
        -Label 'Claude user-scope MCP removal'
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This uninstaller can run only on Windows.' }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'The current Windows user profile directory could not be resolved.' }
    $claudeUserConfigPath = Resolve-CoremailClaudeUserConfigPath -UserProfile $userProfile
    $entry = Get-CoremailUserMcpEntry -ConfigPath $claudeUserConfigPath
    if ($null -eq $entry) {
        Write-CoremailLifecycleLog 'UNINSTALL no active Coremail user-scope MCP entry found'
        Write-Host 'Coremail Controller is already removed from Claude user scope.'
        Write-Host 'No runtime or account data was changed.'
        Write-Host "Diagnostic log: $LogPath"
        exit 0
    }
    $registeredRuntime = Get-CoremailRegisteredRuntimeHint -Entry $entry
    Write-CoremailLifecycleLog "UNINSTALL registration found config=$claudeUserConfigPath; runtime_hint=$registeredRuntime"

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = [string]$env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'The current Windows LocalAppData directory could not be resolved.' }
    [void](Assert-CoremailSafeLocalPath -Path $localAppData -Label 'LocalAppData')
    $agentRoot = Join-Path $localAppData 'CoremailController'
    $lockPath = Join-Path $agentRoot '.lifecycle.lock'
    [void](Assert-CoremailSafeDescendantPath -Root $localAppData -Path $agentRoot -Label 'Coremail lifecycle root')
    [void](Assert-CoremailSafeDescendantPath -Root $localAppData -Path $lockPath -Label 'Coremail lifecycle lock')
    $lockStream = Enter-CoremailLifecycleLock -Path $lockPath

    $candidateRuntime = Resolve-CoremailPythonCandidate -ExplicitPath $PythonExecutable
    if ($null -eq $candidateRuntime) { throw 'Python 3.10 or newer was not found; the user MCP entry was not changed.' }
    $pythonRuntime = [pscustomobject]@{ Executable = [IO.Path]::GetFullPath([string]$candidateRuntime.Executable); Prefix = @($candidateRuntime.Prefix) }
    $claudeInvocation = Resolve-ClaudeCodeInvocation -ExplicitPath $ClaudeCommand
    if ($null -eq $claudeInvocation) { throw 'Claude Code was not found; the user MCP entry was not changed.' }
    $claudeVersion = Get-CoremailClaudeVersion -Invocation $claudeInvocation -Label 'Claude Code version probe'
    Invoke-CoremailClaudeChecked -Invocation $claudeInvocation -Arguments @('mcp', '--help') `
        -Label 'Claude MCP capability probe' -QuietOnSuccess

    $snapshotDirectory = Join-Path ([IO.Path]::GetTempPath()) ('coremail-uninstall-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
    $claudeUserConfigSnapshot = Save-CoremailFileSnapshot -Path $claudeUserConfigPath -BackupDirectory $snapshotDirectory -Label 'claude-user-config'
    $configMutationStarted = $true
    Invoke-CoremailUserMcpRemoval -BackupPath (Join-Path $snapshotDirectory 'registrar.backup')
    $configMutationStarted = $false
    $uninstallCommitted = $true

    Write-Host ''
    Write-Host 'Coremail Controller has been removed from Claude user scope.' -ForegroundColor Green
    Write-Host 'The immutable runtime directories were retained; no files were deleted and no permission repair was attempted.'
    if ($registeredRuntime) { Write-Host "Retained runtime (if present): $registeredRuntime" }
    Write-Host 'Mailbox configuration and Windows Credential Manager entries were preserved.'
    Write-Host "Diagnostic log: $LogPath"
    exit 0
}
catch {
    $uninstallError = $_
    Write-CoremailLifecycleFailure -ErrorRecord $uninstallError -Context 'uninstall'
    if (-not $uninstallCommitted -and $configMutationStarted -and $null -ne $claudeUserConfigSnapshot) {
        try {
            Restore-CoremailFileSnapshot -Destination ([string]$claudeUserConfigSnapshot.Path) `
                -WasPresent ([bool]$claudeUserConfigSnapshot.WasPresent) -BackupPath ([string]$claudeUserConfigSnapshot.BackupPath)
            Write-CoremailLifecycleLog 'ROLLBACK restored Claude user MCP configuration'
        }
        catch { Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'uninstall user config rollback' }
    }
    Write-Host ''
    Write-Host "Uninstall stopped safely: $($uninstallError.Exception.Message)" -ForegroundColor Red
    Write-Host 'No runtime or mailbox data was deleted.'
    Write-Host "Diagnostic log: $LogPath"
    exit 1
}
finally {
    Exit-CoremailLifecycleLock -Stream $lockStream -Path $lockPath
    if ($snapshotDirectory -and (Test-Path -LiteralPath $snapshotDirectory -PathType Container)) {
        Remove-Item -LiteralPath $snapshotDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
