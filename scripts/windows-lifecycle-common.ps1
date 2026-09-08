#requires -Version 5.1

Set-StrictMode -Version 2.0

# Shared, user-scoped lifecycle primitives.  This file deliberately contains no
# elevation, ACL repair, desktop automation, or Claude Skill-directory logic.
$script:CoremailLifecycleLogPath = $null

function Initialize-CoremailLifecycleLog {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $script:CoremailLifecycleLogPath = $null
        return
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    # Log paths are supplied by the top-level .cmd entries before the main
    # lifecycle code has established its state directories.  Validate the
    # existing chain first so a pre-created junction cannot redirect the very
    # first write outside the mail assistant root.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [void](Assert-CoremailSafeLocalPath -Path $fullPath -Label 'lifecycle log')
    }
    try {
        $parent = Split-Path -Parent $fullPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        $script:CoremailLifecycleLogPath = $fullPath
        Write-CoremailLifecycleLog 'LOG STARTED'
    }
    catch {
        # Diagnostics are best-effort. A protected log location must not hide
        # the actual lifecycle result.
        $script:CoremailLifecycleLogPath = $null
        Write-Warning "Persistent lifecycle logging is unavailable: $($_.Exception.Message)"
    }
}

function Write-CoremailLifecycleLog {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:CoremailLifecycleLogPath)) { return }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $line = '{0} {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($script:CoremailLifecycleLogPath, $line, $encoding)
    }
    catch { }
}

function Write-CoremailLifecycleFailure {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = 'operation'
    )
    $exceptionType = if ($null -ne $ErrorRecord.Exception) {
        $ErrorRecord.Exception.GetType().FullName
    } else { 'unknown' }
    Write-CoremailLifecycleLog ('FAILED context={0}; exception={1}; category={2}; errorId={3}; message={4}' -f `
        $Context, $exceptionType, [string]$ErrorRecord.CategoryInfo.Category,
        [string]$ErrorRecord.FullyQualifiedErrorId, [string]$ErrorRecord.Exception.Message)
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
        [string]$Label = 'external command',
        [switch]$QuietOnSuccess
    )

    $output = @()
    $errorOutput = @()
    $exitCode = $null
    $nativeErrorPath = Join-Path ([IO.Path]::GetTempPath()) (
        'mail-native-stderr-' + [guid]::NewGuid().ToString('N') + '.log'
    )
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell promotes redirected native stderr to ErrorRecord
        # values. Keep it separate so JSON stdout remains machine-readable.
        $ErrorActionPreference = 'Continue'
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
        if (-not $QuietOnSuccess -or $exitCode -ne 0) { Write-Host $line }
        Write-CoremailLifecycleLog "NATIVE STDOUT label=$Label; $line"
    }
    foreach ($line in @($errorOutput | ForEach-Object { [string]$_ })) {
        if (-not $QuietOnSuccess -or $exitCode -ne 0) { Write-Host $line }
        Write-CoremailLifecycleLog "NATIVE STDERR label=$Label; $line"
    }
    if (-not [string]::IsNullOrWhiteSpace($CapturePath)) {
        $captureFullPath = [IO.Path]::GetFullPath($CapturePath)
        $captureParent = Split-Path -Parent $captureFullPath
        if (-not [string]::IsNullOrWhiteSpace($captureParent)) {
            New-Item -ItemType Directory -Path $captureParent -Force | Out-Null
        }
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($captureFullPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $encoding)
    }
    if ($null -eq $exitCode) { throw "$Label did not return a native-process exit code." }
    if ($exitCode -ne 0) { throw "$Label failed with exit code $exitCode." }
}

function Invoke-CoremailClaudeChecked {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$CapturePath = '',
        [string]$Label = 'Claude Code',
        [switch]$QuietOnSuccess
    )
    $autoUpdaterWasPresent = Test-Path -LiteralPath 'Env:DISABLE_AUTOUPDATER'
    $updatesWerePresent = Test-Path -LiteralPath 'Env:DISABLE_UPDATES'
    $previousAutoUpdater = [string]$env:DISABLE_AUTOUPDATER
    $previousUpdates = [string]$env:DISABLE_UPDATES
    try {
        $env:DISABLE_AUTOUPDATER = '1'
        $env:DISABLE_UPDATES = '1'
        Invoke-CoremailExternalChecked -Executable ([string]$Invocation.Executable) `
            -Prefix @($Invocation.Prefix) -Arguments $Arguments -CapturePath $CapturePath -Label $Label `
            -QuietOnSuccess:$QuietOnSuccess
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
        'mail-claude-version-' + [guid]::NewGuid().ToString('N') + '.txt'
    )
    try {
        Invoke-CoremailClaudeChecked -Invocation $Invocation -Arguments @('--version') `
            -CapturePath $capturePath -Label $Label -QuietOnSuccess
        $versionText = [IO.File]::ReadAllText($capturePath)
    }
    finally {
        if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
            Remove-Item -LiteralPath $capturePath -Force -ErrorAction SilentlyContinue
        }
    }
    $match = [regex]::Match($versionText, '(?<![0-9])([0-9]+)\.([0-9]+)\.([0-9]+)(?![0-9])')
    $version = $null
    if ($match.Success) {
        $version = [Version]::Parse(('{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value))
        Write-CoremailLifecycleLog "CLAUDE VERSION label=$Label; version=$version"
    }
    else { Write-CoremailLifecycleLog "CLAUDE VERSION label=$Label; semantic-version=unavailable" }
    return [pscustomobject]@{ Version = $version; Text = $versionText.Trim() }
}

function Assert-CoremailSafeLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = 'managed path')
    try { $candidate = [IO.Path]::GetFullPath($Path) }
    catch { throw "$Label is not a valid absolute path: $Path" }
    if ($candidate -notmatch '^[A-Za-z]:\\') {
        throw "$Label must be an absolute local-drive Windows path: $candidate"
    }
    $root = [IO.Path]::GetPathRoot($candidate)
    $cursor = $root
    if (Test-Path -LiteralPath $cursor) {
        $rootItem = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label root is an unsupported link or junction: $cursor"
        }
    }
    foreach ($segment in @($candidate.Substring($root.Length) -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { continue }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label traverses an unsupported link or junction: $cursor"
        }
    }
    return $candidate
}

function Resolve-CoremailClaudeUserConfigPath {
    param([Parameter(Mandatory = $true)][string]$UserProfile)
    try {
        $profilePath = [IO.Path]::GetFullPath($UserProfile)
        $profileRoot = [IO.Path]::GetPathRoot($profilePath)
        if (-not [string]::Equals($profilePath, $profileRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $profilePath = $profilePath.TrimEnd('\')
        }
    }
    catch { throw 'The current Windows user profile path is invalid.' }
    if ($profilePath -notmatch '^[A-Za-z]:\\') {
        throw 'Mail assistant requires a local-drive Windows user profile.'
    }
    $configRoot = $profilePath
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CLAUDE_CONFIG_DIR)) {
        $raw = [string]$env:CLAUDE_CONFIG_DIR
        if ($raw.StartsWith('~') -or $raw.StartsWith('\\') -or
            -not [IO.Path]::IsPathRooted($raw) -or $raw -notmatch '^[A-Za-z]:[\\/]') {
            throw 'CLAUDE_CONFIG_DIR must be an absolute local-drive path; relative, ~, and UNC paths are not supported.'
        }
        try { $configRoot = [IO.Path]::GetFullPath($raw).TrimEnd('\') }
        catch { throw 'CLAUDE_CONFIG_DIR must be an absolute local-drive path.' }
    }
    [void](Assert-CoremailSafeLocalPath -Path $configRoot -Label 'Claude configuration directory')
    if (Test-Path -LiteralPath $configRoot -PathType Leaf) {
        throw 'CLAUDE_CONFIG_DIR must name a directory, not an existing file.'
    }
    $configPath = Join-Path $configRoot '.claude.json'
    [void](Assert-CoremailSafeLocalPath -Path $configPath -Label 'Claude user configuration')
    return $configPath
}

function Assert-CoremailSafeDescendantPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'managed path'
    )
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidatePath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($rootPath -notmatch '^[A-Za-z]:\\' -or $candidatePath -notmatch '^[A-Za-z]:\\') {
        throw "$Label must use an absolute local-drive path."
    }
    if (-not $candidatePath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::Equals($candidatePath, $rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label is outside its system-resolved root: $candidatePath"
    }
    # Check only existing components. New children are safe because their
    # parent chain is checked before creation and no link is followed.
    $cursor = $rootPath
    if (Test-Path -LiteralPath $cursor) {
        $rootItem = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label root is an unsupported link or junction: $cursor"
        }
    }
    $relative = if ([string]::Equals($candidatePath, $rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        ''
    } else { $candidatePath.Substring($rootPath.Length + 1) }
    foreach ($segment in @($relative -split '\\')) {
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
        $backupPath = Join-Path $BackupDirectory ($Label + '-' + [guid]::NewGuid().ToString('N') + '.backup')
        [IO.File]::Copy($fullPath, $backupPath, $false)
    }
    return [pscustomobject]@{ Path = $fullPath; WasPresent = $wasPresent; BackupPath = $backupPath }
}

function Test-CoremailRetryableDirectoryMoveError {
    param([Parameter(Mandatory = $true)][Management.Automation.ErrorRecord]$ErrorRecord)
    if ($ErrorRecord.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::PermissionDenied) { return $true }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [UnauthorizedAccessException] -or $exception -is [IO.IOException]) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Test-CoremailAccessDeniedError {
    param([Parameter(Mandatory = $true)][Management.Automation.ErrorRecord]$ErrorRecord)
    if ($ErrorRecord.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::PermissionDenied) { return $true }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [UnauthorizedAccessException] -or $exception -is [Security.SecurityException] -or
            (($exception.HResult -band 0xFFFF) -eq 5)) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Test-CoremailDirectoryPresent {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).PSIsContainer -eq $true) }
    catch {
        if (Test-CoremailAccessDeniedError -ErrorRecord $_) { return $true }
        return $false
    }
}

function Move-CoremailDirectoryAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$OperationLabel,
        [ValidateRange(1, 100)][int]$MaximumAttempts = 25
    )
    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ([IO.Path]::GetPathRoot($sourcePath) -ine [IO.Path]::GetPathRoot($destinationPath)) {
        throw "$OperationLabel requires source and destination on the same volume."
    }
    $delayMilliseconds = 250
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
                throw "$OperationLabel source is missing: $sourcePath"
            }
            if (Test-Path -LiteralPath $destinationPath) {
                throw "$OperationLabel destination already exists; no overwrite was attempted: $destinationPath"
            }
            [IO.Directory]::Move($sourcePath, $destinationPath)
            if (Test-Path -LiteralPath $sourcePath) { throw "$OperationLabel left the source in place: $sourcePath" }
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) { throw "$OperationLabel did not create the destination: $destinationPath" }
            if ($attempt -gt 1) { Write-Host "$OperationLabel recovered after $attempt attempts." -ForegroundColor Green }
            Write-CoremailLifecycleLog "DIRECTORY MOVE COMPLETED operation=$OperationLabel; attempts=$attempt; destination=$destinationPath"
            return
        }
        catch {
            $moveError = $_
            $sourcePresent = Test-CoremailDirectoryPresent -Path $sourcePath
            $destinationPresent = Test-CoremailDirectoryPresent -Path $destinationPath
            if (-not $sourcePresent -and $destinationPresent) {
                Write-CoremailLifecycleLog "DIRECTORY MOVE RECOVERED operation=$OperationLabel; completed-while-reporting-error; destination=$destinationPath"
                return
            }
            if (-not $sourcePresent -or $destinationPresent) {
                throw "$OperationLabel entered an ambiguous state; no retry or cleanup was attempted. sourcePresent=$sourcePresent; destinationPresent=$destinationPresent; error=$($moveError.Exception.Message)"
            }
            if (-not (Test-CoremailRetryableDirectoryMoveError -ErrorRecord $moveError)) { throw }
            if ($attempt -ge $MaximumAttempts) {
                throw "$OperationLabel remained blocked after $MaximumAttempts attempts. The source remains intact and the destination was not created. Original error: $($moveError.Exception.Message)"
            }
            if ($attempt -eq 1) { Write-Host "$OperationLabel is temporarily blocked; setup will wait and continue automatically." -ForegroundColor Yellow }
            Write-CoremailLifecycleLog "DIRECTORY MOVE RETRY operation=$OperationLabel; attempt=$attempt/$MaximumAttempts; error=$($moveError.Exception.Message)"
            Start-Sleep -Milliseconds $delayMilliseconds
            $delayMilliseconds = [Math]::Min($delayMilliseconds * 2, 5000)
        }
    }
}

function Enter-CoremailLifecycleLock {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [void](Assert-CoremailSafeLocalPath -Path $fullPath -Label 'lifecycle lock')
    }
    $parent = Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch { throw 'Another mail assistant lifecycle operation is already running for this Windows user.' }
    Write-CoremailLifecycleLog "LIFECYCLE LOCK ACQUIRED path=$fullPath"
    return $stream
}

function Exit-CoremailLifecycleLock {
    param([IO.Stream]$Stream, [string]$Path)
    if ($null -ne $Stream) {
        try { $Stream.Dispose() } catch { Write-CoremailLifecycleLog "WARNING lifecycle lock release failed: $($_.Exception.Message)" }
        # Keep the zero-byte lock marker. Deleting it after releasing the
        # handle creates a race in which a second lifecycle can acquire a new
        # file and the first process then deletes that second process's lock.
        Write-CoremailLifecycleLog "LIFECYCLE LOCK RELEASED path=$Path"
    }
}

function Publish-CoremailFileAtomically {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if ([IO.Path]::GetPathRoot($sourcePath) -ine [IO.Path]::GetPathRoot($destinationPath)) { throw 'Atomic file publication requires source and destination on the same volume.' }
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) { [IO.File]::Replace($sourcePath, $destinationPath, $null, $true) }
    else { [IO.File]::Move($sourcePath, $destinationPath) }
    if (Test-Path -LiteralPath $sourcePath) { throw "Atomic file publication left the source in place: $sourcePath" }
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) { throw "Atomic file publication did not create the destination: $destinationPath" }
}

function Restore-CoremailFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][bool]$WasPresent,
        [string]$BackupPath
    )
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if ($WasPresent) {
        if ([string]::IsNullOrWhiteSpace($BackupPath) -or -not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) { throw "Snapshot backup is missing for $destinationPath" }
        $temporary = $destinationPath + '.restore-' + [guid]::NewGuid().ToString('N')
        [IO.File]::Copy($BackupPath, $temporary, $false)
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) { [IO.File]::Replace($temporary, $destinationPath, $null, $true) }
        else { [IO.File]::Move($temporary, $destinationPath) }
    }
    elseif (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        [IO.File]::Delete($destinationPath)
    }
}
