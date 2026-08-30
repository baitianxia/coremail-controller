#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Reconfigure,
    [switch]$SkipConnectionCheck
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:PythonCommand = $null
$script:PythonPrefix = @()
$stageRoot = $null
$stagePlugin = $null
$activationStageRoot = $null
$activationPlugin = $null
$targetRoot = $null
$backupRoot = $null
$pluginActivated = $false

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ''
    Write-Host "[$Number/5] $Message" -ForegroundColor Cyan
}

function Resolve-PythonRuntime {
    param([string]$VersionProbePath)

    if (-not [string]::IsNullOrWhiteSpace($env:COREMAIL_PYTHON)) {
        $candidate = Get-Command $env:COREMAIL_PYTHON -ErrorAction SilentlyContinue
        if ($null -eq $candidate) {
            throw "COREMAIL_PYTHON cannot be resolved: $($env:COREMAIL_PYTHON)"
        }
        $script:PythonCommand = $candidate.Source
    }
    else {
        $launcher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
        if ($null -ne $launcher) {
            $script:PythonCommand = $launcher.Source
            $script:PythonPrefix = @('-3')
        }
        else {
            foreach ($name in @('python.exe', 'python3.exe', 'python', 'python3')) {
                $candidate = Get-Command $name -ErrorAction SilentlyContinue
                if ($null -ne $candidate) {
                    $script:PythonCommand = $candidate.Source
                    break
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:PythonCommand)) {
        throw 'Python 3.10 or newer was not found. Install an approved Python runtime, then double-click INSTALL.cmd again.'
    }
    if (-not (Test-Path -LiteralPath $VersionProbePath -PathType Leaf)) {
        throw "Python version probe not found: $VersionProbePath"
    }

    $pythonPrefix = $script:PythonPrefix
    & $script:PythonCommand @pythonPrefix -I $VersionProbePath
    $versionProbeExitCode = $LASTEXITCODE
    if ($versionProbeExitCode -eq 10) {
        throw 'Python 3.10 or newer is required by the selected interpreter.'
    }
    if ($versionProbeExitCode -ne 0) {
        throw "Unable to validate the selected Python interpreter (probe exit code $versionProbeExitCode): $($script:PythonCommand)"
    }
    return '3.10+ verified'
}

function Test-PluginTree {
    param([string]$Root)

    $requiredFiles = @(
        '.claude-plugin\plugin.json',
        '.mcp.json',
        'README.md',
        'START-HERE.md',
        'INSTALL.cmd',
        'CONFIGURE-ACCOUNT.cmd',
        'UNINSTALL.cmd',
        'skills\coremail\SKILL.md',
        'skills\web-to-coremail\SKILL.md',
        'mcp\run-server.ps1',
        'mcp\check-python.py',
        'mcp\server.py',
        'mcp\coremail_backend.py',
        'mcp\local_discovery.py',
        'mcp\windows_mapi.py',
        'docs\architecture.md',
        'docs\browser-orchestration.md',
        'scripts\configure-account.ps1',
        'scripts\setup-account.ps1',
        'scripts\uninstall.ps1',
        'tests\smoke-mcp.ps1'
    )
    foreach ($relativePath in $requiredFiles) {
        $requiredPath = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Plugin source is incomplete; missing: $relativePath"
        }
    }

    try {
        $manifest = Get-Content -LiteralPath (Join-Path $Root '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
        $mcp = Get-Content -LiteralPath (Join-Path $Root '.mcp.json') -Raw | ConvertFrom-Json
    }
    catch {
        throw "Plugin JSON validation failed: $($_.Exception.Message)"
    }
    if ($manifest.name -ne 'coremail-controller') {
        throw "Unexpected plugin identity: $($manifest.name)"
    }
    $serverNames = @($mcp.mcpServers.PSObject.Properties.Name)
    if ($serverNames.Count -ne 1 -or $serverNames[0] -ne 'coremail-windows') {
        throw 'The Coremail plugin must declare exactly one MCP server named coremail-windows.'
    }
    return [string]$manifest.version
}

function Copy-PluginTree {
    param([string]$Source, [string]$Destination)

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($directory in @('.claude-plugin', 'skills', 'mcp', 'docs', 'scripts', 'tests')) {
        Copy-Item -LiteralPath (Join-Path $Source $directory) -Destination $Destination -Recurse
    }
    foreach ($file in @(
        '.mcp.json',
        '.gitignore',
        'README.md',
        'START-HERE.md',
        'INSTALL.cmd',
        'CONFIGURE-ACCOUNT.cmd',
        'UNINSTALL.cmd',
        'LICENSE',
        'CHANGELOG.md'
    )) {
        $sourceFile = Join-Path $Source $file
        if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
            Copy-Item -LiteralPath $sourceFile -Destination $Destination
        }
    }
}

function Test-ExistingPluginIdentity {
    param([string]$Root)

    $manifestPath = Join-Path $Root '.claude-plugin\plugin.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Refusing to replace an unrecognized directory without a plugin manifest: $Root"
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Refusing to replace a directory with an unreadable plugin manifest: $Root"
    }
    if ($manifest.name -ne 'coremail-controller') {
        throw "Refusing to replace a plugin with unexpected identity: $($manifest.name)"
    }
    return [string]$manifest.version
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer can run only on Windows.'
    }

    $sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

    Write-Step 1 'Checking the package and local prerequisites'
    $sourceVersion = Test-PluginTree -Root $sourceRoot
    $pythonVersion = Resolve-PythonRuntime -VersionProbePath (
        Join-Path $sourceRoot 'mcp\check-python.py'
    )
    $claudeCommand = Get-Command 'claude' -ErrorAction SilentlyContinue
    if ($null -eq $claudeCommand) {
        Write-Warning 'Claude Code was not found on PATH. The plugin can be installed, but Claude Code must be installed before use.'
    }
    else {
        Write-Host "Claude Code: $($claudeCommand.Source)"
    }
    Write-Host "Plugin version: $sourceVersion"
    Write-Host "Python runtime: $script:PythonCommand ($pythonVersion)"

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw 'The current Windows user profile directory could not be resolved.'
    }
    $claudeRoot = Join-Path $userProfile '.claude'
    $skillsRoot = Join-Path $claudeRoot 'skills'
    $targetRoot = Join-Path $skillsRoot 'coremail-controller'
    $sourceCanonical = $sourceRoot.TrimEnd('\')
    $targetCanonical = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')

    Write-Step 2 'Staging and validating the plugin'
    if ([string]::Equals($sourceCanonical, $targetCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host 'The installer is running from the active plugin directory; file replacement is not required.'
        [void](Test-PluginTree -Root $targetRoot)
        $pluginActivated = $true
    }
    else {
        $stageRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'coremail-controller-install-' + [guid]::NewGuid().ToString('N')
        )
        $stagePlugin = Join-Path $stageRoot 'coremail-controller'
        New-Item -ItemType Directory -Path $stageRoot | Out-Null
        Copy-PluginTree -Source $sourceRoot -Destination $stagePlugin
        [void](Test-PluginTree -Root $stagePlugin)
        Get-ChildItem -LiteralPath $stagePlugin -Recurse -File -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
        & (Join-Path $stagePlugin 'tests\smoke-mcp.ps1') -IgnoreAccountConfiguration

        Write-Step 3 'Activating the plugin and preserving the previous version'
        New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
        $activationStagingRoot = Join-Path $claudeRoot 'plugin-staging'
        New-Item -ItemType Directory -Path $activationStagingRoot -Force | Out-Null
        $activationStageRoot = Join-Path $activationStagingRoot (
            'coremail-controller-' + [guid]::NewGuid().ToString('N')
        )
        $activationPlugin = Join-Path $activationStageRoot 'coremail-controller'
        New-Item -ItemType Directory -Path $activationStageRoot | Out-Null
        Copy-PluginTree -Source $stagePlugin -Destination $activationPlugin
        [void](Test-PluginTree -Root $activationPlugin)
        Get-ChildItem -LiteralPath $activationPlugin -Recurse -File -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $targetRoot) {
            $previousVersion = Test-ExistingPluginIdentity -Root $targetRoot
            $backupDirectory = Join-Path $claudeRoot 'plugin-backups'
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $backupRoot = Join-Path $backupDirectory (
                "coremail-controller-$timestamp-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
            )
            try {
                Move-Item -LiteralPath $targetRoot -Destination $backupRoot
            }
            catch {
                throw "Unable to archive the existing plugin directory '$targetRoot'. Disable coremail-controller@skills-dir, reload or exit Claude Code, and ensure the current Windows user has permission to modify that exact directory. The existing plugin was left unchanged. Windows reported: $($_.Exception.Message)"
            }
            Write-Host "Previous plugin version $previousVersion moved to: $backupRoot"
        }

        try {
            Move-Item -LiteralPath $activationPlugin -Destination $targetRoot
            $activationPlugin = $null
        }
        catch {
            if ($backupRoot -and
                (Test-Path -LiteralPath $backupRoot -PathType Container) -and
                -not (Test-Path -LiteralPath $targetRoot)) {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
                $backupRoot = $null
            }
            throw
        }
        [void](Test-PluginTree -Root $targetRoot)
        $pluginActivated = $true
        Write-Host "Installed plugin: $targetRoot"
    }

    Write-Step 4 'Configuring the mailbox account'
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path $userProfile 'AppData\Roaming'
    }
    $configPath = Join-Path $appData 'ClaudeCode\Coremail\config.json'
    if ($Reconfigure -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        & (Join-Path $targetRoot 'scripts\setup-account.ps1')
    }
    else {
        Write-Host "Existing non-secret account configuration preserved: $configPath"
        Write-Host 'Double-click CONFIGURE-ACCOUNT.cmd whenever account settings need to change.'
    }

    Write-Step 5 'Verifying the installed MCP server'
    $smokeTest = Join-Path $targetRoot 'tests\smoke-mcp.ps1'
    & $smokeTest
    $connectionVerified = $false
    if (-not $SkipConnectionCheck -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            & $smokeTest -TimeoutMilliseconds 60000 -CheckConnection
            $connectionVerified = $true
        }
        catch {
            Write-Warning "The plugin is installed, but the live active-transport check did not pass: $($_.Exception.Message)"
            Write-Warning 'Double-click CONFIGURE-ACCOUNT.cmd to correct the account settings, or ask Claude to check the Coremail connection.'
        }
    }

    $summaryDirectory = Join-Path $appData 'ClaudeCode\Coremail'
    New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
    $summaryPath = Join-Path $summaryDirectory 'INSTALLATION.txt'
    $connectionText = if ($connectionVerified) { 'verified' } else { 'not verified' }
    $summary = @"
Coremail Controller installation

Version: $sourceVersion
Plugin: $targetRoot
Configuration: $configPath
Live connection: $connectionText
Previous plugin backup: $backupRoot

Restart Claude Code or run /reload-plugins.
Use /coremail-controller:coremail for mailbox work.
Use /coremail-controller:web-to-coremail for the isolated browser-to-email workflow.
"@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($summaryPath, $summary, $utf8)

    Write-Host ''
    Write-Host 'Coremail Controller installation completed.' -ForegroundColor Green
    Write-Host "Installation summary: $summaryPath"
    Write-Host 'Restart Claude Code or run /reload-plugins.'
    Write-Host 'Then invoke /coremail-controller:coremail.'
    exit 0
}
catch {
    Write-Host ''
    Write-Host "Setup stopped safely: $($_.Exception.Message)" -ForegroundColor Red
    if ($pluginActivated -and $targetRoot) {
        Write-Host "The plugin files are installed at $targetRoot, but account setup or verification may be incomplete."
        Write-Host 'Run CONFIGURE-ACCOUNT.cmd to resume account setup.'
    }
    elseif ($backupRoot) {
        Write-Host "The previous recognized plugin remains recoverable at $backupRoot"
    }
    exit 1
}
finally {
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot -PathType Container)) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($activationStageRoot -and (Test-Path -LiteralPath $activationStageRoot -PathType Container)) {
        Remove-Item -LiteralPath $activationStageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
