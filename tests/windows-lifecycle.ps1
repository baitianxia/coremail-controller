#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PluginRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunnerTemp,
    [Parameter(Mandatory = $true)]
    [string]$PythonCommand,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedIdentitySid,
    [Parameter(Mandatory = $true)]
    [switch]$OrchestratorVerifiedHostedRunner
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The Windows lifecycle gate can run only on Windows.'
}
if (-not $OrchestratorVerifiedHostedRunner) {
    throw 'The Windows lifecycle gate must be launched by the verified hosted-runner orchestrator.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop' -or
    $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -lt 1) {
    throw "Windows PowerShell 5.1 is required; found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
}

$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.User.Value -ne $ExpectedIdentitySid) {
    throw "The lifecycle gate is running as an unexpected Windows identity: $($currentIdentity.Name)"
}
$currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
if ($currentPrincipal.IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw 'Install and uninstall lifecycle checks must run as a standard Windows user, not an administrator.'
}

$RunnerTemp = [IO.Path]::GetFullPath($RunnerTemp)
$PythonCommand = [IO.Path]::GetFullPath($PythonCommand)
if (-not (Test-Path -LiteralPath $RunnerTemp -PathType Container)) {
    throw "The standard-user temporary directory is unavailable: $RunnerTemp"
}
if (-not (Test-Path -LiteralPath $PythonCommand -PathType Leaf)) {
    throw "The selected Python executable is unavailable to the standard user: $PythonCommand"
}
$env:RUNNER_TEMP = $RunnerTemp
$env:TEMP = $RunnerTemp
$env:TMP = $RunnerTemp
$env:COREMAIL_PYTHON = $PythonCommand

$PluginRoot = [IO.Path]::GetFullPath($PluginRoot)
$manifestPath = Join-Path $PluginRoot '.claude-plugin\plugin.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Packaged plugin manifest not found: $manifestPath"
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell executable not found: $windowsPowerShell"
}

$userProfile = [Environment]::GetFolderPath('UserProfile')
$appData = [Environment]::GetFolderPath('ApplicationData')
if ([string]::IsNullOrWhiteSpace($userProfile) -or
    [string]::IsNullOrWhiteSpace($appData) -or
    -not (Test-Path -LiteralPath $userProfile -PathType Container)) {
    throw 'The ephemeral runner profile paths could not be resolved.'
}
$env:USERPROFILE = $userProfile
$env:APPDATA = $appData
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $env:LOCALAPPDATA = $localAppData
}
$claudeRoot = Join-Path $userProfile '.claude'
$targetRoot = Join-Path $claudeRoot 'skills\coremail-controller'
$configDirectory = Join-Path $appData 'ClaudeCode\Coremail'
$configPath = Join-Path $configDirectory 'config.json'

if (Test-Path -LiteralPath $targetRoot) {
    throw "Refusing to overwrite an unexpected CI runner plugin directory: $targetRoot"
}
if (Test-Path -LiteralPath $configPath) {
    throw "Refusing to overwrite an unexpected CI runner mailbox configuration: $configPath"
}

function Invoke-WindowsPowerShellScript {
    param(
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @()
    )

    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -File $ScriptPath @ScriptArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell script failed with exit code $LASTEXITCODE`: $ScriptPath"
    }
}

function Assert-ConfigUnchanged {
    param([string]$ExpectedHash)

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Mailbox configuration was removed: $configPath"
    }
    $actualHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash) {
        throw 'Mailbox configuration changed during the plugin lifecycle test.'
    }
}

Write-Host '[gate 1/7] Parsing every packaged PowerShell script with Windows PowerShell 5.1'
$parseFailures = @()
foreach ($scriptFile in (Get-ChildItem -LiteralPath $PluginRoot -Filter '*.ps1' -File -Recurse)) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $scriptFile.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        $parseFailures += "$($scriptFile.FullName): $($parseError.Message)"
    }
}
if ($parseFailures.Count -gt 0) {
    throw "PowerShell parse failures:`n$($parseFailures -join "`n")"
}

Write-Host '[gate 2/7] Compiling the packaged Windows Credential Manager helper'
$setupText = Get-Content -LiteralPath (Join-Path $PluginRoot 'scripts\setup-account.ps1') -Raw
$credentialPattern = '(?ms)^[ \t]*\$credentialSource[ \t]*=[ \t]*@''\r?\n(?<source>.*?)\r?\n''@[ \t]*$'
$credentialMatch = [regex]::Match($setupText, $credentialPattern)
if (-not $credentialMatch.Success) {
    throw 'Unable to extract the credential helper C# source from setup-account.ps1.'
}
Add-Type -TypeDefinition $credentialMatch.Groups['source'].Value -Language CSharp | Out-Null

Write-Host '[gate 3/7] Creating a non-secret offline configuration fixture'
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$fixture = [ordered]@{
    transport = 'windows_simple_mapi'
    username = 'ci-fixture@example.invalid'
    allowed_from = @('ci-fixture@example.invalid')
    sent_copy_mode = 'none'
    attachment_roots = @()
}
$fixtureJson = $fixture | ConvertTo-Json -Depth 8
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($configPath, $fixtureJson, $utf8)
$fixtureHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash

$installer = Join-Path $PluginRoot 'scripts\install.ps1'
$uninstaller = Join-Path $PluginRoot 'scripts\uninstall.ps1'

Write-Host '[gate 4/7] Installing from the packaged tree and starting the nested MCP smoke test'
Invoke-WindowsPowerShellScript -ScriptPath $installer -ScriptArguments @('-SkipConnectionCheck')
if (-not (Test-Path -LiteralPath (Join-Path $targetRoot '.claude-plugin\plugin.json') -PathType Leaf)) {
    throw "Installer did not activate the plugin: $targetRoot"
}
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
Invoke-WindowsPowerShellScript -ScriptPath (Join-Path $targetRoot 'tests\smoke-mcp.ps1')

Write-Host '[gate 5/7] Reinstalling over the active version to exercise transactional backup'
Invoke-WindowsPowerShellScript -ScriptPath $installer -ScriptArguments @('-SkipConnectionCheck')
$backupDirectory = Join-Path $claudeRoot 'plugin-backups'
$recognizedBackups = @(
    Get-ChildItem -LiteralPath $backupDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName '.claude-plugin\plugin.json') -PathType Leaf
        }
)
if ($recognizedBackups.Count -lt 1) {
    throw 'Reinstallation did not create a recoverable previous-plugin backup.'
}
Assert-ConfigUnchanged -ExpectedHash $fixtureHash

Write-Host '[gate 6/7] Uninstalling without elevation and verifying preservation'
Invoke-WindowsPowerShellScript -ScriptPath $uninstaller
if (Test-Path -LiteralPath $targetRoot) {
    throw "Uninstaller left the active plugin directory in place: $targetRoot"
}
$disabledDirectory = Join-Path $claudeRoot 'plugins-disabled'
$recognizedDisabledCopies = @(
    Get-ChildItem -LiteralPath $disabledDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName '.claude-plugin\plugin.json') -PathType Leaf
        }
)
if ($recognizedDisabledCopies.Count -lt 1) {
    throw 'Uninstaller did not create a recoverable disabled-plugin copy.'
}
Assert-ConfigUnchanged -ExpectedHash $fixtureHash

Write-Host '[gate 7/7] Reinstalling after uninstall and repeating clean removal'
Invoke-WindowsPowerShellScript -ScriptPath $installer -ScriptArguments @('-SkipConnectionCheck')
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
Invoke-WindowsPowerShellScript -ScriptPath $uninstaller
if (Test-Path -LiteralPath $targetRoot) {
    throw 'The final uninstall left an active plugin directory.'
}
Assert-ConfigUnchanged -ExpectedHash $fixtureHash

Write-Host 'Windows PowerShell 5.1 packaged lifecycle gate passed.' -ForegroundColor Green
