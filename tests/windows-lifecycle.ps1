#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PluginRoot,
    [Parameter(Mandatory = $true)][string]$RunnerTemp,
    [Parameter(Mandatory = $true)][string]$PythonCommand,
    [Parameter(Mandatory = $true)][string]$ClaudeCommand,
    [Parameter(Mandatory = $true)][string]$ExpectedIdentitySid,
    [ValidateSet('native', 'npm')][string]$ScenarioName,
    [Parameter(Mandatory = $true)][string]$PermissionRepairRequestPath,
    [Parameter(Mandatory = $true)][string]$PermissionRepairCompletePath,
    [Parameter(Mandatory = $true)][switch]$OrchestratorVerifiedHostedRunner
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The Windows lifecycle gate can run only on Windows.'
}
if (-not $OrchestratorVerifiedHostedRunner) {
    throw 'The gate must be launched by the verified hosted-runner orchestrator.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop' -or
    $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -lt 1) {
    throw "Windows PowerShell 5.1 is required; found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
}
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.User.Value -ne $ExpectedIdentitySid) {
    throw "The lifecycle gate is running as an unexpected Windows identity: $($currentIdentity.Name)"
}
$currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Lifecycle checks must run as a standard Windows user.'
}

$RunnerTemp = [IO.Path]::GetFullPath($RunnerTemp)
$PythonCommand = [IO.Path]::GetFullPath($PythonCommand)
$ClaudeCommand = [IO.Path]::GetFullPath($ClaudeCommand)
$PermissionRepairRequestPath = [IO.Path]::GetFullPath($PermissionRepairRequestPath)
$PermissionRepairCompletePath = [IO.Path]::GetFullPath($PermissionRepairCompletePath)
foreach ($required in @($RunnerTemp, $PythonCommand, $ClaudeCommand)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Gate prerequisite is unavailable: $required" }
}
$runnerPrefix = $RunnerTemp.TrimEnd('\') + '\'
foreach ($markerPath in @($PermissionRepairRequestPath, $PermissionRepairCompletePath)) {
    if (-not $markerPath.StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A permission-repair marker is outside the disposable runner directory.'
    }
}
$env:RUNNER_TEMP = $RunnerTemp
$env:TEMP = $RunnerTemp
$env:TMP = $RunnerTemp
$env:DISABLE_AUTOUPDATER = '1'
$env:DISABLE_UPDATES = '1'
$env:COREMAIL_RELEASE_GATE_TESTING = 'true'
Remove-Item Env:COREMAIL_PYTHON -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue

$PluginRoot = [IO.Path]::GetFullPath($PluginRoot)
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$userProfile = [Environment]::GetFolderPath('UserProfile')
$appData = [Environment]::GetFolderPath('ApplicationData')
if ([string]::IsNullOrWhiteSpace($userProfile) -or
    [string]::IsNullOrWhiteSpace($appData) -or
    -not (Test-Path -LiteralPath $userProfile -PathType Container)) {
    throw 'The disposable user profile paths could not be resolved.'
}
$env:USERPROFILE = $userProfile
$env:APPDATA = $appData
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not [string]::IsNullOrWhiteSpace($localAppData)) { $env:LOCALAPPDATA = $localAppData }

$claudeRoot = Join-Path $userProfile '.claude'
$targetRoot = Join-Path $claudeRoot 'skills\coremail-controller'
$configDirectory = Join-Path $appData 'ClaudeCode\Coremail'
$configPath = Join-Path $configDirectory 'config.json'
$installer = Join-Path $PluginRoot 'scripts\install.ps1'
$uninstaller = Join-Path $PluginRoot 'scripts\uninstall.ps1'
$installLog = Join-Path $RunnerTemp "INSTALL-$ScenarioName.log"
$reinstallLog = Join-Path $RunnerTemp "REINSTALL-$ScenarioName.log"
$uninstallLog = Join-Path $RunnerTemp "UNINSTALL-$ScenarioName.log"
$commonScript = Join-Path $PluginRoot 'scripts\windows-lifecycle-common.ps1'
$discoveryScript = Join-Path $PluginRoot 'scripts\windows-tool-discovery.ps1'
. $commonScript
. $discoveryScript
$utf8 = New-Object System.Text.UTF8Encoding($false)

if ((Test-Path -LiteralPath $targetRoot) -or
    (Test-Path -LiteralPath $configPath)) {
    throw 'The disposable profile unexpectedly contains Coremail state.'
}

function Invoke-WindowsPowerShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [switch]$ExpectFailure,
        [string]$ExpectedText = ''
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -File `
            $ScriptPath @ScriptArguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $text = (@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    foreach ($line in @($output)) { if ($null -ne $line) { Write-Host ([string]$line) } }
    if ($ExpectFailure) {
        if ($exitCode -eq 0) { throw "Expected script failure but it exited successfully: $ScriptPath" }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedText) -and $text -notmatch [regex]::Escape($ExpectedText)) {
            throw "Expected failure text '$ExpectedText' was absent from: $text"
        }
        return
    }
    if ($exitCode -ne 0) {
        throw "Windows PowerShell script failed with exit code $exitCode`: $ScriptPath`n$text"
    }
}

function Invoke-ExactClaude {
    param([string[]]$Arguments, [string]$CapturePath = '')
    $invocation = Resolve-ClaudeCodeInvocation -ExplicitPath $ClaudeCommand
    if ($null -eq $invocation -or [string]$invocation.Kind -ne $ScenarioName) {
        throw "Claude resolver did not select the exact $ScenarioName fixture."
    }
    if ($ScenarioName -eq 'npm' -and [string]$invocation.NpmBinKind -ne 'native') {
        throw 'The pinned current npm fixture did not resolve its package-declared native PE.'
    }
    Invoke-CoremailClaudeChecked `
        -Invocation $invocation `
        -Arguments $Arguments `
        -CapturePath $CapturePath `
        -Label "Claude $ScenarioName fixture"
}

function Assert-ConfigUnchanged {
    param([string]$ExpectedHash)
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Mailbox configuration was removed: $configPath"
    }
    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $ExpectedHash) {
        throw 'Mailbox configuration changed during the lifecycle test.'
    }
}

function Assert-ExactClaudePlugin {
    param([ValidateSet('enabled', 'disabled')][string]$State)
    $inventory = Join-Path $RunnerTemp (
        'inventory-' + $State + '-' + [guid]::NewGuid().ToString('N') + '.json'
    )
    Invoke-ExactClaude -Arguments @('plugin', 'list', '--json') -CapturePath $inventory
    & $PythonCommand -B -I (Join-Path $targetRoot 'scripts\verify-claude-plugin-list.py') `
        $inventory `
        --plugin-id 'coremail-controller@skills-dir' `
        --version '0.7.1' `
        --expected-path $targetRoot `
        --state $State
    if ($LASTEXITCODE -ne 0) { throw "Claude plugin state verification failed: $State" }
}

function Get-ClaudePluginSettingsOverride {
    $settingsPayload = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $enabledPluginsProperty = $settingsPayload.PSObject.Properties['enabledPlugins']
    if ($null -eq $enabledPluginsProperty -or $null -eq $enabledPluginsProperty.Value) {
        return [pscustomobject]@{ Present = $false; Value = $null }
    }
    $pluginProperty = $enabledPluginsProperty.Value.PSObject.Properties[
        'coremail-controller@skills-dir'
    ]
    if ($null -eq $pluginProperty) {
        return [pscustomobject]@{ Present = $false; Value = $null }
    }
    if ($pluginProperty.Value -isnot [bool]) {
        throw 'Claude settings contain a non-boolean Coremail plugin override.'
    }
    return [pscustomobject]@{ Present = $true; Value = [bool]$pluginProperty.Value }
}

Write-Host "[gate 1/11][$ScenarioName] Parsing all packaged PowerShell and compiling Credential Manager helper"
$parseFailures = @()
foreach ($scriptFile in (Get-ChildItem -LiteralPath $PluginRoot -Filter '*.ps1' -File -Recurse)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $scriptFile.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        $parseFailures += "$($scriptFile.FullName): $($parseError.Message)"
    }
}
if ($parseFailures.Count -gt 0) { throw "PowerShell parse failures:`n$($parseFailures -join "`n")" }
$credentialText = Get-Content -LiteralPath (Join-Path $PluginRoot 'scripts\windows-credential.ps1') -Raw
$credentialPattern = '(?ms)^[ \t]*\$credentialSource[ \t]*=[ \t]*@''\r?\n(?<source>.*?)\r?\n''@[ \t]*\r?$'
$credentialMatch = [regex]::Match($credentialText, $credentialPattern)
if (-not $credentialMatch.Success) { throw 'Unable to extract the credential helper C# source.' }
Add-Type -TypeDefinition $credentialMatch.Groups['source'].Value -Language CSharp | Out-Null

Write-Host "[gate 2/11][$ScenarioName] Verifying package integrity, metadata, direct MCP, and real Claude validation"
& $PythonCommand -B -I (Join-Path $PluginRoot 'scripts\verify-release.py') `
    $PluginRoot --require-windows-gate
if ($LASTEXITCODE -ne 0) { throw 'Packaged internal integrity verification failed.' }
& (Join-Path $PluginRoot 'tests\smoke-mcp.ps1') `
    -IgnoreAccountConfiguration -PythonExecutable $PythonCommand
Invoke-ExactClaude -Arguments @('--version')
Invoke-ExactClaude -Arguments @('plugin', 'validate', $PluginRoot, '--strict')
if ($ScenarioName -eq 'npm') {
    $legacyResolverRoot = Join-Path $RunnerTemp 'legacy-node-backed-npm'
    $legacyPackageRoot = Join-Path $legacyResolverRoot 'node_modules\@anthropic-ai\claude-code'
    New-Item -ItemType Directory -Path $legacyPackageRoot -Force | Out-Null
    [IO.File]::Copy(
        (Join-Path (Split-Path -Parent $ClaudeCommand) 'node.exe'),
        (Join-Path $legacyResolverRoot 'node.exe'),
        $false
    )
    [IO.File]::WriteAllText((Join-Path $legacyResolverRoot 'claude.cmd'), '@echo off', $utf8)
    $legacyPackage = [ordered]@{
        name = '@anthropic-ai/claude-code'
        version = 'legacy-resolver-fixture'
        bin = [ordered]@{ claude = 'cli.js' }
    }
    [IO.File]::WriteAllText(
        (Join-Path $legacyPackageRoot 'package.json'),
        ($legacyPackage | ConvertTo-Json -Depth 5),
        $utf8
    )
    [IO.File]::WriteAllText(
        (Join-Path $legacyPackageRoot 'cli.js'),
        "console.error('legacy-stderr-is-separated'); console.log('legacy-node-resolver-ok')`n",
        $utf8
    )
    $legacyInvocation = Resolve-ClaudeCodeInvocation `
        -ExplicitPath (Join-Path $legacyResolverRoot 'claude.cmd')
    if ($null -eq $legacyInvocation -or
        [string]$legacyInvocation.Kind -ne 'npm' -or
        [string]$legacyInvocation.NpmBinKind -ne 'node') {
        throw 'The legacy Node-backed npm Claude resolver path was not selected.'
    }
    $legacyOutput = Join-Path $RunnerTemp 'legacy-node-resolver.txt'
    Invoke-CoremailExternalChecked `
        -Executable ([string]$legacyInvocation.Executable) `
        -Prefix @($legacyInvocation.Prefix) `
        -Arguments @('--version') `
        -CapturePath $legacyOutput `
        -Label 'Legacy Node-backed npm resolver fixture'
    if ((Get-Content -LiteralPath $legacyOutput -Raw).Trim() -ne 'legacy-node-resolver-ok') {
        throw 'The legacy Node-backed npm resolver executed the wrong entry point.'
    }
}
$corruptRoot = Join-Path $RunnerTemp 'corrupt-package'
Copy-Item -LiteralPath $PluginRoot -Destination $corruptRoot -Recurse
[IO.File]::AppendAllText((Join-Path $corruptRoot 'README.md'), "`ncorruption")
$corruptVerifierError = Join-Path $RunnerTemp 'corrupt-verifier-stderr.txt'
$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    & $PythonCommand -B -I (Join-Path $corruptRoot 'scripts\verify-release.py') `
        $corruptRoot --require-windows-gate 2> $corruptVerifierError
    $corruptVerifierExitCode = $global:LASTEXITCODE
}
finally { $ErrorActionPreference = $previousPreference }
if ($corruptVerifierExitCode -eq 0) {
    throw 'The internal verifier accepted a corrupted package.'
}
if ($corruptVerifierExitCode -ne 2) {
    throw "The corrupt-package verifier returned unexpected exit code $corruptVerifierExitCode."
}
$corruptVerifierText = (Get-Content -LiteralPath $corruptVerifierError -Raw).Trim()
if ($corruptVerifierText -notmatch 'size mismatch: README\.md') {
    throw "The corrupt-package verifier failed for an unexpected reason: $corruptVerifierText"
}
Write-Host 'Corrupted package was rejected for the injected README.md size mismatch.'

Write-Host "[gate 3/11][$ScenarioName] Creating non-secret config and a previously-disabled Claude state"
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$fixture = [ordered]@{
    transport = 'windows_simple_mapi'
    username = 'ci-fixture@example.invalid'
    allowed_from = @('ci-fixture@example.invalid')
    sent_copy_mode = 'none'
    attachment_roots = @()
}
[IO.File]::WriteAllText($configPath, ($fixture | ConvertTo-Json -Depth 8), $utf8)
$fixtureHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
New-Item -ItemType Directory -Path $claudeRoot -Force | Out-Null
$initialSettings = [ordered]@{ enabledPlugins = [ordered]@{ 'coremail-controller@skills-dir' = $false } }
$settingsPath = Join-Path $claudeRoot 'settings.json'
[IO.File]::WriteAllText($settingsPath, ($initialSettings | ConvertTo-Json -Depth 8), $utf8)
$settingsHashBeforeCustomRoot = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
$env:CLAUDE_CONFIG_DIR = Join-Path $RunnerTemp 'unsupported-custom-claude-root'
try {
    Invoke-WindowsPowerShellScript -ScriptPath $installer -ExpectFailure `
        -ExpectedText 'default per-user Claude directory' `
        -ScriptArguments @(
            '-SkipConnectionCheck',
            '-PythonExecutable', $PythonCommand,
            '-ClaudeCommand', $ClaudeCommand,
            '-LogPath', (Join-Path $RunnerTemp "CUSTOM-CLAUDE-ROOT-$ScenarioName.log")
        )
}
finally { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
if ((Test-Path -LiteralPath $targetRoot) -or
    (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -ne $settingsHashBeforeCustomRoot) {
    throw 'Rejected custom Claude root changed plugin or settings state.'
}
Assert-ConfigUnchanged -ExpectedHash $fixtureHash

Write-Host "[gate 4/11][$ScenarioName] Installing as a standard user and proving Claude re-enablement"
Invoke-WindowsPowerShellScript -ScriptPath $installer -ScriptArguments @(
    '-SkipConnectionCheck',
    '-PythonExecutable', $PythonCommand,
    '-ClaudeCommand', $ClaudeCommand,
    '-LogPath', $installLog
)
if (-not (Test-Path -LiteralPath (Join-Path $targetRoot '.claude-plugin\plugin.json') -PathType Leaf)) {
    throw "Installer did not activate the plugin: $targetRoot"
}
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
$runtime = Get-Content -LiteralPath (Join-Path $targetRoot 'mcp\python-runtime.json') -Raw |
    ConvertFrom-Json
if ([string]$runtime.executable_sha256 -ine
    (Get-FileHash -LiteralPath $PythonCommand -Algorithm SHA256).Hash) {
    throw 'Installed Python runtime is not pinned to the selected executable hash.'
}
$pluginOverride = Get-ClaudePluginSettingsOverride
if ($pluginOverride.Present -and -not $pluginOverride.Value) {
    throw 'Installer did not reverse the persisted disabled state.'
}
Assert-ExactClaudePlugin -State enabled
& (Join-Path $targetRoot 'tests\smoke-mcp.ps1')
if ((Get-Content -LiteralPath $installLog -Raw) -notmatch 'INSTALLATION COMMITTED') {
    throw 'Persistent install log does not contain the commit marker.'
}

Write-Host "[gate 5/11][$ScenarioName] Reinstalling over the active version and preserving a backup"
Invoke-WindowsPowerShellScript -ScriptPath $installer -ScriptArguments @(
    '-SkipConnectionCheck',
    '-PythonExecutable', $PythonCommand,
    '-ClaudeCommand', $ClaudeCommand,
    '-LogPath', $reinstallLog
)
$backupDirectory = Join-Path $claudeRoot 'plugin-backups'
$recognizedBackups = @(Get-ChildItem -LiteralPath $backupDirectory -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.claude-plugin\plugin.json') -PathType Leaf })
if ($recognizedBackups.Count -lt 1) { throw 'Reinstallation did not preserve a previous-plugin backup.' }
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
Assert-ExactClaudePlugin -State enabled

Write-Host "[gate 6/11][$ScenarioName] Rejecting a concurrent lifecycle without mutation"
$lockPath = Join-Path $claudeRoot 'coremail-controller.lifecycle.lock'
$lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$targetHashBeforeLock = (Get-FileHash -LiteralPath (Join-Path $targetRoot '.claude-plugin\plugin.json') -Algorithm SHA256).Hash
$settingsHashBeforeLock = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
try {
    Invoke-WindowsPowerShellScript -ScriptPath $installer -ExpectFailure `
        -ExpectedText 'Another Coremail Controller install, upgrade, or uninstall is already running' `
        -ScriptArguments @(
            '-SkipConnectionCheck',
            '-PythonExecutable', $PythonCommand,
            '-ClaudeCommand', $ClaudeCommand,
            '-LogPath', (Join-Path $RunnerTemp "LOCK-$ScenarioName.log")
        )
}
finally { $lockStream.Dispose() }
if ((Get-FileHash -LiteralPath (Join-Path $targetRoot '.claude-plugin\plugin.json') -Algorithm SHA256).Hash -ne $targetHashBeforeLock -or
    (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -ne $settingsHashBeforeLock) {
    throw 'Lock contention changed plugin or Claude settings state.'
}

Write-Host "[gate 7/11][$ScenarioName] Rolling back a credential/config fault exactly"
$credentialScript = Join-Path $targetRoot 'scripts\windows-credential.ps1'
. $credentialScript
$credentialTarget = 'ClaudeCode.Coremail:rollback@example.invalid:' + [guid]::NewGuid().ToString('N')
$securePassword = ConvertTo-SecureString ('Gate9!' + [guid]::NewGuid().ToString('N')) -AsPlainText -Force
try {
    try {
        & (Join-Path $targetRoot 'scripts\setup-account.ps1') `
            -Transport imap_smtp `
            -Username 'rollback@example.invalid' `
            -ImapHost 'imap.example.invalid' `
            -SmtpHost 'smtp.example.invalid' `
            -CredentialTarget $credentialTarget `
            -Password $securePassword `
            -NonInteractive `
            -TestFailurePoint after_credential_write `
            -LogPath (Join-Path $RunnerTemp "ACCOUNT-ROLLBACK-$ScenarioName.log")
        throw 'Injected account failure unexpectedly succeeded.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'Injected release-gate failure') { throw }
    }
}
finally { $securePassword.Dispose() }
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
if (Test-CoremailCredential -Target $credentialTarget) {
    throw 'Failed account transaction left the new credential behind.'
}

Write-Host "[gate 8/11][$ScenarioName] Recovering automatically from a real ACL-denied directory move"
$moveLog = Join-Path $RunnerTemp "MOVE-RETRY-$ScenarioName.log"
Initialize-CoremailLifecycleLog -Path $moveLog
$moveParent = Join-Path $userProfile ('coremail-move-fixture-' + [guid]::NewGuid().ToString('N'))
$moveSource = Join-Path $moveParent 'source'
$moveDestination = Join-Path $moveParent 'destination'
New-Item -ItemType Directory -Path $moveSource -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $moveSource 'marker.txt'), 'fixture', $utf8)
$sourceAcl = Get-Acl -LiteralPath $moveSource
$parentAcl = Get-Acl -LiteralPath $moveParent
$sourceSddl = $sourceAcl.GetSecurityDescriptorSddlForm('All')
$parentSddl = $parentAcl.GetSecurityDescriptorSddlForm('All')
$denySource = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $currentIdentity.User,
    'Delete',
    'Deny'
)
$denyParent = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $currentIdentity.User,
    'DeleteSubdirectoriesAndFiles',
    'Deny'
)
[void]$sourceAcl.AddAccessRule($denySource)
[void]$parentAcl.AddAccessRule($denyParent)
Set-Acl -LiteralPath $moveSource -AclObject $sourceAcl
Set-Acl -LiteralPath $moveParent -AclObject $parentAcl
$restoreFixture = Join-Path $RunnerTemp ('acl-' + [guid]::NewGuid().ToString('N') + '.json')
$restoreScript = Join-Path $RunnerTemp ('restore-acl-' + [guid]::NewGuid().ToString('N') + '.ps1')
$restorePayload = [ordered]@{
    source = $moveSource
    parent = $moveParent
    source_sddl = $sourceSddl
    parent_sddl = $parentSddl
}
[IO.File]::WriteAllText($restoreFixture, ($restorePayload | ConvertTo-Json -Depth 4), $utf8)
$restoreSource = @'
param([string]$Fixture)
$ErrorActionPreference = 'Stop'
Start-Sleep -Milliseconds 1200
$data = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json
$sourceAcl = New-Object System.Security.AccessControl.DirectorySecurity
$sourceAcl.SetSecurityDescriptorSddlForm([string]$data.source_sddl)
Set-Acl -LiteralPath ([string]$data.source) -AclObject $sourceAcl
$parentAcl = New-Object System.Security.AccessControl.DirectorySecurity
$parentAcl.SetSecurityDescriptorSddlForm([string]$data.parent_sddl)
Set-Acl -LiteralPath ([string]$data.parent) -AclObject $parentAcl
'@
[IO.File]::WriteAllText($restoreScript, $restoreSource, $utf8)
$restoreProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', "`"$restoreScript`"",
    '-Fixture', "`"$restoreFixture`""
) -WindowStyle Hidden -PassThru
try {
    Move-CoremailDirectoryAtomically `
        -Source $moveSource `
        -Destination $moveDestination `
        -OperationLabel 'Release-gate ACL move'
    if (-not $restoreProcess.WaitForExit(10000) -or $restoreProcess.ExitCode -ne 0) {
        throw 'The ACL restoration helper did not complete successfully.'
    }
}
finally {
    if (-not $restoreProcess.HasExited) { $restoreProcess.Kill() }
    $restoreProcess.Dispose()
    $restoreAcl = New-Object System.Security.AccessControl.DirectorySecurity
    $restoreAcl.SetSecurityDescriptorSddlForm($parentSddl)
    Set-Acl -LiteralPath $moveParent -AclObject $restoreAcl -ErrorAction SilentlyContinue
    $survivingSource = if (Test-Path -LiteralPath $moveSource) { $moveSource } else { $moveDestination }
    if (Test-Path -LiteralPath $survivingSource) {
        $restoreAcl = New-Object System.Security.AccessControl.DirectorySecurity
        $restoreAcl.SetSecurityDescriptorSddlForm($sourceSddl)
        Set-Acl -LiteralPath $survivingSource -AclObject $restoreAcl -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath $moveDestination -PathType Container) -or
    (Test-Path -LiteralPath $moveSource)) {
    throw 'ACL retry fixture did not complete the directory move.'
}
$moveLogText = Get-Content -LiteralPath $moveLog -Raw
if ($moveLogText -notmatch 'DIRECTORY MOVE RETRY' -or $moveLogText -notmatch 'DIRECTORY MOVE RECOVERED') {
    throw 'ACL retry evidence is missing from the persistent log.'
}

Write-Host "[gate 9/11][$ScenarioName] Recovering a legacy ACL, then reversibly uninstalling through real Claude"
$legacyManifestPath = Join-Path $targetRoot '.claude-plugin\plugin.json'
$originalTargetAcl = Get-Acl -LiteralPath $targetRoot
$originalTargetSddl = $originalTargetAcl.GetSecurityDescriptorSddlForm('All')
$restrictedTargetAcl = Get-Acl -LiteralPath $targetRoot
$restrictedTargetAcl.SetAccessRuleProtection($true, $false)
foreach ($existingRule in @($restrictedTargetAcl.GetAccessRules(
    $true,
    $true,
    [Security.Principal.SecurityIdentifier]
))) {
    [void]$restrictedTargetAcl.RemoveAccessRuleSpecific($existingRule)
}
$inheritanceFlags = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
$propagationFlags = [Security.AccessControl.PropagationFlags]::None
$allowType = [Security.AccessControl.AccessControlType]::Allow
foreach ($principalSid in @(
    (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),
    (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))
)) {
    $fullControlRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $principalSid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritanceFlags,
        $propagationFlags,
        $allowType
    )
    [void]$restrictedTargetAcl.AddAccessRule($fullControlRule)
}

$settingsHashBeforeLegacyDenial = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
try {
    Set-Acl -LiteralPath $targetRoot -AclObject $restrictedTargetAcl
    $legacyReadDenied = $false
    try { [void][IO.File]::ReadAllText($legacyManifestPath) }
    catch [UnauthorizedAccessException] { $legacyReadDenied = $true }
    catch {
        if (($_.Exception.HResult -band 0xFFFF) -eq 5) { $legacyReadDenied = $true }
        else { throw }
    }
    if (-not $legacyReadDenied) {
        throw 'The legacy ACL fixture did not deny ordinary-user manifest access.'
    }

    Invoke-WindowsPowerShellScript -ScriptPath $uninstaller -ExpectFailure `
        -ExpectedText 'automatic permission repair was disabled' `
        -ScriptArguments @(
            '-NoLegacyPermissionRepair',
            '-ClaudeCommand', $ClaudeCommand,
            '-LogPath', (Join-Path $RunnerTemp "LEGACY-ACL-DISABLED-$ScenarioName.log")
        )
    if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        throw 'Disabled legacy ACL repair moved the active plugin.'
    }
    if ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -ne
        $settingsHashBeforeLegacyDenial) {
        throw 'Disabled legacy ACL repair changed Claude plugin state.'
    }

    $env:COREMAIL_GATE_PERMISSION_REPAIR_REQUEST = $PermissionRepairRequestPath
    $env:COREMAIL_GATE_PERMISSION_REPAIR_COMPLETE = $PermissionRepairCompletePath

    Invoke-WindowsPowerShellScript -ScriptPath $uninstaller -ScriptArguments @(
        '-ClaudeCommand', $ClaudeCommand,
        '-LogPath', $uninstallLog
    )
}
finally {
    Remove-Item Env:COREMAIL_GATE_PERMISSION_REPAIR_REQUEST -ErrorAction SilentlyContinue
    Remove-Item Env:COREMAIL_GATE_PERMISSION_REPAIR_COMPLETE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $targetRoot -PathType Container) {
        $restoreTargetAcl = New-Object System.Security.AccessControl.DirectorySecurity
        $restoreTargetAcl.SetSecurityDescriptorSddlForm($originalTargetSddl)
        Set-Acl -LiteralPath $targetRoot -AclObject $restoreTargetAcl -ErrorAction SilentlyContinue
    }
}
if (Test-Path -LiteralPath $targetRoot) { throw 'Uninstaller left the active plugin directory in place.' }
if (-not (Test-Path -LiteralPath $PermissionRepairRequestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $PermissionRepairCompletePath -PathType Leaf)) {
    throw 'The administrator permission-repair handshake markers are incomplete.'
}
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
$pluginOverride = Get-ClaudePluginSettingsOverride
if (-not $pluginOverride.Present -or $pluginOverride.Value -ne $false) {
    throw 'Uninstaller did not persist the disabled plugin state.'
}
if ((Get-Content -LiteralPath $uninstallLog -Raw) -notmatch 'UNINSTALL COMMITTED') {
    throw 'Persistent uninstall log does not contain the commit marker.'
}
$uninstallLogText = Get-Content -LiteralPath $uninstallLog -Raw
if ($uninstallLogText -notmatch 'LEGACY ACL REPAIR REQUESTED' -or
    $uninstallLogText -notmatch 'LEGACY ACL REPAIR RECOVERED mode=release-gate-handshake') {
    throw 'Legacy ACL recovery evidence is missing from the uninstall log.'
}

Write-Host "[gate 10/11][$ScenarioName] Reinstalling after disable and proving re-enable again"
Invoke-WindowsPowerShellScript -ScriptPath $installer -ScriptArguments @(
    '-SkipConnectionCheck',
    '-PythonExecutable', $PythonCommand,
    '-ClaudeCommand', $ClaudeCommand,
    '-LogPath', (Join-Path $RunnerTemp "FINAL-INSTALL-$ScenarioName.log")
)
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
Assert-ExactClaudePlugin -State enabled

Write-Host "[gate 11/11][$ScenarioName] Repeating clean removal and preservation"
$installedUninstaller = Join-Path $targetRoot 'scripts\uninstall.ps1'
Invoke-WindowsPowerShellScript -ScriptPath $installedUninstaller -ScriptArguments @(
    '-ClaudeCommand', $ClaudeCommand,
    '-LogPath', (Join-Path $RunnerTemp "FINAL-UNINSTALL-$ScenarioName.log")
)
if (Test-Path -LiteralPath $targetRoot) { throw 'The final uninstall left an active plugin directory.' }
Assert-ConfigUnchanged -ExpectedHash $fixtureHash
$missingClaude = Join-Path $RunnerTemp 'intentionally-absent-claude.exe'
Invoke-WindowsPowerShellScript -ScriptPath $uninstaller -ScriptArguments @(
    '-ClaudeCommand', $missingClaude,
    '-LogPath', (Join-Path $RunnerTemp "IDEMPOTENT-UNINSTALL-$ScenarioName.log")
)
if (Test-Path -LiteralPath $targetRoot) {
    throw 'Idempotent uninstall unexpectedly recreated the active plugin directory.'
}

Write-Host "Windows PowerShell 5.1 packaged lifecycle gate passed: $ScenarioName" -ForegroundColor Green
