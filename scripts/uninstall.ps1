#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NoLegacyPermissionRepair,
    [string]$ClaudeCommand = '',
    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
$lockStream = $null
$lockPath = $null
$snapshotDirectory = $null
$targetRoot = $null
$claudeUserConfigPath = $null
$claudeUserConfigSnapshot = $null
$claudeUserConfigMutationStarted = $false
$uninstallCommitted = $false
$pythonRuntime = $null
$legacyPermissionRepairAttempted = $false

function Invoke-LegacyPermissionRepair {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$Root
    )

    if ($script:legacyPermissionRepairAttempted) {
        throw 'The one-time legacy permission repair completed, but access is still denied.'
    }
    $script:legacyPermissionRepairAttempted = $true
    Request-CoremailLegacyPluginPermissionRepair `
        -UserProfile $UserProfile `
        -TargetRoot $Root `
        -Disabled:$NoLegacyPermissionRepair
}

function Get-RecognizedCoremailPackage {
    param([Parameter(Mandatory = $true)][string]$Root)

    $manifestPath = Join-Path $Root '.claude-plugin\plugin.json'
    try { $manifestText = [IO.File]::ReadAllText($manifestPath) }
    catch [UnauthorizedAccessException] { throw }
    catch {
        if (Test-CoremailAccessDeniedError -ErrorRecord $_) { throw }
        throw "Refusing to move a package whose manifest is unavailable: $Root ($($_.Exception.Message))"
    }
    try { $manifest = $manifestText | ConvertFrom-Json }
    catch { throw "Refusing to move a package with an invalid manifest: $Root" }
    if ([string]$manifest.name -ne 'coremail-controller' -or
        [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
        throw 'Refusing to move a package with an unexpected identity or missing version.'
    }
    return $manifest
}

function Invoke-CoremailUserMcpRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$UserConfig,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )

    # During an upgrade the active target can still be a 0.7.x package, which
    # predates the user-scope registrar.  Prefer the verified package that
    # contains this uninstaller, then fall back to the active package for a
    # normal 0.8.x uninstall.
    $registrarCandidates = @(
        (Join-Path $PSScriptRoot 'register_claude_user_mcp.py'),
        (Join-Path $Root 'scripts\register_claude_user_mcp.py')
    )
    $registrar = $registrarCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$registrar)) {
        throw "The Coremail Claude MCP registrar is missing from the uninstall package and active target: $Root"
    }
    $arguments = @(
        '-B', '-I', $registrar, 'unregister',
        '--claude-executable', [string]$claudeInvocation.Executable,
        '--server-name', $mcpServerName,
        '--user-config', $UserConfig,
        '--backup', $BackupPath
    )
    foreach ($prefix in @($claudeInvocation.Prefix)) {
        $arguments += @('--claude-prefix', [string]$prefix)
    }
    $autoUpdaterWasPresent = Test-Path -LiteralPath 'Env:DISABLE_AUTOUPDATER'
    $updatesWerePresent = Test-Path -LiteralPath 'Env:DISABLE_UPDATES'
    $previousAutoUpdater = [string]$env:DISABLE_AUTOUPDATER
    $previousUpdates = [string]$env:DISABLE_UPDATES
    try {
        $env:DISABLE_AUTOUPDATER = '1'
        $env:DISABLE_UPDATES = '1'
        Invoke-CoremailExternalChecked `
            -Executable ([string]$pythonRuntime.Executable) `
            -Arguments $arguments `
            -Label 'Claude user-scope MCP removal'
    }
    finally {
        if ($autoUpdaterWasPresent) { $env:DISABLE_AUTOUPDATER = $previousAutoUpdater }
        else { Remove-Item Env:DISABLE_AUTOUPDATER -ErrorAction SilentlyContinue }
        if ($updatesWerePresent) { $env:DISABLE_UPDATES = $previousUpdates }
        else { Remove-Item Env:DISABLE_UPDATES -ErrorAction SilentlyContinue }
    }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This uninstaller is intended for Windows.'
    }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw 'The current Windows user profile directory could not be resolved.'
    }
    $claudeRoot = Join-Path $userProfile '.claude'
    $skillsRoot = Join-Path $claudeRoot 'skills'
    $targetRoot = Join-Path $skillsRoot 'coremail-controller'
    Write-CoremailLifecycleLog "UNINSTALL identity=$([Security.Principal.WindowsIdentity]::GetCurrent().Name); target=$targetRoot"
    [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $skillsRoot)

    $targetLookupDenied = $false
    try {
        $targetEntry = Get-CoremailExactChildDirectory `
            -Parent $skillsRoot `
            -Name 'coremail-controller'
    }
    catch {
        if (-not (Test-CoremailAccessDeniedError -ErrorRecord $_)) { throw }
        $targetLookupDenied = $true
    }
    if (-not $targetLookupDenied -and [string]::IsNullOrWhiteSpace([string]$targetEntry)) {
        Write-Host 'Coremail Controller is not installed in the personal skills directory.'
        Write-Host "Diagnostic log: $LogPath"
        Write-CoremailLifecycleLog 'UNINSTALL no active Coremail package found'
        exit 0
    }

    # Resolve the user MCP file only after confirming that there is an active
    # package.  A stale/invalid CLAUDE_CONFIG_DIR must not turn an idempotent
    # uninstall of an already absent package into a failure.
    $claudeUserConfigPath = Resolve-CoremailClaudeUserConfigPath -UserProfile $userProfile

    $claudeInvocation = Resolve-ClaudeCodeInvocation -ExplicitPath $ClaudeCommand
    if ($null -eq $claudeInvocation) {
        throw 'Claude Code was not found; the user-scope Coremail MCP cannot be removed safely.'
    }

    $lockPath = Join-Path $claudeRoot 'coremail-controller.lifecycle.lock'
    [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $lockPath)
    $lockStream = Enter-CoremailLifecycleLock -Path $lockPath

    if ($targetLookupDenied) {
        Invoke-LegacyPermissionRepair -UserProfile $userProfile -Root $targetRoot
    }
    try {
        $targetEntry = Get-CoremailExactChildDirectory `
            -Parent $skillsRoot `
            -Name 'coremail-controller'
        if ([string]::IsNullOrWhiteSpace([string]$targetEntry)) {
            throw 'The Coremail package directory disappeared before identity verification.'
        }
        [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $targetRoot)
        $manifest = Get-RecognizedCoremailPackage -Root $targetRoot
    }
    catch {
        if (-not (Test-CoremailAccessDeniedError -ErrorRecord $_)) { throw }
        Invoke-LegacyPermissionRepair -UserProfile $userProfile -Root $targetRoot
        $targetEntry = Get-CoremailExactChildDirectory `
            -Parent $skillsRoot `
            -Name 'coremail-controller'
        if ([string]::IsNullOrWhiteSpace([string]$targetEntry)) {
            throw 'The legacy Coremail package disappeared during permission repair.'
        }
        [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $targetRoot)
        $manifest = Get-RecognizedCoremailPackage -Root $targetRoot
    }

    # Use the executable recorded by the installed descriptor.  Read it only
    # after any legacy ACL repair has restored access, and never silently switch
    # to a different Python from PATH.
    $runtimePath = Join-Path $targetRoot 'mcp\python-runtime.json'
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw "The installed Python runtime descriptor is missing: $runtimePath"
    }
    try { $pythonRuntime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json }
    catch { throw "The installed Python runtime descriptor is invalid: $($_.Exception.Message)" }
    if ([int]$pythonRuntime.schema_version -ne 1 -or
        [string]$pythonRuntime.executable_sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The installed Python runtime descriptor is invalid.'
    }
    $pythonRuntime.Executable = [IO.Path]::GetFullPath([string]$pythonRuntime.executable)
    if (-not (Test-Path -LiteralPath $pythonRuntime.Executable -PathType Leaf)) {
        throw "The installed Python executable is unavailable: $($pythonRuntime.Executable)"
    }
    if ((Get-FileHash -LiteralPath $pythonRuntime.Executable -Algorithm SHA256).Hash -ine
        [string]$pythonRuntime.executable_sha256) {
        throw 'The installed Python executable changed; uninstall stopped before mutation.'
    }

    # Package identity and the pinned runtime are verified before invoking
    # Claude.  This keeps a malformed/foreign active directory from causing a
    # user-configuration side effect during the capability probe.
    $claudeVersion = Get-CoremailClaudeVersion `
        -Invocation $claudeInvocation `
        -Label 'Claude Code version probe'
    $claudeVersionDisplay = if ($null -ne $claudeVersion.Version) {
        [string]$claudeVersion.Version
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$claudeVersion.Text)) {
        [string]$claudeVersion.Text
    }
    else {
        '<unreported>'
    }
    Invoke-CoremailClaudeChecked `
        -Invocation $claudeInvocation `
        -Arguments @('mcp', '--help') `
        -Label 'Claude MCP capability probe'

    $snapshotDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'coremail-uninstall-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $snapshotDirectory | Out-Null
    $claudeUserConfigSnapshot = Save-CoremailFileSnapshot `
        -Path $claudeUserConfigPath `
        -BackupDirectory $snapshotDirectory `
        -Label 'claude-user-config'
    $claudeUserConfigMutationStarted = $true
    $registrarBackup = Join-Path $snapshotDirectory 'claude-user-config-registrar.backup'
    Invoke-CoremailUserMcpRemoval `
        -Root $targetRoot `
        -UserConfig $claudeUserConfigPath `
        -BackupPath $registrarBackup

    $disabledRoot = Join-Path $claudeRoot 'plugins-disabled'
    [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $disabledRoot)
    New-Item -ItemType Directory -Path $disabledRoot -Force | Out-Null
    $destination = Join-Path $disabledRoot (
        'coremail-controller-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    Move-CoremailDirectoryAtomically `
        -Source $targetRoot `
        -Destination $destination `
        -OperationLabel "Disabling the Coremail package for $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" `
        -AccessDeniedRepair {
            if ($NoLegacyPermissionRepair) {
                throw 'Automatic legacy permission repair was disabled; the protected package was not moved.'
            }
            elseif (Test-CoremailReleaseGatePermissionRepairMode) {
                Invoke-LegacyPermissionRepair -UserProfile $userProfile -Root $targetRoot
                [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $targetRoot)
                $manifestAfterRepair = Get-RecognizedCoremailPackage -Root $targetRoot
                if ([string]$manifestAfterRepair.version -ne [string]$manifest.version) {
                    throw 'The package identity changed while legacy permissions were repaired.'
                }
            }
            elseif ($env:COREMAIL_RELEASE_GATE_TESTING -eq 'true') {
                throw 'The release gate encountered an unexpected production elevation path.'
            }
            else {
                Invoke-CoremailElevatedDirectoryMove `
                    -UserProfile $userProfile `
                    -Source $targetRoot `
                    -Destination $destination `
                    -ExpectedVersion ([string]$manifest.version)
            }
        }
    $uninstallCommitted = $true
    $claudeUserConfigMutationStarted = $false
    Write-CoremailLifecycleLog "UNINSTALL COMMITTED recovery=$destination; claudeVersion=$claudeVersionDisplay"

    Write-Host 'Coremail Controller has been removed from Claude user scope and moved, not deleted.' -ForegroundColor Green
    Write-Host "Recovery location: $destination"
    Write-Host 'Mailbox configuration and Windows Credential Manager entries were preserved.'
    Write-Host "Diagnostic log: $LogPath"
    exit 0
}
catch {
    $uninstallError = $_
    Write-CoremailLifecycleFailure -ErrorRecord $uninstallError -Context 'uninstall'
    if (-not $uninstallCommitted -and $claudeUserConfigMutationStarted -and
        $null -ne $claudeUserConfigSnapshot) {
        try {
            Restore-CoremailFileSnapshot `
                -Destination ([string]$claudeUserConfigSnapshot.Path) `
                -WasPresent ([bool]$claudeUserConfigSnapshot.WasPresent) `
                -BackupPath ([string]$claudeUserConfigSnapshot.BackupPath)
            Write-CoremailLifecycleLog 'ROLLBACK restored Claude user MCP configuration after uninstall failure'
        }
        catch {
            Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'uninstall user config rollback'
            Write-Host 'WARNING: Claude user MCP configuration rollback failed; package and diagnostic log were preserved.' -ForegroundColor Red
        }
    }
    Write-Host ''
    Write-Host "Uninstall stopped safely: $($uninstallError.Exception.Message)" -ForegroundColor Red
    Write-Host "The Coremail package directory remains at: $targetRoot"
    Write-Host "Diagnostic log: $LogPath"
    exit 1
}
finally {
    Exit-CoremailLifecycleLock -Stream $lockStream -Path $lockPath
    if ($snapshotDirectory -and
        (Test-Path -LiteralPath $snapshotDirectory -PathType Container)) {
        Remove-Item -LiteralPath $snapshotDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
