#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Reconfigure,
    [switch]$SkipConnectionCheck,
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

$mcpServerName = 'coremail-controller'
$expectedVersion = '0.9.0'
$userProfile = $null
$localAppData = $null
$agentRoot = $null
$releaseRoot = $null
$stagingRoot = $null
$activeRoot = $null
$stageRoot = $null
$claudeInvocation = $null
$pythonRuntime = $null
$claudeUserConfigPath = $null
$lifecycleLockPath = $null
$lifecycleLockStream = $null
$claudeUserConfigSnapshot = $null
$claudeUserConfigMutationStarted = $false
$registrationCommitted = $false
$preserveStage = $false
$sourceVersion = $null
$sourceCommit = $null
$deploymentPath = $null

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ''
    Write-Host "[$Number/6] $Message" -ForegroundColor Cyan
    Write-CoremailLifecycleLog "STEP $Number/6: $Message"
}

function Get-CoremailManifestVersion {
    param([Parameter(Mandatory = $true)][string]$Root)
    $manifestPath = Join-Path $Root '.claude-plugin\plugin.json'
    try { $manifest = (Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { throw "Plugin manifest is unavailable or invalid: $manifestPath ($($_.Exception.Message))" }
    if ([string]$manifest.name -ne $mcpServerName -or [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
        throw "Unexpected Coremail package identity: $manifestPath"
    }
    return [string]$manifest.version
}

function Invoke-PinnedPython {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$Label = 'Python helper',
        [string]$CapturePath = ''
    )
    Invoke-CoremailExternalChecked -Executable ([string]$pythonRuntime.executable) `
        -Arguments $Arguments -CapturePath $CapturePath -Label $Label
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

function Get-CoremailClaudePowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Windows PowerShell is unavailable: $path" }
    return [IO.Path]::GetFullPath($path)
}

function Invoke-CoremailUserMcpRegistration {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('register', 'unregister')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$UserConfig,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    $registrar = Join-Path $Root 'scripts\register_claude_user_mcp.py'
    if (-not (Test-Path -LiteralPath $registrar -PathType Leaf)) { throw "The Coremail MCP registrar is missing: $registrar" }
    $arguments = @(
        '-B', '-I', $registrar, $Operation,
        '--claude-executable', [string]$claudeInvocation.Executable,
        '--server-name', $mcpServerName,
        '--user-config', $UserConfig,
        '--backup', $BackupPath
    )
    foreach ($prefix in @($claudeInvocation.Prefix)) { $arguments += @('--claude-prefix', [string]$prefix) }
    if ($Operation -eq 'register') {
        $arguments += @(
            '--powershell-executable', (Get-CoremailClaudePowerShellPath),
            '--server-script', (Join-Path $Root 'mcp\run-server.ps1')
        )
    }
    $autoUpdaterWasPresent = Test-Path -LiteralPath 'Env:DISABLE_AUTOUPDATER'
    $updatesWerePresent = Test-Path -LiteralPath 'Env:DISABLE_UPDATES'
    $previousAutoUpdater = [string]$env:DISABLE_AUTOUPDATER
    $previousUpdates = [string]$env:DISABLE_UPDATES
    try {
        $env:DISABLE_AUTOUPDATER = '1'
        $env:DISABLE_UPDATES = '1'
        $label = if ($Operation -eq 'register') { 'Claude user-scope MCP registration' } else { 'Claude user-scope MCP removal' }
        Invoke-PinnedPython -Arguments $arguments -Label $label
    }
    finally {
        if ($autoUpdaterWasPresent) { $env:DISABLE_AUTOUPDATER = $previousAutoUpdater }
        else { Remove-Item Env:DISABLE_AUTOUPDATER -ErrorAction SilentlyContinue }
        if ($updatesWerePresent) { $env:DISABLE_UPDATES = $previousUpdates }
        else { Remove-Item Env:DISABLE_UPDATES -ErrorAction SilentlyContinue }
    }
}

function Copy-CoremailPluginTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $descriptor = [IO.Path]::GetFullPath((Join-Path $Source 'mcp\python-runtime.json'))
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        if ([string]::Equals([IO.Path]::GetFullPath($item.FullName), $descriptor, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Write-PythonRuntimeDescriptor {
    param([Parameter(Mandatory = $true)][string]$PluginRoot, [Parameter(Mandatory = $true)][string]$OutputPath)
    $descriptorScript = Join-Path $PluginRoot 'mcp\describe-python.py'
    Invoke-PinnedPython -Arguments @('-B', '-I', $descriptorScript, '--output', $OutputPath) -Label 'Python runtime descriptor'
}

function Get-CoremailBuildIdentity {
    param([Parameter(Mandatory = $true)][string]$Root)
    $metadataPath = Join-Path $Root 'BUILD-METADATA.json'
    try { $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json }
    catch { throw "Build metadata is unavailable or invalid: $metadataPath" }
    if ([int]$metadata.schema_version -ne 1 -or [string]$metadata.version -ne $expectedVersion -or
        [string]$metadata.source_commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'The package is not a valid Windows-gated Coremail release.'
    }
    return [string]$metadata.source_commit
}

function Get-CoremailDeploymentPath {
    param(
        [Parameter(Mandatory = $true)][string]$DescriptorPath,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $descriptorHash = (Get-FileHash -LiteralPath $DescriptorPath -Algorithm SHA256).Hash.ToLowerInvariant().Substring(0, 12)
    $leaf = 'coremail-controller-{0}-{1}-{2}' -f $sourceVersion, $Commit.Substring(0, 12).ToLowerInvariant(), $descriptorHash
    $candidate = Join-Path $Parent $leaf
    [void](Assert-CoremailSafeDescendantPath -Root $localAppData -Path $candidate -Label 'Coremail release path')
    return $candidate
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This installer can run only on Windows.' }
    Write-Step 1 'Checking the gated package and local prerequisites'
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'The current Windows user profile directory could not be resolved.' }
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = [string]$env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'The current Windows LocalAppData directory could not be resolved.' }
    [void](Assert-CoremailSafeLocalPath -Path $localAppData -Label 'LocalAppData')

    $claudeUserConfigPath = Resolve-CoremailClaudeUserConfigPath -UserProfile $userProfile
    $candidateRuntime = Resolve-CoremailPythonCandidate -ExplicitPath $PythonExecutable
    if ($null -eq $candidateRuntime) { throw 'Python 3.10 or newer was not found. Install an approved Python runtime, then run INSTALL.cmd again.' }
    $probeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('coremail-python-probe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
    try {
        $probePath = Join-Path $probeDirectory 'python-runtime.json'
        Invoke-CoremailExternalChecked -Executable ([string]$candidateRuntime.Executable) -Prefix @($candidateRuntime.Prefix) `
            -Arguments @('-B', '-I', (Join-Path $sourceRoot 'mcp\describe-python.py'), '--output', $probePath) -Label 'Python runtime discovery'
        $pythonRuntime = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
    }
    finally { Remove-Item -LiteralPath $probeDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    if ([int]$pythonRuntime.schema_version -ne 1 -or [string]$pythonRuntime.executable_sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The selected Python runtime returned an invalid descriptor.'
    }
    $pythonRuntime.executable = [IO.Path]::GetFullPath([string]$pythonRuntime.executable)
    Invoke-PinnedPython -Arguments @('-B', '-I', (Join-Path $sourceRoot 'mcp\check-python.py')) -Label 'Python runtime check'

    $sourceVersion = Get-CoremailManifestVersion -Root $sourceRoot
    if ($sourceVersion -ne $expectedVersion) { throw "The package version is $sourceVersion; expected $expectedVersion." }
    $sourceCommit = Get-CoremailBuildIdentity -Root $sourceRoot
    $sourceDescriptor = Join-Path $sourceRoot 'mcp\python-runtime.json'
    if (Test-Path -LiteralPath $sourceDescriptor -PathType Leaf) { Assert-CoremailRelease -Root $sourceRoot -AllowPythonRuntime }
    else { Assert-CoremailRelease -Root $sourceRoot }

    $claudeInvocation = Resolve-ClaudeCodeInvocation -ExplicitPath $ClaudeCommand
    if ($null -eq $claudeInvocation) { throw 'Claude Code was not found. The installer uses the existing user installation and does not install or repair it.' }
    $claudeVersion = Get-CoremailClaudeVersion -Invocation $claudeInvocation -Label 'Claude Code version probe'
    $claudeVersionDisplay = '<unreported>'
    if ($null -ne $claudeVersion.Version) { $claudeVersionDisplay = [string]$claudeVersion.Version }
    elseif ($claudeVersion.Text) { $claudeVersionDisplay = [string]$claudeVersion.Text }
    Invoke-CoremailClaudeChecked -Invocation $claudeInvocation -Arguments @('mcp', '--help') `
        -Label 'Claude MCP capability probe' -QuietOnSuccess
    Write-Host "Coremail package version: $sourceVersion"
    Write-Host "Pinned Python: $($pythonRuntime.executable) ($($pythonRuntime.version), $($pythonRuntime.pointer_bits)-bit)"
    Write-Host "Claude Code: $($claudeInvocation.CommandPath) ($($claudeInvocation.Kind), $claudeVersionDisplay); user MCP config: $claudeUserConfigPath"

    Write-Step 2 'Acquiring the user lifecycle lock and staging under LocalAppData'
    $agentRoot = Join-Path $localAppData 'CoremailController'
    $releaseRoot = Join-Path $agentRoot 'releases'
    $stagingRoot = Join-Path $agentRoot 'staging'
    $lifecycleLockPath = Join-Path $agentRoot '.lifecycle.lock'
    foreach ($path in @($agentRoot, $releaseRoot, $stagingRoot, $lifecycleLockPath)) {
        [void](Assert-CoremailSafeDescendantPath -Root $localAppData -Path $path -Label 'Coremail lifecycle path')
    }
    $lifecycleLockStream = Enter-CoremailLifecycleLock -Path $lifecycleLockPath
    New-Item -ItemType Directory -Path $releaseRoot, $stagingRoot -Force | Out-Null
    $stageRoot = Join-Path $stagingRoot ('coremail-controller-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $stagePlugin = Join-Path $stageRoot 'runtime'
    Copy-CoremailPluginTree -Source $sourceRoot -Destination $stagePlugin
    Get-ChildItem -LiteralPath $stagePlugin -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    Assert-CoremailRelease -Root $stagePlugin
    Write-PythonRuntimeDescriptor -PluginRoot $stagePlugin -OutputPath (Join-Path $stagePlugin 'mcp\python-runtime.json')
    Assert-CoremailRelease -Root $stagePlugin -AllowPythonRuntime
    & (Join-Path $stagePlugin 'tests\smoke-mcp.ps1') -IgnoreAccountConfiguration
    if (-not $?) { throw 'Staged MCP smoke test failed.' }

    Write-Step 3 'Publishing an immutable Coremail runtime release'
    $deploymentPath = Get-CoremailDeploymentPath -DescriptorPath (Join-Path $stagePlugin 'mcp\python-runtime.json') -Commit $sourceCommit -Parent $releaseRoot
    $activeRoot = $deploymentPath
    $reuseExisting = $false
    if (Test-CoremailDirectoryPresent -Path $deploymentPath) {
        try {
            Assert-CoremailRelease -Root $deploymentPath -AllowPythonRuntime
            & (Join-Path $deploymentPath 'tests\smoke-mcp.ps1') -IgnoreAccountConfiguration
            if (-not $?) { throw 'Existing runtime smoke test failed.' }
            $reuseExisting = $true
            Write-Host "Verified immutable runtime already exists; reusing: $deploymentPath"
            Write-CoremailLifecycleLog "IMMUTABLE RELEASE REUSED path=$deploymentPath"
        }
        catch {
            $activeRoot = Join-Path $releaseRoot ('coremail-controller-' + $sourceVersion + '-' + [guid]::NewGuid().ToString('N'))
            [void](Assert-CoremailSafeDescendantPath -Root $localAppData -Path $activeRoot -Label 'replacement Coremail release path')
            Write-Warning "An existing release identity was not reusable; publishing a separate immutable directory: $activeRoot"
            Write-CoremailLifecycleLog "IMMUTABLE RELEASE IDENTITY NOT REUSED path=$deploymentPath; replacement=$activeRoot; reason=$($_.Exception.Message)"
        }
    }
    if (-not $reuseExisting) {
        try {
            Move-CoremailDirectoryAtomically -Source $stagePlugin -Destination $activeRoot -OperationLabel 'Publishing the immutable Coremail runtime'
            $stagePlugin = $null
        }
        catch {
            # The move helper deliberately leaves an ambiguous or locked
            # source untouched. Keep that staging directory for diagnosis
            # instead of deleting the only recoverable copy in finally.
            $preserveStage = $true
            throw
        }
        Write-CoremailLifecycleLog "IMMUTABLE RELEASE PUBLISHED path=$activeRoot"
    }
    Assert-CoremailRelease -Root $activeRoot -AllowPythonRuntime
    & (Join-Path $activeRoot 'tests\smoke-mcp.ps1') -IgnoreAccountConfiguration
    if (-not $?) { throw 'Published MCP smoke test failed.' }

    Write-Step 4 'Registering and verifying the Coremail MCP in Claude user scope'
    $claudeUserConfigSnapshot = Save-CoremailFileSnapshot -Path $claudeUserConfigPath -BackupDirectory $stageRoot -Label 'claude-user-config'
    $claudeUserConfigMutationStarted = $true
    Invoke-CoremailUserMcpRegistration -Operation register -Root $activeRoot -UserConfig $claudeUserConfigPath `
        -BackupPath (Join-Path $stageRoot 'claude-user-config-registrar.backup')
    $registrationCommitted = $true
    $claudeUserConfigMutationStarted = $false
    Write-Host "Claude Code user-scope MCP registered: $mcpServerName" -ForegroundColor Green

    Write-Step 5 'Preserving or configuring the mailbox account'
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) { $appData = Join-Path $userProfile 'AppData\Roaming' }
    $configPath = Join-Path $appData 'ClaudeCode\Coremail\config.json'
    [void](Assert-CoremailSafeDescendantPath -Root $appData -Path $configPath -Label 'Coremail account configuration')
    if ($Reconfigure -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        & (Join-Path $activeRoot 'scripts\setup-account.ps1') -LogPath $LogPath
        if (-not $?) { throw 'Account setup failed.' }
    }
    else { Write-Host "Existing non-secret account configuration preserved: $configPath" }

    Write-Step 6 'Verifying the installed MCP server and writing the result'
    $smokeTest = Join-Path $activeRoot 'tests\smoke-mcp.ps1'
    & $smokeTest
    if (-not $?) { throw 'Installed MCP smoke test failed.' }
    $connectionVerified = $false
    if (-not $SkipConnectionCheck -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            & $smokeTest -TimeoutMilliseconds 60000 -CheckConnection
            if (-not $?) { throw 'Live Coremail connection smoke test failed.' }
            $connectionVerified = $true
        }
        catch {
            Write-Warning "The package is installed, but the live transport check did not pass: $($_.Exception.Message)"
            Write-CoremailLifecycleLog "WARNING live connection check failed: $($_.Exception.Message)"
        }
    }
    $summaryDirectory = Join-Path $appData 'ClaudeCode\Coremail'
    New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
    $summaryPath = Join-Path $summaryDirectory 'INSTALLATION.txt'
    [void](Assert-CoremailSafeDescendantPath -Root $appData -Path $summaryPath -Label 'Coremail installation summary')
    $connectionText = if ($connectionVerified) { 'verified' } else { 'not verified' }
    $summary = @"
Coremail Controller installation

Version: $sourceVersion
MCP runtime: $activeRoot
Runtime root: $agentRoot
Claude MCP server: $mcpServerName (user scope; registered and verified)
Claude user MCP configuration: $claudeUserConfigPath
Python: $($pythonRuntime.executable)
Python SHA-256: $($pythonRuntime.executable_sha256)
Configuration: $configPath
Live connection: $connectionText
Lifecycle log: $LogPath

No Claude Skill directory is required or modified. Restart Claude Code, then
describe the mailbox task in natural language using the Coremail MCP tools.
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($summaryPath, $summary, $utf8)
    Write-CoremailLifecycleLog 'INSTALLATION COMMITTED'
    Write-Host ''
    Write-Host 'Coremail Controller installation completed.' -ForegroundColor Green
    Write-Host "Installation summary: $summaryPath"
    Write-Host "Diagnostic log: $LogPath"
    Write-Host 'Restart Claude Code, then describe the mailbox task in natural language.'
    exit 0
}
catch {
    $installError = $_
    Write-CoremailLifecycleFailure -ErrorRecord $installError -Context 'installation'
    if (-not $registrationCommitted -and $claudeUserConfigMutationStarted -and $null -ne $claudeUserConfigSnapshot) {
        try {
            Restore-CoremailFileSnapshot -Destination ([string]$claudeUserConfigSnapshot.Path) `
                -WasPresent ([bool]$claudeUserConfigSnapshot.WasPresent) -BackupPath ([string]$claudeUserConfigSnapshot.BackupPath)
            Write-CoremailLifecycleLog 'ROLLBACK restored Claude user MCP configuration'
        }
        catch { Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'installation user config rollback'; $preserveStage = $true }
    }
    Write-Host ''
    Write-Host "Setup stopped safely: $($installError.Exception.Message)" -ForegroundColor Red
    if ($activeRoot -and (Test-Path -LiteralPath $activeRoot -PathType Container)) {
        Write-Host "Any published immutable runtime remains intact at: $activeRoot"
    }
    if ($preserveStage -and $stageRoot -and (Test-Path -LiteralPath $stageRoot -PathType Container)) {
        Write-Host "The staged runtime was retained for safe diagnosis at: $stageRoot"
    }
    Write-Host "Diagnostic log: $LogPath"
    exit 1
}
finally {
    Exit-CoremailLifecycleLock -Stream $lifecycleLockStream -Path $lifecycleLockPath
    if (-not $preserveStage -and $stageRoot -and (Test-Path -LiteralPath $stageRoot -PathType Container)) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
