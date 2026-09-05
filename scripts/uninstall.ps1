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

$pluginId = 'coremail-controller@skills-dir'
$lockStream = $null
$lockPath = $null
$settingsSnapshot = $null
$settingsMutationStarted = $false
$uninstallCommitted = $false
$snapshotDirectory = $null
$targetRoot = $null
$legacyPermissionRepairAttempted = $false

function Invoke-Claude {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$CapturePath = '',
        [string]$Label = 'Claude Code'
    )
    Invoke-CoremailClaudeChecked `
        -Invocation $Invocation `
        -Arguments $Arguments `
        -CapturePath $CapturePath `
        -Label $Label
}

function Get-ExactPluginInventoryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$InventoryPath,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )
    try {
        $inventoryText = Get-Content -LiteralPath $InventoryPath -Raw
        $payload = $inventoryText | ConvertFrom-Json
    }
    catch { throw "Claude plugin inventory is not valid JSON: $($_.Exception.Message)" }
    # Windows PowerShell 5.1 unwraps a one-element JSON array emitted through
    # the pipeline. Use the source JSON shape, not the resulting CLR type, to
    # distinguish Claude's top-level array from an object response.
    $entries = if ($inventoryText.TrimStart().StartsWith('[')) {
        @($payload | Where-Object { $null -ne $_ })
    }
    elseif ($null -ne $payload.PSObject.Properties['installed']) {
        @($payload.installed)
    }
    else {
        throw 'Claude plugin inventory has an unsupported structure.'
    }
    $matches = @($entries | Where-Object { [string]$_.id -eq $pluginId })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one Claude inventory entry for $pluginId; found $($matches.Count)."
    }
    $entry = $matches[0]
    if ([string]$entry.version -ne $ExpectedVersion) {
        throw "Claude inventory reports plugin version '$($entry.version)', expected '$ExpectedVersion'."
    }
    $inventoryPath = [IO.Path]::GetFullPath([string]$entry.installPath).TrimEnd('\')
    if (-not [string]::Equals(
        $inventoryPath,
        [IO.Path]::GetFullPath($ExpectedPath).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Claude inventory points the plugin id at an unexpected directory.'
    }
    if ($entry.enabled -isnot [bool]) {
        throw 'Claude inventory did not report a boolean enabled state.'
    }
    if ($null -ne $entry.PSObject.Properties['errors'] -and
        $null -ne $entry.errors -and @($entry.errors).Count -gt 0) {
        throw 'Claude inventory reports plugin load errors; uninstall stopped before mutation.'
    }
    return $entry
}

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

function Get-RecognizedPluginManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $manifestPath = Join-Path $Root '.claude-plugin\plugin.json'
    try { $manifestText = [IO.File]::ReadAllText($manifestPath) }
    catch [UnauthorizedAccessException] { throw }
    catch {
        if (Test-CoremailAccessDeniedError -ErrorRecord $_) { throw }
        throw "Refusing to move a plugin whose manifest is unavailable: $Root ($($_.Exception.Message))"
    }
    try { $manifest = $manifestText | ConvertFrom-Json }
    catch { throw "Refusing to move a plugin with an invalid manifest: $Root" }
    if ([string]$manifest.name -ne 'coremail-controller' -or
        [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
        throw 'Refusing to move a plugin with an unexpected identity or missing version.'
    }
    return $manifest
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This uninstaller is intended for Windows.'
    }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw 'The current Windows user profile directory could not be resolved.'
    }
    Assert-CoremailDefaultClaudeConfigDirectory -UserProfile $userProfile
    $claudeRoot = Join-Path $userProfile '.claude'
    $skillsRoot = Join-Path $claudeRoot 'skills'
    $targetRoot = Join-Path $skillsRoot 'coremail-controller'
    $currentIdentityName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-CoremailLifecycleLog "UNINSTALL identity=$currentIdentityName; target=$targetRoot"
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
    if (-not $targetLookupDenied -and
        [string]::IsNullOrWhiteSpace([string]$targetEntry)) {
        Write-Host 'Coremail Controller is not installed in the personal skills directory.'
        Write-Host "Diagnostic log: $LogPath"
        Write-CoremailLifecycleLog 'UNINSTALL no active plugin found'
        exit 0
    }

    $claudeInvocation = Resolve-ClaudeCodeInvocation -ExplicitPath $ClaudeCommand
    if ($null -eq $claudeInvocation) {
        throw 'Claude Code was not found; the plugin cannot be disabled and verified safely.'
    }
    [void](Assert-CoremailClaudeMinimumVersion `
        -Invocation $claudeInvocation `
        -Label 'Claude Code version probe')

    # Do not create the lifecycle lock (or any other state) until the CLI
    # version preflight has accepted the skills-directory contract. This keeps
    # unsupported Claude releases fail-before-mutation just like installation.
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
            throw 'The plugin directory disappeared before identity verification.'
        }
        [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $targetRoot)
        $manifest = Get-RecognizedPluginManifest -Root $targetRoot
    }
    catch {
        if (-not (Test-CoremailAccessDeniedError -ErrorRecord $_)) { throw }
        Invoke-LegacyPermissionRepair -UserProfile $userProfile -Root $targetRoot
        $targetEntry = Get-CoremailExactChildDirectory `
            -Parent $skillsRoot `
            -Name 'coremail-controller'
        if ([string]::IsNullOrWhiteSpace([string]$targetEntry)) {
            throw 'The legacy plugin directory disappeared during permission repair.'
        }
        [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $targetRoot)
        $manifest = Get-RecognizedPluginManifest -Root $targetRoot
    }

    $snapshotDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'coremail-uninstall-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $snapshotDirectory | Out-Null
    $inventoryPath = Join-Path $snapshotDirectory 'before.json'
    Invoke-Claude `
        -Invocation $claudeInvocation `
        -Arguments @('plugin', 'list', '--json') `
        -CapturePath $inventoryPath `
        -Label 'Claude plugin inventory before uninstall'
    $entry = Get-ExactPluginInventoryEntry `
        -InventoryPath $inventoryPath `
        -ExpectedPath $targetRoot `
        -ExpectedVersion ([string]$manifest.version)

    if ([bool]$entry.enabled) {
        $settingsPath = Join-Path $claudeRoot 'settings.json'
        [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $settingsPath)
        $settingsSnapshot = Save-CoremailFileSnapshot `
            -Path $settingsPath `
            -BackupDirectory $snapshotDirectory `
            -Label 'claude-settings'
        $settingsMutationStarted = $true
        Invoke-Claude `
            -Invocation $claudeInvocation `
            -Arguments @('plugin', 'disable', $pluginId, '--scope', 'user') `
            -Label 'Claude plugin disable'
        $disabledInventoryPath = Join-Path $snapshotDirectory 'disabled.json'
        Invoke-Claude `
            -Invocation $claudeInvocation `
            -Arguments @('plugin', 'list', '--json') `
            -CapturePath $disabledInventoryPath `
            -Label 'Claude plugin inventory after disable'
        $disabledEntry = Get-ExactPluginInventoryEntry `
            -InventoryPath $disabledInventoryPath `
            -ExpectedPath $targetRoot `
            -ExpectedVersion ([string]$manifest.version)
        if ([bool]$disabledEntry.enabled) {
            throw 'Claude Code did not disable the exact Coremail plugin.'
        }
    }
    else {
        Write-Host "Claude Code already reports $pluginId as disabled."
    }

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
        -OperationLabel "Disabling the Coremail plugin directory for $currentIdentityName" `
        -AccessDeniedRepair {
            Invoke-LegacyPermissionRepair -UserProfile $userProfile -Root $targetRoot
            [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $targetRoot)
            $manifestAfterRepair = Get-RecognizedPluginManifest -Root $targetRoot
            if ([string]$manifestAfterRepair.version -ne [string]$manifest.version) {
                throw 'The plugin identity changed while legacy permissions were repaired.'
            }
        }
    $uninstallCommitted = $true
    $settingsMutationStarted = $false
    Write-CoremailLifecycleLog "UNINSTALL COMMITTED recovery=$destination"

    Write-Host 'Coremail Controller has been disabled and moved, not deleted.' -ForegroundColor Green
    Write-Host "Recovery location: $destination"
    Write-Host 'Mailbox configuration and Windows Credential Manager entries were preserved.'
    Write-Host "Diagnostic log: $LogPath"
    Write-Host 'Restart Claude Code or run /reload-plugins.'
    exit 0
}
catch {
    $uninstallError = $_
    Write-CoremailLifecycleFailure -ErrorRecord $uninstallError -Context 'uninstall'
    if (-not $uninstallCommitted -and $settingsMutationStarted -and $null -ne $settingsSnapshot) {
        try {
            Restore-CoremailFileSnapshot `
                -Destination ([string]$settingsSnapshot.Path) `
                -WasPresent ([bool]$settingsSnapshot.WasPresent) `
                -BackupPath ([string]$settingsSnapshot.BackupPath)
            Write-CoremailLifecycleLog 'ROLLBACK restored Claude settings after uninstall failure'
        }
        catch {
            Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'uninstall settings rollback'
            Write-Host 'WARNING: Claude settings rollback failed; both the plugin directory and diagnostic log were preserved.' -ForegroundColor Red
        }
    }
    Write-Host ''
    Write-Host "Uninstall stopped safely: $($uninstallError.Exception.Message)" -ForegroundColor Red
    Write-Host "The plugin directory remains at: $targetRoot"
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
