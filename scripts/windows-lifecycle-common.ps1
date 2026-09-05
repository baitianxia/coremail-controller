#requires -Version 5.1

Set-StrictMode -Version 2.0

$script:CoremailLifecycleLogPath = $null

function Initialize-CoremailLifecycleLog {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $script:CoremailLifecycleLogPath = $null
        return
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $parent = Split-Path -Parent $fullPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        $script:CoremailLifecycleLogPath = $fullPath
        Write-CoremailLifecycleLog 'LOG STARTED'
    }
    catch {
        # Diagnostics are best-effort. A protected or malformed log location
        # must not prevent a safe lifecycle operation from running.
        $script:CoremailLifecycleLogPath = $null
        Write-Warning "Persistent lifecycle logging is unavailable: $($_.Exception.Message)"
    }
}

function Write-CoremailLifecycleLog {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:CoremailLifecycleLogPath)) {
        return
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $line = '{0} {1}{2}' -f (
            Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        ), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($script:CoremailLifecycleLogPath, $line, $encoding)
    }
    catch {
        # Diagnostic collection must never hide the original operation result.
    }
}

function Write-CoremailLifecycleFailure {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = 'operation'
    )

    $exceptionType = if ($null -ne $ErrorRecord.Exception) {
        $ErrorRecord.Exception.GetType().FullName
    }
    else { 'unknown' }
    $failureText = 'FAILED context={0}; exception={1}; category={2}; errorId={3}; message={4}' -f `
        $Context, `
        $exceptionType, `
        [string]$ErrorRecord.CategoryInfo.Category, `
        [string]$ErrorRecord.FullyQualifiedErrorId, `
        [string]$ErrorRecord.Exception.Message
    Write-CoremailLifecycleLog $failureText
    if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)) {
        Write-CoremailLifecycleLog ('STACK: ' + [string]$ErrorRecord.ScriptStackTrace)
    }
}

function Invoke-CoremailExternalChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Prefix = @(),
        [string[]]$Arguments = @(),
        [string]$CapturePath = '',
        [string]$Label = 'external command'
    )

    $output = @()
    $errorOutput = @()
    $exitCode = $null
    $nativeErrorPath = Join-Path ([IO.Path]::GetTempPath()) (
        'coremail-native-stderr-' + [guid]::NewGuid().ToString('N') + '.log'
    )
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 promotes redirected native stderr lines to
        # ErrorRecord values. Keep stderr separate so machine-readable stdout
        # (Claude JSON and MAPI probes) cannot be poisoned by a warning.
        $ErrorActionPreference = 'Continue'
        # LASTEXITCODE is maintained in the caller's global/script scope. A
        # local assignment would shadow the value that the native launch sets.
        $global:LASTEXITCODE = $null
        $output = & $Executable @Prefix @Arguments 2> $nativeErrorPath
        $exitCode = $global:LASTEXITCODE
        if (Test-Path -LiteralPath $nativeErrorPath -PathType Leaf) {
            $errorOutput = @(Get-Content -LiteralPath $nativeErrorPath)
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
        if (Test-Path -LiteralPath $nativeErrorPath -PathType Leaf) {
            Remove-Item -LiteralPath $nativeErrorPath -Force -ErrorAction SilentlyContinue
        }
    }
    $lines = @($output | ForEach-Object { [string]$_ })
    foreach ($line in $lines) {
        Write-Host $line
        Write-CoremailLifecycleLog "NATIVE STDOUT label=$Label; $line"
    }
    foreach ($line in @($errorOutput | ForEach-Object { [string]$_ })) {
        Write-Host $line
        Write-CoremailLifecycleLog "NATIVE STDERR label=$Label; $line"
    }
    if (-not [string]::IsNullOrWhiteSpace($CapturePath)) {
        $captureFullPath = [IO.Path]::GetFullPath($CapturePath)
        $captureParent = Split-Path -Parent $captureFullPath
        New-Item -ItemType Directory -Path $captureParent -Force | Out-Null
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $captureFullPath,
            (($lines -join [Environment]::NewLine) + [Environment]::NewLine),
            $encoding
        )
    }
    if ($null -eq $exitCode) {
        throw "$Label did not start or return a native-process exit code."
    }
    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode."
    }
}

function Invoke-CoremailClaudeChecked {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$CapturePath = '',
        [string]$Label = 'Claude Code'
    )

    $autoUpdaterWasPresent = Test-Path -LiteralPath 'Env:DISABLE_AUTOUPDATER'
    $updatesWerePresent = Test-Path -LiteralPath 'Env:DISABLE_UPDATES'
    $previousAutoUpdater = [string]$env:DISABLE_AUTOUPDATER
    $previousUpdates = [string]$env:DISABLE_UPDATES
    try {
        # Lifecycle validation must not trigger an unrelated Claude Code update
        # or network dependency. Restore the caller's environment afterwards.
        $env:DISABLE_AUTOUPDATER = '1'
        $env:DISABLE_UPDATES = '1'
        Invoke-CoremailExternalChecked `
            -Executable ([string]$Invocation.Executable) `
            -Prefix @($Invocation.Prefix) `
            -Arguments $Arguments `
            -CapturePath $CapturePath `
            -Label $Label
    }
    finally {
        if ($autoUpdaterWasPresent) { $env:DISABLE_AUTOUPDATER = $previousAutoUpdater }
        else { Remove-Item Env:DISABLE_AUTOUPDATER -ErrorAction SilentlyContinue }
        if ($updatesWerePresent) { $env:DISABLE_UPDATES = $previousUpdates }
        else { Remove-Item Env:DISABLE_UPDATES -ErrorAction SilentlyContinue }
    }
}

function Get-CoremailClaudeVersion {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [string]$Label = 'Claude Code version probe'
    )

    $capturePath = Join-Path ([IO.Path]::GetTempPath()) (
        'coremail-claude-version-' + [guid]::NewGuid().ToString('N') + '.txt'
    )
    try {
        Invoke-CoremailClaudeChecked `
            -Invocation $Invocation `
            -Arguments @('--version') `
            -CapturePath $capturePath `
            -Label $Label
        $versionText = [IO.File]::ReadAllText($capturePath)
    }
    finally {
        if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
            Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        }
    }
    $match = [regex]::Match(
        $versionText,
        '(?<![0-9])([0-9]+)\.([0-9]+)\.([0-9]+)(?![0-9])'
    )
    if (-not $match.Success) {
        throw (
            "$Label did not report a semantic Claude Code version. " +
            'The installed Claude executable cannot be validated safely.'
        )
    }
    $versionTextValue = '{0}.{1}.{2}' -f @(
        $match.Groups[1].Value,
        $match.Groups[2].Value,
        $match.Groups[3].Value
    )
    $version = [Version]::Parse($versionTextValue)
    Write-CoremailLifecycleLog "CLAUDE VERSION label=$Label; version=$version"
    return [pscustomobject]@{
        Version = $version
        Text = $versionText.Trim()
    }
}

function Assert-CoremailClaudeMinimumVersion {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [string]$MinimumVersion = '2.1.157',
        [string]$Label = 'Claude Code version probe'
    )

    try { $minimum = [Version]::Parse($MinimumVersion) }
    catch { throw "The lifecycle minimum Claude Code version is invalid: $MinimumVersion" }
    $observed = Get-CoremailClaudeVersion -Invocation $Invocation -Label $Label
    if ($observed.Version -lt $minimum) {
        throw (
            "Claude Code $($observed.Version) is not supported by this release. " +
            "Claude Code $minimum or newer is required for skills-directory plugins. " +
            'Upgrade Claude Code with its official installer, then run INSTALL.cmd again. ' +
            'No plugin files or Claude settings were changed.'
        )
    }
    return $observed
}

function Assert-CoremailDefaultClaudeConfigDirectory {
    param([Parameter(Mandatory = $true)][string]$UserProfile)

    if ([string]::IsNullOrWhiteSpace([string]$env:CLAUDE_CONFIG_DIR)) { return }
    $expected = [IO.Path]::GetFullPath((Join-Path $UserProfile '.claude')).TrimEnd('\')
    $configured = $null
    try { $configured = [IO.Path]::GetFullPath([string]$env:CLAUDE_CONFIG_DIR).TrimEnd('\') }
    catch { throw 'CLAUDE_CONFIG_DIR must be unset or point to the default per-user .claude directory.' }
    if (-not [string]::Equals(
        $configured,
        $expected,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (
            'This release installs only into the default per-user Claude directory. ' +
            "Unset CLAUDE_CONFIG_DIR for this process or set it to: $expected"
        )
    }
}

function Save-CoremailFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $wasPresent = Test-Path -LiteralPath $fullPath -PathType Leaf
    $backupPath = $null
    if ($wasPresent) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        $backupPath = Join-Path $BackupDirectory (
            $Label + '-' + [guid]::NewGuid().ToString('N') + '.backup'
        )
        [IO.File]::Copy($fullPath, $backupPath, $false)
    }
    return [pscustomobject]@{
        Path = $fullPath
        WasPresent = $wasPresent
        BackupPath = $backupPath
    }
}

function Test-CoremailRetryableDirectoryMoveError {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($ErrorRecord.CategoryInfo.Category -eq
        [Management.Automation.ErrorCategory]::PermissionDenied) {
        return $true
    }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [UnauthorizedAccessException] -or
            $exception -is [IO.IOException]) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Test-CoremailAccessDeniedError {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($ErrorRecord.CategoryInfo.Category -eq
        [Management.Automation.ErrorCategory]::PermissionDenied) {
        return $true
    }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [UnauthorizedAccessException] -or
            $exception -is [System.Security.SecurityException]) {
            return $true
        }
        # Win32 ERROR_ACCESS_DENIED may surface through IOException or
        # Win32Exception. The low 16 bits of HRESULT preserve that code.
        if (($exception.HResult -band 0xFFFF) -eq 5) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Move-CoremailDirectoryAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$OperationLabel,
        [ValidateRange(1, 100)][int]$MaximumAttempts = 25,
        [scriptblock]$AccessDeniedRepair = $null,
        [ValidateRange(1, 100)][int]$RepairAfterAttempt = 5
    )

    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if ([IO.Path]::GetPathRoot($sourcePath) -ine
        [IO.Path]::GetPathRoot($destinationPath)) {
        throw "$OperationLabel requires source and destination on the same volume."
    }

    $delayMilliseconds = 250
    $accessDeniedRepairAttempted = $false
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            [IO.Directory]::Move($sourcePath, $destinationPath)
            if (Test-Path -LiteralPath $sourcePath) {
                throw "$OperationLabel returned success but the source still exists: $sourcePath"
            }
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
                throw "$OperationLabel returned success but the destination is absent: $destinationPath"
            }
            if ($attempt -gt 1) {
                Write-Host "$OperationLabel recovered after $attempt attempts." -ForegroundColor Green
                Write-CoremailLifecycleLog (
                    "DIRECTORY MOVE RECOVERED operation=$OperationLabel; attempts=$attempt; destination=$destinationPath"
                )
            }
            else {
                Write-CoremailLifecycleLog (
                    "DIRECTORY MOVE COMPLETED operation=$OperationLabel; destination=$destinationPath"
                )
            }
            return
        }
        catch {
            $moveError = $_
            $sourcePresent = Test-Path -LiteralPath $sourcePath -PathType Container
            $destinationPresent = Test-Path -LiteralPath $destinationPath -PathType Container
            if (-not $sourcePresent -and $destinationPresent) {
                Write-CoremailLifecycleLog (
                    "DIRECTORY MOVE RECOVERED operation=$OperationLabel; completed-while-reporting-error; destination=$destinationPath"
                )
                return
            }
            if (-not $sourcePresent -or $destinationPresent) {
                throw (
                    "$OperationLabel entered an ambiguous state; no retry or cleanup was attempted. " +
                    "sourcePresent=$sourcePresent; destinationPresent=$destinationPresent; " +
                    "error=$($moveError.Exception.Message)"
                )
            }
            if (-not (Test-CoremailRetryableDirectoryMoveError -ErrorRecord $moveError)) {
                throw
            }
            if (-not $accessDeniedRepairAttempted -and
                $null -ne $AccessDeniedRepair -and
                $attempt -ge $RepairAfterAttempt -and
                (Test-CoremailAccessDeniedError -ErrorRecord $moveError)) {
                $accessDeniedRepairAttempted = $true
                Write-CoremailLifecycleLog (
                    "DIRECTORY MOVE ACCESS REPAIR operation=$OperationLabel; attempt=$attempt"
                )
                & $AccessDeniedRepair
                $delayMilliseconds = 250
                continue
            }
            if ($attempt -ge $MaximumAttempts) {
                throw (
                    "$OperationLabel remained blocked after $MaximumAttempts attempts. " +
                    "The source remains intact and the destination was not created. " +
                    "Original error: $($moveError.Exception.Message)"
                )
            }
            if ($attempt -eq 1) {
                Write-Host "$OperationLabel is temporarily blocked; setup will wait and continue automatically." -ForegroundColor Yellow
            }
            Write-CoremailLifecycleLog (
                "DIRECTORY MOVE RETRY operation=$OperationLabel; attempt=$attempt/$MaximumAttempts; error=$($moveError.Exception.Message)"
            )
            Start-Sleep -Milliseconds $delayMilliseconds
            $delayMilliseconds = [Math]::Min($delayMilliseconds * 2, 5000)
        }
    }
}

function Enter-CoremailLifecycleLock {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    try {
        $stream = [IO.File]::Open(
            $fullPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        throw "Another Coremail Controller install, upgrade, or uninstall is already running for this Windows user."
    }
    Write-CoremailLifecycleLog "LIFECYCLE LOCK ACQUIRED path=$fullPath"
    return $stream
}

function Exit-CoremailLifecycleLock {
    param(
        [IO.Stream]$Stream,
        [string]$Path
    )

    if ($null -ne $Stream) {
        try { $Stream.Dispose() }
        catch { Write-CoremailLifecycleLog "WARNING lifecycle lock release failed: $($_.Exception.Message)" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Path) -and
        (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try { [IO.File]::Delete([IO.Path]::GetFullPath($Path)) }
        catch { Write-CoremailLifecycleLog "WARNING lifecycle lock file cleanup failed: $($_.Exception.Message)" }
    }
}

function Assert-CoremailSafeClaudePath {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $profilePath = [IO.Path]::GetFullPath($UserProfile).TrimEnd('\')
    $candidatePath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($profilePath -notmatch '^[A-Za-z]:\\' -or
        $candidatePath -notmatch '^[A-Za-z]:\\') {
        throw 'Coremail Controller V1 requires a local-drive Windows user profile.'
    }
    $prefix = $profilePath + '\'
    if (-not $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Lifecycle path is outside the current Windows user profile: $candidatePath"
    }

    $relative = $candidatePath.Substring($prefix.Length)
    $cursor = $profilePath
    foreach ($segment in @($relative -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { continue }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Lifecycle path traverses an unsupported link or junction: $cursor"
        }
    }
    return $candidatePath
}

function Assert-CoremailSafeDescendantPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'managed path'
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidatePath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $prefix = $rootPath + '\'
    if (-not $candidatePath.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Label is outside its system-resolved root: $candidatePath"
    }

    $cursor = $rootPath
    if (Test-Path -LiteralPath $cursor) {
        $rootItem = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label root is an unsupported link or junction: $cursor"
        }
    }
    foreach ($segment in @($candidatePath.Substring($prefix.Length) -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { continue }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label traverses an unsupported link or junction: $cursor"
        }
    }
    return $candidatePath
}

function Get-CoremailExactChildDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or
        $Name -in @('.', '..') -or
        $Name.IndexOfAny([char[]]'\/') -ge 0) {
        throw 'An exact lifecycle child name is required.'
    }
    $parentPath = [IO.Path]::GetFullPath($Parent)
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        return $null
    }
    $matches = @([IO.Directory]::EnumerateFileSystemEntries($parentPath) |
        Where-Object {
            [string]::Equals(
                [IO.Path]::GetFileName($_),
                $Name,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -ne 1) {
        throw "The lifecycle parent contains an ambiguous '$Name' entry."
    }
    $entryPath = [IO.Path]::GetFullPath([string]$matches[0])
    $attributes = [IO.File]::GetAttributes($entryPath)
    if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
        throw "The expected plugin path is not a directory: $entryPath"
    }
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The expected plugin path is a link or junction: $entryPath"
    }
    return $entryPath
}

function Request-CoremailLegacyPluginPermissionRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [switch]$Disabled
    )

    $profilePath = [IO.Path]::GetFullPath($UserProfile).TrimEnd('\')
    $targetPath = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $expectedTarget = [IO.Path]::GetFullPath(
        (Join-Path $profilePath '.claude\skills\coremail-controller')
    ).TrimEnd('\')
    if (-not [string]::Equals(
        $targetPath,
        $expectedTarget,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Legacy permission repair was refused for an unexpected path.'
    }

    $skillsRoot = Split-Path -Parent $targetPath
    [void](Assert-CoremailSafeClaudePath -UserProfile $profilePath -Path $skillsRoot)
    try {
        $entryPath = Get-CoremailExactChildDirectory `
            -Parent $skillsRoot `
            -Name 'coremail-controller'
    }
    catch {
        if (-not (Test-CoremailAccessDeniedError -ErrorRecord $_)) { throw }
        # The final entry may deny READ_ATTRIBUTES. The elevated command below uses
        # /L, so even a last-component link cannot redirect the grant to its target;
        # ordinary-user path checks still run again after access is restored.
        $entryPath = $targetPath
    }
    if ([string]::IsNullOrWhiteSpace([string]$entryPath)) {
        throw 'Legacy permission repair was refused because the exact plugin directory is absent.'
    }
    if ($Disabled) {
        throw (
            'The legacy plugin directory denies the current user access, and automatic ' +
            'permission repair was disabled. An administrator must grant this user Modify ' +
            "on the exact directory before retrying: $targetPath"
        )
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User
    if ($null -eq $sid -or -not $sid.IsAccountSid()) {
        throw 'Legacy permission repair requires a normal Windows account SID.'
    }

    Write-CoremailLifecycleLog "LEGACY ACL REPAIR REQUESTED target=$targetPath; sid=$($sid.Value)"
    Write-Host ''
    Write-Warning 'A withdrawn Coremail Controller release left its exact plugin directory inaccessible to this Windows user.'
    Write-Host "Target: $targetPath"
    Write-Host "Account SID: $($sid.Value)"

    # A secure-desktop consent click cannot be automated on a hosted runner. The
    # release gate uses this marker-only branch to prove the same standard-user
    # process waits for access restoration and then continues. It grants no rights.
    $gateRequest = [string]$env:COREMAIL_GATE_PERMISSION_REPAIR_REQUEST
    $gateComplete = [string]$env:COREMAIL_GATE_PERMISSION_REPAIR_COMPLETE
    if ($env:COREMAIL_RELEASE_GATE_TESTING -eq 'true' -and
        -not [string]::IsNullOrWhiteSpace($gateRequest) -and
        -not [string]::IsNullOrWhiteSpace($gateComplete)) {
        $runnerTemp = [IO.Path]::GetFullPath([string]$env:RUNNER_TEMP).TrimEnd('\')
        $requestPath = [IO.Path]::GetFullPath($gateRequest)
        $completePath = [IO.Path]::GetFullPath($gateComplete)
        $runnerPrefix = $runnerTemp + '\'
        foreach ($markerPath in @($requestPath, $completePath)) {
            if (-not $markerPath.StartsWith(
                $runnerPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'Release-gate permission repair marker is outside RUNNER_TEMP.'
            }
        }
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($requestPath, $targetPath + [Environment]::NewLine, $encoding)
        for ($gateAttempt = 1; $gateAttempt -le 300; $gateAttempt++) {
            if (Test-Path -LiteralPath $completePath -PathType Leaf) {
                Write-CoremailLifecycleLog 'LEGACY ACL REPAIR RECOVERED mode=release-gate-handshake'
                return
            }
            Start-Sleep -Milliseconds 100
        }
        throw 'The release-gate legacy permission repair handshake timed out.'
    }

    $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
        throw 'The protected Windows icacls.exe utility is unavailable.'
    }
    $grant = '*{0}:(OI)(CI)M' -f $sid.Value
    $argumentText = '"{0}" /grant {1} /L /Q' -f $targetPath, $grant
    Write-Host 'Windows will now request one UAC approval for this exact ACL grant.' -ForegroundColor Yellow
    try {
        $repairProcess = Start-Process `
            -FilePath $icacls `
            -ArgumentList $argumentText `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -ErrorAction Stop
    }
    catch {
        throw "Legacy plugin permission repair was cancelled or could not start: $($_.Exception.Message)"
    }
    try { $repairExitCode = $repairProcess.ExitCode }
    finally { $repairProcess.Dispose() }
    if ($repairExitCode -ne 0) {
        throw "Windows permission repair failed with icacls exit code $repairExitCode."
    }

    $repairedEntry = Get-CoremailExactChildDirectory `
        -Parent $skillsRoot `
        -Name 'coremail-controller'
    if ([string]::IsNullOrWhiteSpace([string]$repairedEntry)) {
        throw 'The plugin directory disappeared during permission repair; no lifecycle move was attempted.'
    }
    [void](Assert-CoremailSafeClaudePath -UserProfile $profilePath -Path $targetPath)
    Write-CoremailLifecycleLog 'LEGACY ACL REPAIR RECOVERED mode=system-icacls'
}

function Publish-CoremailFileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if ([IO.Path]::GetPathRoot($sourcePath) -ine
        [IO.Path]::GetPathRoot($destinationPath)) {
        throw 'Atomic file publication requires source and destination on the same volume.'
    }
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        [IO.File]::Replace($sourcePath, $destinationPath, $null, $true)
    }
    else {
        [IO.File]::Move($sourcePath, $destinationPath)
    }
    if (Test-Path -LiteralPath $sourcePath) {
        throw "Atomic file publication left the source in place: $sourcePath"
    }
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        throw "Atomic file publication did not create the destination: $destinationPath"
    }
}

function Restore-CoremailFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][bool]$WasPresent,
        [string]$BackupPath
    )

    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if ($WasPresent) {
        if ([string]::IsNullOrWhiteSpace($BackupPath) -or
            -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            throw "Rollback backup is missing: $BackupPath"
        }
        $parent = Split-Path -Parent $destinationPath
        $temporary = Join-Path $parent ('.coremail-restore-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::Copy([IO.Path]::GetFullPath($BackupPath), $temporary, $false)
        Publish-CoremailFileAtomically -Source $temporary -Destination $destinationPath
    }
    elseif (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        [IO.File]::Delete($destinationPath)
    }
}
