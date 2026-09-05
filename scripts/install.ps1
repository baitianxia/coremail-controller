#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Reconfigure,
    [switch]$SkipConnectionCheck,
    [switch]$NoLegacyPermissionRepair,
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
        'INSTALL-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'
    )
}
Initialize-CoremailLifecycleLog -Path $LogPath

$pluginId = 'coremail-controller@skills-dir'
$expectedVersion = '0.7.1'
$lifecycleLockStream = $null
$lifecycleLockPath = $null
$activationStageRoot = $null
$activationPlugin = $null
$targetRoot = $null
$backupRoot = $null
$failedRoot = $null
$targetContainsNewPlugin = $false
$activationCommitted = $false
$settingsSnapshot = $null
$settingsMutationStarted = $false
$runtimeSnapshot = $null
$runtimeMutationStarted = $false
$preserveActivationStage = $false
$pythonRuntime = $null
$claudeInvocation = $null
$claudeVersion = $null
$existingPluginVersion = $null
$legacyPermissionRepairAttempted = $false

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ''
    Write-Host "[$Number/6] $Message" -ForegroundColor Cyan
    Write-CoremailLifecycleLog "STEP $Number/6: $Message"
}

function Get-CoremailManifestVersion {
    param([Parameter(Mandatory = $true)][string]$Root)
    $manifestPath = Join-Path $Root '.claude-plugin\plugin.json'
    try { $manifestText = [IO.File]::ReadAllText($manifestPath) }
    catch [UnauthorizedAccessException] { throw }
    catch {
        if (Test-CoremailAccessDeniedError -ErrorRecord $_) { throw }
        throw "Plugin manifest is unavailable: $manifestPath ($($_.Exception.Message))"
    }
    try { $manifest = $manifestText | ConvertFrom-Json }
    catch { throw "Plugin manifest is invalid: $($_.Exception.Message)" }
    if ([string]$manifest.name -ne 'coremail-controller') {
        throw "Unexpected plugin identity: $($manifest.name)"
    }
    return [string]$manifest.version
}

function Test-ExistingPluginIdentity {
    param([Parameter(Mandatory = $true)][string]$Root)
    $version = Get-CoremailManifestVersion -Root $Root
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Refusing to replace a plugin without a version: $Root"
    }
    return $version
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

function Get-ExistingPluginVersionWithLegacyRepair {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$SkillsRoot,
        [Parameter(Mandatory = $true)][string]$Root
    )

    try {
        $entry = Get-CoremailExactChildDirectory `
            -Parent $SkillsRoot `
            -Name 'coremail-controller'
        if ([string]::IsNullOrWhiteSpace([string]$entry)) { return $null }
        [void](Assert-CoremailSafeClaudePath -UserProfile $UserProfile -Path $Root)
        $version = Test-ExistingPluginIdentity -Root $Root
        return $version
    }
    catch {
        if (-not (Test-CoremailAccessDeniedError -ErrorRecord $_)) { throw }
        Invoke-LegacyPermissionRepair -UserProfile $UserProfile -Root $Root
        $entry = Get-CoremailExactChildDirectory `
            -Parent $SkillsRoot `
            -Name 'coremail-controller'
        if ([string]::IsNullOrWhiteSpace([string]$entry)) {
            throw 'The legacy plugin directory disappeared during permission repair.'
        }
        [void](Assert-CoremailSafeClaudePath -UserProfile $UserProfile -Path $Root)
        $version = Test-ExistingPluginIdentity -Root $Root
        return $version
    }
}

function Copy-CoremailPluginTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Invoke-PinnedPython {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$Label = 'Python helper',
        [string]$CapturePath = ''
    )
    Invoke-CoremailExternalChecked `
        -Executable ([string]$pythonRuntime.executable) `
        -Arguments $Arguments `
        -CapturePath $CapturePath `
        -Label $Label
}

function Invoke-Claude {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$Label = 'Claude Code',
        [string]$CapturePath = ''
    )
    Invoke-CoremailClaudeChecked `
        -Invocation $claudeInvocation `
        -Arguments $Arguments `
        -CapturePath $CapturePath `
        -Label $Label
}

function Write-PythonRuntimeDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $descriptorScript = Join-Path $PluginRoot 'mcp\describe-python.py'
    Invoke-PinnedPython `
        -Arguments @('-B', '-I', $descriptorScript, '--output', $OutputPath) `
        -Label 'Python runtime descriptor'
}

function Assert-CoremailRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$AllowPythonRuntime
    )
    $verifier = Join-Path $Root 'scripts\verify-release.py'
    $arguments = @('-B', '-I', $verifier, $Root, '--require-windows-gate')
    if ($AllowPythonRuntime) { $arguments += '--allow-python-runtime' }
    Invoke-PinnedPython -Arguments $arguments -Label 'Coremail release verifier'
}

function Assert-ClaudePluginState {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('present', 'enabled', 'disabled')]
        [string]$State,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory
    )
    $inventoryPath = Join-Path $TemporaryDirectory (
        'claude-plugin-list-' + [guid]::NewGuid().ToString('N') + '.json'
    )
    Invoke-Claude `
        -Arguments @('plugin', 'list', '--json') `
        -CapturePath $inventoryPath `
        -Label 'Claude plugin inventory'
    $verifier = Join-Path $Root 'scripts\verify-claude-plugin-list.py'
    Invoke-PinnedPython `
        -Arguments @(
            '-B', '-I', $verifier, $inventoryPath,
            '--plugin-id', $pluginId,
            '--version', $expectedVersion,
            '--expected-path', $Root,
            '--state', $State
        ) `
        -Label 'Claude plugin state verifier'
}

function Restore-ActivationTransaction {
    param([Parameter(Mandatory = $true)][string]$OriginalMessage)

    Write-CoremailLifecycleLog "ROLLBACK STARTED reason=$OriginalMessage"
    if ($settingsMutationStarted -and $null -ne $settingsSnapshot) {
        Restore-CoremailFileSnapshot `
            -Destination ([string]$settingsSnapshot.Path) `
            -WasPresent ([bool]$settingsSnapshot.WasPresent) `
            -BackupPath ([string]$settingsSnapshot.BackupPath)
        Write-CoremailLifecycleLog 'ROLLBACK restored Claude user settings'
    }
    if ($runtimeMutationStarted -and $null -ne $runtimeSnapshot) {
        Restore-CoremailFileSnapshot `
            -Destination ([string]$runtimeSnapshot.Path) `
            -WasPresent ([bool]$runtimeSnapshot.WasPresent) `
            -BackupPath ([string]$runtimeSnapshot.BackupPath)
        Write-CoremailLifecycleLog 'ROLLBACK restored pinned Python descriptor'
    }
    if ($targetContainsNewPlugin -and
        (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        $failedDirectory = Join-Path (Split-Path -Parent (Split-Path -Parent $targetRoot)) 'plugin-failed'
        [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $failedDirectory)
        New-Item -ItemType Directory -Path $failedDirectory -Force | Out-Null
        $failedRoot = Join-Path $failedDirectory (
            'coremail-controller-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
            [guid]::NewGuid().ToString('N').Substring(0, 8)
        )
        Move-CoremailDirectoryAtomically `
            -Source $targetRoot `
            -Destination $failedRoot `
            -OperationLabel 'Quarantining the uncommitted plugin'
        $targetContainsNewPlugin = $false
        Write-CoremailLifecycleLog "ROLLBACK quarantined uncommitted plugin at $failedRoot"
    }
    if ($backupRoot -and
        (Test-Path -LiteralPath $backupRoot -PathType Container) -and
        -not (Test-Path -LiteralPath $targetRoot)) {
        Move-CoremailDirectoryAtomically `
            -Source $backupRoot `
            -Destination $targetRoot `
            -OperationLabel 'Restoring the previous plugin'
        $backupRoot = $null
        Write-CoremailLifecycleLog 'ROLLBACK restored previous plugin'
    }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer can run only on Windows.'
    }

    Write-Step 1 'Checking the gated package and exact local prerequisites'
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw 'The current Windows user profile directory could not be resolved.'
    }
    Assert-CoremailDefaultClaudeConfigDirectory -UserProfile $userProfile
    $claudeRoot = Join-Path $userProfile '.claude'
    $skillsRoot = Join-Path $claudeRoot 'skills'
    $targetRoot = Join-Path $skillsRoot 'coremail-controller'
    $sourceCanonical = $sourceRoot.TrimEnd('\')
    $targetCanonical = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $runningFromTarget = [string]::Equals(
        $sourceCanonical,
        $targetCanonical,
        [StringComparison]::OrdinalIgnoreCase
    )
    [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $skillsRoot)

    $candidateRuntime = Resolve-CoremailPythonCandidate -ExplicitPath $PythonExecutable
    if ($null -eq $candidateRuntime) {
        throw 'Python 3.10 or newer was not found. Install an approved Python runtime, then run INSTALL.cmd again.'
    }
    $runtimeProbeDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'coremail-python-probe-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $runtimeProbeDirectory | Out-Null
    try {
        $runtimeProbePath = Join-Path $runtimeProbeDirectory 'python-runtime.json'
        Invoke-CoremailExternalChecked `
            -Executable ([string]$candidateRuntime.Executable) `
            -Prefix @($candidateRuntime.Prefix) `
            -Arguments @('-B', '-I', (Join-Path $sourceRoot 'mcp\describe-python.py'), '--output', $runtimeProbePath) `
            -Label 'Python runtime discovery'
        $pythonRuntime = Get-Content -LiteralPath $runtimeProbePath -Raw | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $runtimeProbeDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ([int]$pythonRuntime.schema_version -ne 1 -or
        [string]$pythonRuntime.executable_sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The selected Python runtime returned an invalid descriptor.'
    }
    $pythonRuntime.executable = [IO.Path]::GetFullPath([string]$pythonRuntime.executable)
    Invoke-PinnedPython `
        -Arguments @('-B', '-I', (Join-Path $sourceRoot 'mcp\check-python.py')) `
        -Label 'Python version probe'

    $claudeInvocation = Resolve-ClaudeCodeInvocation -ExplicitPath $ClaudeCommand
    if ($null -eq $claudeInvocation) {
        throw 'Claude Code was not found as a native per-user executable or a validated npm installation.'
    }
    $claudeVersion = Assert-CoremailClaudeMinimumVersion `
        -Invocation $claudeInvocation `
        -Label 'Claude Code version probe'

    Assert-CoremailRelease -Root $sourceRoot -AllowPythonRuntime:$runningFromTarget
    $sourceVersion = Get-CoremailManifestVersion -Root $sourceRoot
    if ($sourceVersion -ne $expectedVersion) {
        throw "The package version is $sourceVersion; expected $expectedVersion."
    }
    Invoke-Claude `
        -Arguments @('plugin', 'validate', $sourceRoot, '--strict') `
        -Label 'Claude plugin validation'
    Write-Host "Plugin version: $sourceVersion"
    Write-Host "Pinned Python: $($pythonRuntime.executable) ($($pythonRuntime.version), $($pythonRuntime.pointer_bits)-bit)"
    Write-Host "Claude Code: $($claudeInvocation.CommandPath) ($($claudeInvocation.Kind), $($claudeVersion.Version))"

    Write-Step 2 'Acquiring the user lifecycle lock and staging under the Claude profile'
    $lifecycleLockPath = Join-Path $claudeRoot 'coremail-controller.lifecycle.lock'
    [void](Assert-CoremailSafeClaudePath `
        -UserProfile $userProfile `
        -Path $lifecycleLockPath)
    $lifecycleLockStream = Enter-CoremailLifecycleLock -Path $lifecycleLockPath
    New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
    $existingPluginVersion = Get-ExistingPluginVersionWithLegacyRepair `
        -UserProfile $userProfile `
        -SkillsRoot $skillsRoot `
        -Root $targetRoot
    if ($runningFromTarget -and $null -eq $existingPluginVersion) {
        throw 'INSTALL.cmd is running from the active path, but that plugin entry disappeared.'
    }
    $activationStagingDirectory = Join-Path $claudeRoot 'plugin-staging'
    [void](Assert-CoremailSafeClaudePath `
        -UserProfile $userProfile `
        -Path $activationStagingDirectory)
    New-Item -ItemType Directory -Path $activationStagingDirectory -Force | Out-Null
    $activationStageRoot = Join-Path $activationStagingDirectory (
        'coremail-controller-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $activationStageRoot | Out-Null

    if ($runningFromTarget) {
        Write-Host 'INSTALL.cmd is running from the active plugin; the verified files will be retained.'
        Assert-CoremailRelease -Root $targetRoot -AllowPythonRuntime
        $runtimePath = Join-Path $targetRoot 'mcp\python-runtime.json'
        $runtimeSnapshot = Save-CoremailFileSnapshot `
            -Path $runtimePath `
            -BackupDirectory $activationStageRoot `
            -Label 'python-runtime'
        $runtimeMutationStarted = $true
        $runtimeStage = Join-Path (Split-Path -Parent $runtimePath) (
            '.python-runtime-' + [guid]::NewGuid().ToString('N') + '.json'
        )
        Write-PythonRuntimeDescriptor -PluginRoot $targetRoot -OutputPath $runtimeStage
        Publish-CoremailFileAtomically -Source $runtimeStage -Destination $runtimePath
    }
    else {
        $activationPlugin = Join-Path $activationStageRoot 'coremail-controller'
        Copy-CoremailPluginTree -Source $sourceRoot -Destination $activationPlugin
        Get-ChildItem -LiteralPath $activationPlugin -Recurse -File -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
        Assert-CoremailRelease -Root $activationPlugin
        Write-PythonRuntimeDescriptor `
            -PluginRoot $activationPlugin `
            -OutputPath (Join-Path $activationPlugin 'mcp\python-runtime.json')
        Assert-CoremailRelease -Root $activationPlugin -AllowPythonRuntime
        & (Join-Path $activationPlugin 'tests\smoke-mcp.ps1') -IgnoreAccountConfiguration
        Invoke-Claude `
            -Arguments @('plugin', 'validate', $activationPlugin, '--strict') `
            -Label 'Staged Claude plugin validation'
    }

    Write-Step 3 'Publishing the plugin with recoverable same-volume directory moves'
    if (-not $runningFromTarget) {
        if ($null -ne $existingPluginVersion) {
            $previousVersion = $existingPluginVersion
            $backupDirectory = Join-Path $claudeRoot 'plugin-backups'
            [void](Assert-CoremailSafeClaudePath `
                -UserProfile $userProfile `
                -Path $backupDirectory)
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
            $backupRoot = Join-Path $backupDirectory (
                'coremail-controller-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
                [guid]::NewGuid().ToString('N').Substring(0, 8)
            )
            Move-CoremailDirectoryAtomically `
                -Source $targetRoot `
                -Destination $backupRoot `
                -OperationLabel 'Archiving the previous plugin' `
                -AccessDeniedRepair {
                    Invoke-LegacyPermissionRepair -UserProfile $userProfile -Root $targetRoot
                    [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $targetRoot)
                    $versionAfterRepair = Test-ExistingPluginIdentity -Root $targetRoot
                    if ($versionAfterRepair -ne $previousVersion) {
                        throw 'The plugin identity changed while legacy permissions were repaired.'
                    }
                }
            Write-Host "Previous plugin version $previousVersion preserved at: $backupRoot"
        }
        try {
            Move-CoremailDirectoryAtomically `
                -Source $activationPlugin `
                -Destination $targetRoot `
                -OperationLabel 'Publishing the new plugin'
            $activationPlugin = $null
            $targetContainsNewPlugin = $true
        }
        catch {
            $publishError = $_
            if ((Test-Path -LiteralPath $targetRoot) -or
                ($activationPlugin -and -not (Test-Path -LiteralPath $activationPlugin))) {
                $preserveActivationStage = $true
            }
            if ($backupRoot -and
                (Test-Path -LiteralPath $backupRoot -PathType Container) -and
                -not (Test-Path -LiteralPath $targetRoot)) {
                Move-CoremailDirectoryAtomically `
                    -Source $backupRoot `
                    -Destination $targetRoot `
                    -OperationLabel 'Restoring the previous plugin after publication failure'
                $backupRoot = $null
            }
            throw $publishError
        }
    }
    Assert-CoremailRelease -Root $targetRoot -AllowPythonRuntime
    & (Join-Path $targetRoot 'tests\smoke-mcp.ps1') -IgnoreAccountConfiguration

    Write-Step 4 'Enabling and verifying the exact plugin through Claude Code'
    $settingsPath = Join-Path $claudeRoot 'settings.json'
    [void](Assert-CoremailSafeClaudePath -UserProfile $userProfile -Path $settingsPath)
    $settingsSnapshot = Save-CoremailFileSnapshot `
        -Path $settingsPath `
        -BackupDirectory $activationStageRoot `
        -Label 'claude-settings'
    $settingsMutationStarted = $true
    Invoke-Claude `
        -Arguments @('plugin', 'enable', $pluginId, '--scope', 'user') `
        -Label 'Claude plugin enable'
    Assert-ClaudePluginState `
        -State enabled `
        -Root $targetRoot `
        -TemporaryDirectory $activationStageRoot
    $activationCommitted = $true
    $settingsMutationStarted = $false
    $runtimeMutationStarted = $false
    Write-Host "Claude Code loaded and enabled: $pluginId" -ForegroundColor Green

    Write-Step 5 'Preserving or configuring the mailbox account'
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path $userProfile 'AppData\Roaming'
    }
    $configPath = Join-Path $appData 'ClaudeCode\Coremail\config.json'
    [void](Assert-CoremailSafeDescendantPath `
        -Root $appData `
        -Path $configPath `
        -Label 'Coremail account configuration')
    if ($Reconfigure -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        & (Join-Path $targetRoot 'scripts\setup-account.ps1') -LogPath $LogPath
    }
    else {
        Write-Host "Existing non-secret account configuration preserved: $configPath"
    }

    Write-Step 6 'Verifying the installed MCP server and writing the result'
    $smokeTest = Join-Path $targetRoot 'tests\smoke-mcp.ps1'
    & $smokeTest
    $connectionVerified = $false
    if (-not $SkipConnectionCheck -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            & $smokeTest -TimeoutMilliseconds 60000 -CheckConnection
            $connectionVerified = $true
        }
        catch {
            Write-Warning "The plugin is installed, but the live transport check did not pass: $($_.Exception.Message)"
            Write-CoremailLifecycleLog "WARNING live connection check failed: $($_.Exception.Message)"
        }
    }

    $summaryDirectory = Join-Path $appData 'ClaudeCode\Coremail'
    New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
    $summaryPath = Join-Path $summaryDirectory 'INSTALLATION.txt'
    [void](Assert-CoremailSafeDescendantPath `
        -Root $appData `
        -Path $summaryPath `
        -Label 'Coremail installation summary')
    $connectionText = if ($connectionVerified) { 'verified' } else { 'not verified' }
    $summary = @"
Coremail Controller installation

Version: $sourceVersion
Plugin: $targetRoot
Claude plugin id: $pluginId (enabled and listed)
Python: $($pythonRuntime.executable)
Python SHA-256: $($pythonRuntime.executable_sha256)
Configuration: $configPath
Live connection: $connectionText
Previous plugin backup: $backupRoot
Lifecycle log: $LogPath

Restart Claude Code or run /reload-plugins.
Use /coremail-controller:coremail for mailbox work.
Use /coremail-controller:web-to-coremail for the isolated browser-to-email workflow.
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($summaryPath, $summary, $utf8)

    Write-CoremailLifecycleLog 'INSTALLATION COMMITTED'
    Write-Host ''
    Write-Host 'Coremail Controller installation completed.' -ForegroundColor Green
    Write-Host "Installation summary: $summaryPath"
    Write-Host "Diagnostic log: $LogPath"
    Write-Host 'Restart Claude Code or run /reload-plugins, then invoke /coremail-controller:coremail.'
    exit 0
}
catch {
    $installError = $_
    Write-CoremailLifecycleFailure -ErrorRecord $installError -Context 'installation'
    if (-not $activationCommitted -and
        ($settingsMutationStarted -or $runtimeMutationStarted -or $targetContainsNewPlugin -or $backupRoot)) {
        try { Restore-ActivationTransaction -OriginalMessage $installError.Exception.Message }
        catch {
            $rollbackError = $_
            Write-CoremailLifecycleFailure -ErrorRecord $rollbackError -Context 'installation rollback'
            $preserveActivationStage = $true
            Write-Host ''
            Write-Host "Setup failed and rollback also stopped safely: $($rollbackError.Exception.Message)" -ForegroundColor Red
            Write-Host "Original setup error: $($installError.Exception.Message)"
            Write-Host 'Current and backup directories were preserved; do not delete either until the diagnostic log is reviewed.'
            Write-Host "Diagnostic log: $LogPath"
            exit 1
        }
    }
    Write-Host ''
    Write-Host "Setup stopped safely: $($installError.Exception.Message)" -ForegroundColor Red
    if ($activationCommitted) {
        Write-Host "The verified plugin remains installed at $targetRoot; mailbox setup may be incomplete."
    }
    elseif ($failedRoot) {
        Write-Host "The rejected new plugin was preserved for diagnosis at: $failedRoot"
    }
    Write-Host "Diagnostic log: $LogPath"
    exit 1
}
finally {
    Exit-CoremailLifecycleLock -Stream $lifecycleLockStream -Path $lifecycleLockPath
    if (-not $preserveActivationStage -and
        $activationStageRoot -and
        (Test-Path -LiteralPath $activationStageRoot -PathType Container)) {
        Remove-Item -LiteralPath $activationStageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
