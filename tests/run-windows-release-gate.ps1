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
if ($PSVersionTable.PSEdition -ne 'Desktop' -or
    $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -lt 1) {
    throw "Windows PowerShell 5.1 is required; found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
}
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'The Windows release gate requires an ephemeral GitHub-hosted runner.'
}
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The orchestrator needs the hosted runner administrator token for the disposable-user gate.'
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
$sourceManifest = Get-Content -LiteralPath (Join-Path $PluginRoot '.claude-plugin\plugin.json') -Raw |
    ConvertFrom-Json
if ([string]$sourceManifest.name -ne 'coremail-controller' -or
    [string]::IsNullOrWhiteSpace([string]$sourceManifest.version)) {
    throw 'The packaged plugin manifest has an unexpected identity.'
}
$expectedPluginVersion = [string]$sourceManifest.version

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
$permissionRepairRequest = Join-Path $standardTemp 'legacy-permission-request.marker'
$permissionRepairComplete = Join-Path $standardTemp 'legacy-permission-complete.marker'
$expectedUserProfile = Join-Path (Join-Path $env:SystemDrive 'Users') $userName
$expectedPluginTarget = Join-Path $expectedUserProfile '.claude\skills\coremail-controller'
$stagedClaudeCommand = $null
$userCreated = $false
$process = $null
$permissionRepairHandled = $false

function Complete-CoremailGatePermissionRepair {
    param(
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [Parameter(Mandatory = $true)][string]$CompletePath,
        [Parameter(Mandatory = $true)][string]$ExpectedTarget,
        [Parameter(Mandatory = $true)][Security.Principal.SecurityIdentifier]$ExpectedSid,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][string]$DiagnosticRoot
    )

    $requestedTarget = ([IO.File]::ReadAllText($RequestPath)).Trim()
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($requestedTarget).TrimEnd('\'),
        [IO.Path]::GetFullPath($ExpectedTarget).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "The standard-user gate requested permission repair for an unexpected path: $requestedTarget"
    }
    if (-not $ExpectedSid.IsAccountSid()) {
        throw 'The gate permission repair SID is not a normal Windows account SID.'
    }
    $profileRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ExpectedTarget))
    $claudeRoot = Join-Path $profileRoot '.claude'
    $skillsRoot = Join-Path $claudeRoot 'skills'
    foreach ($path in @($profileRoot, $claudeRoot, $skillsRoot, $ExpectedTarget)) {
        $entry = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The gate permission repair path traverses a reparse point: $path"
        }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $ExpectedTarget '.claude-plugin\plugin.json') -Raw |
        ConvertFrom-Json
    if ([string]$manifest.name -ne 'coremail-controller' -or
        [string]$manifest.version -ne $ExpectedVersion) {
        throw 'The inaccessible gate target has an unexpected plugin identity.'
    }
    if (Test-Path -LiteralPath $CompletePath) {
        throw 'The gate permission repair completion marker already exists.'
    }

    $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
        throw 'The protected Windows icacls.exe utility is unavailable to the gate orchestrator.'
    }
    $repairStdout = Join-Path $DiagnosticRoot 'legacy-icacls-stdout.txt'
    $repairStderr = Join-Path $DiagnosticRoot 'legacy-icacls-stderr.txt'
    $grant = '*{0}:(OI)(CI)M' -f $ExpectedSid.Value
    $repairProcess = Start-Process `
        -FilePath $icacls `
        -ArgumentList @("`"$ExpectedTarget`"", '/grant', $grant, '/L', '/Q') `
        -WindowStyle Hidden `
        -RedirectStandardOutput $repairStdout `
        -RedirectStandardError $repairStderr `
        -Wait `
        -PassThru
    try { $repairExitCode = $repairProcess.ExitCode }
    finally { $repairProcess.Dispose() }
    if ($repairExitCode -ne 0) {
        $repairError = if (Test-Path -LiteralPath $repairStderr -PathType Leaf) {
            (Get-Content -LiteralPath $repairStderr -Raw).Trim()
        }
        else { '<no stderr>' }
        throw "The gate icacls permission repair failed with exit code $repairExitCode`: $repairError"
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($CompletePath, 'repaired', $encoding)
    Write-Host "Gate administrator granted exact Modify permission to $($ExpectedSid.Value) on $ExpectedTarget"
}

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
        '-PermissionRepairRequestPath',
        "`"$permissionRepairRequest`"",
        '-PermissionRepairCompletePath',
        "`"$permissionRepairComplete`"",
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
        -PassThru

    $processDeadline = [DateTime]::UtcNow.AddMinutes(30)
    while (-not $process.HasExited) {
        if (-not $permissionRepairHandled -and
            (Test-Path -LiteralPath $permissionRepairRequest -PathType Leaf)) {
            $requestText = [IO.File]::ReadAllText($permissionRepairRequest)
            if (-not [string]::IsNullOrWhiteSpace($requestText)) {
                Complete-CoremailGatePermissionRepair `
                    -RequestPath $permissionRepairRequest `
                    -CompletePath $permissionRepairComplete `
                    -ExpectedTarget $expectedPluginTarget `
                    -ExpectedSid $localUser.SID `
                    -ExpectedVersion $expectedPluginVersion `
                    -DiagnosticRoot $standardTemp
                $permissionRepairHandled = $true
            }
        }
        if ([DateTime]::UtcNow -gt $processDeadline) {
            throw "The $ScenarioName standard-user lifecycle gate exceeded 30 minutes."
        }
        Start-Sleep -Milliseconds 100
    }
    $process.WaitForExit()

    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        Get-Content -LiteralPath $stdoutPath | ForEach-Object { Write-Host $_ }
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    }
    if ($process.ExitCode -ne 0) {
        throw "The $ScenarioName standard-user lifecycle gate failed with exit code $($process.ExitCode)."
    }
    if (-not $permissionRepairHandled -or
        -not (Test-Path -LiteralPath $permissionRepairComplete -PathType Leaf)) {
        throw 'The lifecycle gate did not complete the constrained legacy permission repair handshake.'
    }
    Write-Host "Disposable standard-user Windows lifecycle gate passed: $ScenarioName" -ForegroundColor Green
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
    if ($userCreated) {
        try { Remove-LocalUser -Name $userName -ErrorAction Stop }
        catch { Write-Warning "Unable to remove disposable local user '$userName': $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $gateRoot -PathType Container) {
        Remove-Item -LiteralPath $gateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $securePassword.Dispose()
}
