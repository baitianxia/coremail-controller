#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PluginRoot,
    [Parameter(Mandatory = $true)]
    [string]$PythonCommand
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The Windows release gate orchestrator can run only on Windows.'
}
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'The Windows release gate requires an ephemeral GitHub-hosted runner.'
}

$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw 'The orchestrator needs the hosted runner administrator token to create a disposable standard user.'
}

$PluginRoot = [IO.Path]::GetFullPath($PluginRoot)
$PythonCommand = [IO.Path]::GetFullPath($PythonCommand)
if (-not (Test-Path -LiteralPath $PythonCommand -PathType Leaf)) {
    throw "Python executable not found: $PythonCommand"
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
$gateRoot = Join-Path 'C:\Users\Public' ('coremail-gate-' + $suffix)
$stagedPlugin = Join-Path $gateRoot 'plugin'
$standardTemp = Join-Path $gateRoot 'temp'
$stdoutPath = Join-Path $gateRoot 'stdout.log'
$stderrPath = Join-Path $gateRoot 'stderr.log'
$userCreated = $false

try {
    $localUser = New-LocalUser `
        -Name $userName `
        -Password $securePassword `
        -AccountNeverExpires `
        -PasswordNeverExpires `
        -UserMayNotChangePassword `
        -Description 'Disposable Coremail release-gate standard user'
    $userCreated = $true

    New-Item -ItemType Directory -Path $gateRoot | Out-Null
    Copy-Item -LiteralPath $PluginRoot -Destination $stagedPlugin -Recurse
    New-Item -ItemType Directory -Path $standardTemp | Out-Null

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
    if (-not (Test-Path -LiteralPath $lifecycleScript -PathType Leaf)) {
        throw "Packaged standard-user lifecycle script not found: $lifecycleScript"
    }
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
        '-ExpectedIdentitySid',
        $localUser.SID.Value,
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
        throw "The standard-user lifecycle gate failed with exit code $($process.ExitCode)."
    }

    Write-Host 'Disposable standard-user Windows lifecycle gate passed.' -ForegroundColor Green
}
finally {
    if ($userCreated) {
        try {
            Remove-LocalUser -Name $userName -ErrorAction Stop
        }
        catch {
            Write-Warning "Unable to remove disposable local user '$userName': $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $gateRoot -PathType Container) {
        Remove-Item -LiteralPath $gateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
