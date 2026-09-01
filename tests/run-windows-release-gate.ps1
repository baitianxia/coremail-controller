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

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The Windows release gate orchestrator can run only on Windows.'
}
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'The Windows release gate requires an ephemeral GitHub-hosted runner.'
}
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The orchestrator needs the hosted runner administrator token to create a disposable standard user.'
}

$PluginRoot = [IO.Path]::GetFullPath($PluginRoot)
$PythonCommand = [IO.Path]::GetFullPath($PythonCommand)
$ClaudeCommand = [IO.Path]::GetFullPath($ClaudeCommand)
foreach ($required in @($PythonCommand, $ClaudeCommand)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Release-gate executable not found: $required"
    }
}
if ($ScenarioName -eq 'npm') {
    if ([string]::IsNullOrWhiteSpace($NodeCommand)) {
        throw 'The npm scenario requires -NodeCommand.'
    }
    $NodeCommand = [IO.Path]::GetFullPath($NodeCommand)
    if (-not (Test-Path -LiteralPath $NodeCommand -PathType Leaf)) {
        throw "Node executable not found: $NodeCommand"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $PluginRoot '.claude-plugin\plugin.json') -PathType Leaf)) {
    throw "Packaged plugin root is invalid: $PluginRoot"
}

$suffix = [guid]::NewGuid().ToString('N')
$userName = 'cmgate' + $suffix.Substring(0, 10)
$passwordText = 'Cc9!' + $suffix + 'zZ7!'
$securePassword = ConvertTo-SecureString $passwordText -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential(
    "$env:COMPUTERNAME\$userName",
    $securePassword
)
$passwordText = $null
$gateRoot = Join-Path 'C:\Users\Public' ('coremail-gate-' + $ScenarioName + '-' + $suffix)
$stagedPlugin = Join-Path $gateRoot 'plugin'
$standardTemp = Join-Path $gateRoot 'temp'
$stdoutPath = Join-Path $gateRoot 'stdout.log'
$stderrPath = Join-Path $gateRoot 'stderr.log'
$stagedClaudeCommand = $null
$userCreated = $false

try {
    $localUser = New-LocalUser `
        -Name $userName `
        -Password $securePassword `
        -AccountNeverExpires `
        -PasswordNeverExpires `
        -UserMayNotChangePassword `
        -Description "Disposable Coremail $ScenarioName release-gate user"
    $userCreated = $true

    New-Item -ItemType Directory -Path $gateRoot | Out-Null
    Copy-Item -LiteralPath $PluginRoot -Destination $stagedPlugin -Recurse
    New-Item -ItemType Directory -Path $standardTemp | Out-Null
    if ($ScenarioName -eq 'native') {
        $claudeFixtureRoot = Join-Path $gateRoot 'claude-native'
        New-Item -ItemType Directory -Path $claudeFixtureRoot | Out-Null
        $stagedClaudeCommand = Join-Path $claudeFixtureRoot 'claude.exe'
        [IO.File]::Copy($ClaudeCommand, $stagedClaudeCommand, $false)
    }
    else {
        $claudeSourceRoot = Split-Path -Parent $ClaudeCommand
        $claudeFixtureRoot = Join-Path $gateRoot 'claude-npm'
        $sourcePackageRoot = Join-Path $claudeSourceRoot 'node_modules\@anthropic-ai\claude-code'
        $stagedPackageParent = Join-Path $claudeFixtureRoot 'node_modules\@anthropic-ai'
        if (-not (Test-Path -LiteralPath $sourcePackageRoot -PathType Container)) {
            throw "npm Claude package root not found: $sourcePackageRoot"
        }
        New-Item -ItemType Directory -Path $stagedPackageParent -Force | Out-Null
        [IO.File]::Copy(
            $ClaudeCommand,
            (Join-Path $claudeFixtureRoot 'claude.cmd'),
            $false
        )
        Copy-Item `
            -LiteralPath $sourcePackageRoot `
            -Destination (Join-Path $stagedPackageParent 'claude-code') `
            -Recurse
        $stagedClaudeCommand = Join-Path $claudeFixtureRoot 'claude.cmd'
        [IO.File]::Copy($NodeCommand, (Join-Path $claudeFixtureRoot 'node.exe'), $false)
    }

    $gateAcl = Get-Acl -LiteralPath $gateRoot
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $localUser.SID,
        'Modify',
        'ContainerInherit,ObjectInherit',
        'None',
        'Allow'
    )
    [void]$gateAcl.AddAccessRule($accessRule)
    Set-Acl -LiteralPath $gateRoot -AclObject $gateAcl

    $lifecycleScript = Join-Path $stagedPlugin 'tests\windows-lifecycle.ps1'
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentText = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        "`"$lifecycleScript`"",
        '-PluginRoot',
        "`"$stagedPlugin`"",
        '-RunnerTemp',
        "`"$standardTemp`"",
        '-PythonCommand',
        "`"$PythonCommand`"",
        '-ClaudeCommand',
        "`"$stagedClaudeCommand`"",
        '-ExpectedIdentitySid',
        $localUser.SID.Value,
        '-ScenarioName',
        $ScenarioName,
        '-OrchestratorVerifiedHostedRunner'
    ) -join ' '

    $process = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $argumentText `
        -Credential $credential `
        -LoadUserProfile `
        -WorkingDirectory $gateRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -Wait `
        -PassThru

    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        Get-Content -LiteralPath $stdoutPath | ForEach-Object { Write-Host $_ }
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    }
    if ($process.ExitCode -ne 0) {
        throw "The $ScenarioName standard-user lifecycle gate failed with exit code $($process.ExitCode)."
    }
    Write-Host "Disposable standard-user Windows lifecycle gate passed: $ScenarioName" -ForegroundColor Green
}
finally {
    if ($userCreated) {
        try { Remove-LocalUser -Name $userName -ErrorAction Stop }
        catch { Write-Warning "Unable to remove disposable local user '$userName': $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $gateRoot -PathType Container) {
        Remove-Item -LiteralPath $gateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
