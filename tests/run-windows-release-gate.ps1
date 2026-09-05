#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PluginRoot,
    [Parameter(Mandatory = $true)][string]$PythonCommand,
    [Parameter(Mandatory = $true)][string]$ClaudeCommand,
    [string]$NodeCommand = '',
    [ValidateSet('native', 'npm')][string]$ScenarioName = 'native'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'The Windows release gate can run only on Windows.' }
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) { throw 'Windows PowerShell 5.1 is required.' }
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'The release gate requires a GitHub-hosted runner.' }
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The gate orchestrator requires the hosted administrator token to create its disposable standard user.' }

$PluginRoot = [IO.Path]::GetFullPath($PluginRoot)
$PythonCommand = [IO.Path]::GetFullPath($PythonCommand)
$ClaudeCommand = [IO.Path]::GetFullPath($ClaudeCommand)
foreach ($required in @($PluginRoot, $PythonCommand, $ClaudeCommand)) { if (-not (Test-Path -LiteralPath $required -PathType Leaf -ErrorAction SilentlyContinue) -and $required -ne $PluginRoot) { throw "Gate prerequisite is unavailable: $required" } }
if ($ScenarioName -eq 'npm') {
    if (-not $NodeCommand) { throw 'The npm scenario requires -NodeCommand.' }
    $NodeCommand = [IO.Path]::GetFullPath($NodeCommand)
    if (-not (Test-Path -LiteralPath $NodeCommand -PathType Leaf)) { throw "Node executable not found: $NodeCommand" }
}
$manifestPath = Join-Path $PluginRoot '.claude-plugin\plugin.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Packaged plugin root is invalid: $PluginRoot" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.name -ne 'coremail-controller' -or [string]$manifest.version -ne '0.9.0') { throw 'The packaged plugin manifest has an unexpected identity.' }

. (Join-Path $PluginRoot 'scripts\windows-lifecycle-common.ps1')

$suffix = [guid]::NewGuid().ToString('N')
$userName = 'cmgate' + $suffix.Substring(0, 10)
$passwordText = 'Cc9!' + $suffix + 'zZ7!'
$securePassword = ConvertTo-SecureString $passwordText -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("$env:COMPUTERNAME\$userName", $securePassword)
$passwordText = $null
$gateRoot = Join-Path 'C:\Users\Public' ('coremail-gate-' + $ScenarioName + '-' + $suffix)
$stagedPlugin = Join-Path $gateRoot 'plugin'
$standardTemp = Join-Path $gateRoot 'temp'
$stdoutPath = Join-Path $gateRoot 'stdout.log'
$stderrPath = Join-Path $gateRoot 'stderr.log'
$expectedUserProfile = Join-Path (Join-Path $env:SystemDrive 'Users') $userName
$userCreated = $false
$process = $null
$utf8 = New-Object System.Text.UTF8Encoding($false)

try {
    $localUser = New-LocalUser -Name $userName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description "Disposable Coremail $ScenarioName release-gate user"
    $userCreated = $true
    New-Item -ItemType Directory -Path $gateRoot -Force | Out-Null
    Copy-Item -LiteralPath $PluginRoot -Destination $stagedPlugin -Recurse
    New-Item -ItemType Directory -Path $standardTemp -Force | Out-Null

    if ($ScenarioName -eq 'native') {
        $claudeFixtureRoot = Join-Path $gateRoot 'claude-native'
        New-Item -ItemType Directory -Path $claudeFixtureRoot -Force | Out-Null
        $stagedClaudeCommand = Join-Path $claudeFixtureRoot 'claude.exe'
        [IO.File]::Copy($ClaudeCommand, $stagedClaudeCommand, $false)
    }
    else {
        $claudeSourceRoot = Split-Path -Parent $ClaudeCommand
        $claudeFixtureRoot = Join-Path $gateRoot 'claude-npm'
        $sourcePackageRoot = Join-Path $claudeSourceRoot 'node_modules\@anthropic-ai\claude-code'
        if (-not (Test-Path -LiteralPath $sourcePackageRoot -PathType Container)) { throw "npm Claude package root not found: $sourcePackageRoot" }
        $stagedPackageParent = Join-Path $claudeFixtureRoot 'node_modules\@anthropic-ai'
        New-Item -ItemType Directory -Path $stagedPackageParent -Force | Out-Null
        [IO.File]::Copy($ClaudeCommand, (Join-Path $claudeFixtureRoot 'claude.cmd'), $false)
        Copy-Item -LiteralPath $sourcePackageRoot -Destination (Join-Path $stagedPackageParent 'claude-code') -Recurse
        [IO.File]::Copy($NodeCommand, (Join-Path $claudeFixtureRoot 'node.exe'), $false)
        $stagedClaudeCommand = Join-Path $claudeFixtureRoot 'claude.cmd'
    }

    $gateAcl = Get-Acl -LiteralPath $gateRoot
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($localUser.SID, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    [void]$gateAcl.AddAccessRule($accessRule)
    Set-Acl -LiteralPath $gateRoot -AclObject $gateAcl

    $lifecycleScript = Join-Path $stagedPlugin 'tests\windows-lifecycle.ps1'
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentText = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', "`"$lifecycleScript`"",
        '-PluginRoot', "`"$stagedPlugin`"", '-RunnerTemp', "`"$standardTemp`"",
        '-PythonCommand', "`"$PythonCommand`"", '-ClaudeCommand', "`"$stagedClaudeCommand`"",
        '-ExpectedIdentitySid', $localUser.SID.Value, '-ScenarioName', $ScenarioName,
        '-OrchestratorVerifiedHostedRunner'
    ) -join ' '
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $argumentText -Credential $credential -LoadUserProfile -WorkingDirectory $gateRoot -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    $processHandle = $process.Handle
    if ($processHandle -eq [IntPtr]::Zero) { throw 'The standard-user lifecycle process did not expose a usable handle.' }
    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    while (-not $process.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) { throw "The $ScenarioName standard-user lifecycle gate exceeded 30 minutes." }
        Start-Sleep -Milliseconds 100
    }
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath | ForEach-Object { Write-Host $_ } }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host $_ -ForegroundColor Red } }
    if ($null -eq $exitCode -or $exitCode -ne 0) { throw "The $ScenarioName standard-user lifecycle gate failed with exit code $exitCode." }
    Write-Host "Disposable standard-user Windows lifecycle gate passed: $ScenarioName" -ForegroundColor Green
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    if ($userCreated) {
        try { Remove-LocalUser -Name $userName -ErrorAction Stop }
        catch { Write-Warning "Unable to remove disposable local user '$userName': $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $gateRoot -PathType Container) { Remove-Item -LiteralPath $gateRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($null -ne $securePassword) { $securePassword.Dispose() }
}
