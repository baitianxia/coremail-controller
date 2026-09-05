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
    $version = $null
    if ($match.Success) {
        $versionTextValue = '{0}.{1}.{2}' -f @(
            $match.Groups[1].Value,
            $match.Groups[2].Value,
            $match.Groups[3].Value
        )
        $version = [Version]::Parse($versionTextValue)
        Write-CoremailLifecycleLog "CLAUDE VERSION label=$Label; version=$version"
    }
    else {
        # --version is a launch probe and diagnostic only.  A distribution that
        # reports a non-semantic build label is still accepted when the actual
        # user-scope MCP capability probe and registration transaction succeed.
        Write-CoremailLifecycleLog "CLAUDE VERSION label=$Label; semantic-version=unavailable"
    }
    return [pscustomobject]@{
        Version = $version
        Text = $versionText.Trim()
    }
}

function Assert-CoremailSafeLocalPath {
    <#
      Validate a local-drive path and inspect every existing component for a
      reparse point.  Claude's user MCP file may live in CLAUDE_CONFIG_DIR,
      which is intentionally independent from the skills directory.  Keeping
      this check here makes the custom-root support safe without weakening the
      stricter profile-bound checks used for lifecycle directories.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'managed path'
    )

    try { $candidate = [IO.Path]::GetFullPath($Path) }
    catch { throw "$Label is not a valid absolute path: $Path" }
    if ($candidate -notmatch '^[A-Za-z]:\\') {
        throw "$Label must be an absolute local-drive Windows path: $candidate"
    }
    $root = [IO.Path]::GetPathRoot($candidate)
    $cursor = $root
    if (Test-Path -LiteralPath $cursor) {
        try { $rootItem = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
        catch {
            if (Test-CoremailAccessDeniedError -ErrorRecord $_) { throw }
            throw "$Label could not be inspected: $cursor ($($_.Exception.Message))"
        }
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label root is an unsupported link or junction: $cursor"
        }
    }
    $relative = $candidate.Substring($root.Length)
    foreach ($segment in @($relative -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { continue }
        try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
        catch {
            if (Test-CoremailAccessDeniedError -ErrorRecord $_) { throw }
            throw "$Label could not be inspected: $cursor ($($_.Exception.Message))"
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label traverses an unsupported link or junction: $cursor"
        }
    }
    return $candidate
}

function Resolve-CoremailClaudeUserConfigPath {
    <#
      Claude stores user-scope MCP servers in <config-root>\.claude.json.
      With no override, the root is the current user's profile.  Claude's
      documented CLAUDE_CONFIG_DIR override is accepted when it is a local,
      absolute path; relative, tilde, and UNC values fail before mutation.
    #>
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
        throw 'Coremail Controller requires a local-drive Windows user profile.'
    }
    $configRoot = $profilePath
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CLAUDE_CONFIG_DIR)) {
        $raw = [string]$env:CLAUDE_CONFIG_DIR
        if ($raw.StartsWith('~')) {
            throw 'CLAUDE_CONFIG_DIR must be a local absolute path; ~ paths are not supported.'
        }
        if ($raw.StartsWith('\\')) {
            throw 'CLAUDE_CONFIG_DIR must be a local absolute path; UNC paths are not supported.'
        }
        if (-not [IO.Path]::IsPathRooted($raw) -or
            $raw -notmatch '^[A-Za-z]:[\\/]') {
            throw 'CLAUDE_CONFIG_DIR must be a local absolute path; relative paths are not supported.'
        }
        try {
            $configRoot = [IO.Path]::GetFullPath($raw)
            $configRootRoot = [IO.Path]::GetPathRoot($configRoot)
            if (-not [string]::Equals($configRoot, $configRootRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $configRoot = $configRoot.TrimEnd('\')
            }
        }
        catch { throw 'CLAUDE_CONFIG_DIR must be a local absolute path.' }
        if ($configRoot -notmatch '^[A-Za-z]:\\') {
            throw 'CLAUDE_CONFIG_DIR must be a local absolute path; relative paths are not supported.'
        }
    }
    [void](Assert-CoremailSafeLocalPath -Path $configRoot -Label 'Claude configuration directory')
    if (Test-Path -LiteralPath $configRoot -PathType Leaf) {
        throw 'CLAUDE_CONFIG_DIR must name a directory, not an existing file.'
    }
    $configPath = Join-Path $configRoot '.claude.json'
    [void](Assert-CoremailSafeLocalPath -Path $configPath -Label 'Claude user configuration')
    return $configPath
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

function Test-CoremailReleaseGatePermissionRepairMode {
    # The marker handshake is an internal CI boundary.  Production callers
    # must never be able to select it accidentally merely because the general
    # release-testing flag is present.
    return $env:COREMAIL_RELEASE_GATE_TESTING -eq 'true' -and
        -not [string]::IsNullOrWhiteSpace([string]$env:COREMAIL_GATE_PERMISSION_REPAIR_REQUEST) -and
        -not [string]::IsNullOrWhiteSpace([string]$env:COREMAIL_GATE_PERMISSION_REPAIR_COMPLETE)
}

function Test-CoremailDirectoryPresent {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $entry = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ($entry.PSIsContainer -eq $true)
    }
    catch {
        # A protected source can deny READ_ATTRIBUTES to the ordinary token.
        # Treat that state as present so the constrained repair callback gets
        # a chance to run; treating it as absent would create a false
        # ambiguous-state failure before elevation.
        if (Test-CoremailAccessDeniedError -ErrorRecord $_) { return $true }
        return $false
    }
}

function Test-CoremailInteractivePromptAvailable {
    # The hosted release gate and redirected automation must never block on
    # Read-Host.  A normal INSTALL.cmd/UNINSTALL.cmd console remains eligible
    # for the short, user-controlled recovery prompt below.
    if ($env:COREMAIL_RELEASE_GATE_TESTING -eq 'true' -or
        $env:CI -eq 'true' -or
        $env:GITHUB_ACTIONS -eq 'true') {
        return $false
    }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch { return $false }
    return ($null -ne $Host -and $null -ne $Host.UI)
}

function Invoke-CoremailManualDirectoryMoveAssistance {
    <#
      Give a real Windows user a chance to release a handle or repair the
      exact ACL without downloading/repacking the release.  The function never
      deletes, copies, takes ownership, or recursively changes permissions.
      It returns 'moved' when the user action made the atomic move succeed and
      'versioned' when the user chooses the immutable-release fallback or the
      process is non-interactive.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$OperationLabel,
        [switch]$AllowVersionedFallback
    )

    if (-not (Test-CoremailInteractivePromptAvailable)) {
        Write-CoremailLifecycleLog (
            "MANUAL MOVE ASSISTANCE SKIPPED operation=$OperationLabel; reason=noninteractive"
        )
        return 'versioned'
    }

    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $sidText = '<current-user-SID>'
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($null -ne $currentSid) { $sidText = $currentSid.Value }
    }
    catch { }
    Write-Host ''
    Write-Warning (
        "$OperationLabel still cannot access the exact existing directory. " +
        'No files were deleted or overwritten.'
    )
    Write-Host "Source: $sourcePath"
    Write-Host '请先关闭 Claude Code、Explorer 中打开该目录的窗口，以及可能正在扫描该目录的同步/索引程序。'
    Write-Host '如果是 ACL 问题，请让管理员在管理员 PowerShell 中仅对上述目录授予当前用户 Modify：'
    $grantText = '*' + $sidText + ':(OI)(CI)M'
    Write-Host ('icacls.exe "{0}" /grant {1} /L /Q' -f $sourcePath, $grantText)
    if ($AllowVersionedFallback) {
        Write-Host '完成人工处理后按 R 重试；按 V 保留旧目录并直接启用新的不可变版本目录。'
    }
    else {
        Write-Host '完成人工处理后按 R 重试；如果暂时无法处理，请退出并在关闭占用者后再次运行。'
    }

    for ($promptAttempt = 1; $promptAttempt -le 3; $promptAttempt++) {
        try {
            $promptText = if ($AllowVersionedFallback) {
                "[$promptAttempt/3] 输入 R=重试，V=使用不可变版本"
            }
            else {
                "[$promptAttempt/3] 输入 R=重试"
            }
            $choice = (Read-Host $promptText).Trim().ToLowerInvariant()
        }
        catch {
            Write-CoremailLifecycleLog (
                "MANUAL MOVE ASSISTANCE FALLBACK operation=$OperationLabel; reason=prompt-failed"
            )
            return 'versioned'
        }
        if ($AllowVersionedFallback -and $choice -eq 'v') {
            Write-CoremailLifecycleLog (
                "MANUAL MOVE ASSISTANCE FALLBACK operation=$OperationLabel; choice=versioned"
            )
            return 'versioned'
        }
        if ($choice -ne 'r') {
            $validChoices = if ($AllowVersionedFallback) { 'R 或 V' } else { 'R' }
            Write-Host "请输入 $validChoices。" -ForegroundColor Yellow
            continue
        }
        try {
            [IO.Directory]::Move($sourcePath, $destinationPath)
            $sourceAfter = Test-CoremailDirectoryPresent -Path $sourcePath
            $destinationAfter = Test-CoremailDirectoryPresent -Path $destinationPath
            if (-not $sourceAfter -and $destinationAfter) {
                Write-CoremailLifecycleLog (
                    "MANUAL MOVE ASSISTANCE RECOVERED operation=$OperationLabel; destination=$destinationPath"
                )
                Write-Host "$OperationLabel 已在人工处理后完成。" -ForegroundColor Green
                return 'moved'
            }
            throw (
                "$OperationLabel returned an ambiguous postcondition after manual retry; " +
                "sourcePresent=$sourceAfter; destinationPresent=$destinationAfter"
            )
        }
        catch {
            $manualRetryHint = ' 可继续释放占用后再次按 R。'
            if ($AllowVersionedFallback) {
                $manualRetryHint = ' 可继续释放占用后再次按 R，或按 V 继续。'
            }
            Write-Warning (
                "$OperationLabel 仍未完成：$($_.Exception.Message)。" +
                $manualRetryHint
            )
        }
    }
    Write-CoremailLifecycleLog (
        "MANUAL MOVE ASSISTANCE FALLBACK operation=$OperationLabel; reason=retry-window-exhausted"
    )
    return 'versioned'
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
            $sourcePresent = Test-CoremailDirectoryPresent -Path $sourcePath
            $destinationPresent = Test-CoremailDirectoryPresent -Path $destinationPath
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
                # A repair callback may have completed the move itself (for
                # example, a narrowly scoped elevated broker).  Check the
                # postcondition before entering another Directory.Move call;
                # otherwise the next iteration would manufacture a misleading
                # "source not found" error.
                $sourceAfterRepair = Test-CoremailDirectoryPresent -Path $sourcePath
                $destinationAfterRepair = Test-CoremailDirectoryPresent -Path $destinationPath
                if (-not $sourceAfterRepair -and $destinationAfterRepair) {
                    Write-CoremailLifecycleLog (
                        "DIRECTORY MOVE RECOVERED operation=$OperationLabel; completed-by-repair; destination=$destinationPath"
                    )
                    return
                }
                if (-not $sourceAfterRepair -or $destinationAfterRepair) {
                    throw (
                        "$OperationLabel entered an ambiguous state after access repair; " +
                        "no retry or cleanup was attempted. sourcePresent=$sourceAfterRepair; " +
                        "destinationPresent=$destinationAfterRepair"
                    )
                }
                $delayMilliseconds = 250
                continue
            }
            if ($attempt -ge $MaximumAttempts) {
                $repairHint = if ($accessDeniedRepairAttempted) {
                    ' An access repair was attempted; if the error persists, close Claude Code, Explorer, and any security/indexing process using this directory, then retry.'
                }
                else { '' }
                throw (
                    "$OperationLabel remained blocked after $MaximumAttempts attempts. " +
                    "The source remains intact and the destination was not created. " +
                    "Original error: $($moveError.Exception.Message).$repairHint"
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
    # Only the process that successfully acquired the exclusive stream may
    # remove the lock path.  On contention, deleting a lock file in finally
    # could invalidate another lifecycle process's coordination state.
    if ($null -ne $Stream -and
        -not [string]::IsNullOrWhiteSpace($Path) -and
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

    $profilePath = [IO.Path]::GetFullPath($UserProfile)
    $profileRoot = [IO.Path]::GetPathRoot($profilePath)
    if (-not [string]::Equals($profilePath, $profileRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $profilePath = $profilePath.TrimEnd('\')
    }
    $candidatePath = [IO.Path]::GetFullPath($Path)
    $candidateRoot = [IO.Path]::GetPathRoot($candidatePath)
    if (-not [string]::Equals($candidatePath, $candidateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $candidatePath = $candidatePath.TrimEnd('\')
    }
    if ($profilePath -notmatch '^[A-Za-z]:\\' -or
        $candidatePath -notmatch '^[A-Za-z]:\\') {
        throw 'Coremail Controller V1 requires a local-drive Windows user profile.'
    }
    $prefix = if ($profilePath.EndsWith('\')) { $profilePath } else { $profilePath + '\' }
    if (-not [string]::Equals($candidatePath, $profilePath, [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Lifecycle path is outside the current Windows user profile: $candidatePath"
    }

    if ([string]::Equals($candidatePath, $profilePath, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = ''
    }
    else {
        $relative = $candidatePath.Substring($prefix.Length)
    }
    $cursor = $profilePath
    if (Test-Path -LiteralPath $cursor) {
        $profileItem = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Lifecycle path root is an unsupported link or junction: $cursor"
        }
    }
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

    $rootPath = [IO.Path]::GetFullPath($Root)
    $rootPathRoot = [IO.Path]::GetPathRoot($rootPath)
    if (-not [string]::Equals($rootPath, $rootPathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $rootPath = $rootPath.TrimEnd('\')
    }
    $candidatePath = [IO.Path]::GetFullPath($Path)
    $candidatePathRoot = [IO.Path]::GetPathRoot($candidatePath)
    if (-not [string]::Equals($candidatePath, $candidatePathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $candidatePath = $candidatePath.TrimEnd('\')
    }
    $prefix = if ($rootPath.EndsWith('\')) { $rootPath } else { $rootPath + '\' }
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
    if (Test-CoremailReleaseGatePermissionRepairMode) {
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
    # Pass each icacls argument as a separate item.  Windows PowerShell's
    # Start-Process joins an ArgumentList array using the native quoting rules;
    # constructing one opaque command string is lossy when a profile path or
    # SID contains characters that the ShellExecute layer treats specially.
    # The protected path and SID have already been validated above.
    $argumentList = @(
        "`"$targetPath`"",
        '/grant',
        $grant,
        '/L',
        '/Q'
    )
    Write-CoremailLifecycleLog (
        "LEGACY ACL REPAIR COMMAND target=$targetPath; grant=$grant; switches=/L,/Q"
    )
    Write-Host 'Windows will now request one UAC approval for this exact ACL grant.' -ForegroundColor Yellow
    try {
        $repairProcess = Start-Process `
            -FilePath $icacls `
            -ArgumentList $argumentList `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -ErrorAction Stop
    }
    catch {
        throw "Legacy plugin permission repair was cancelled or could not start: $($_.Exception.Message)"
    }
    # Keep a native process handle alive and wait explicitly.  Windows
    # PowerShell 5.1 can expose a stale/null ExitCode when a ShellExecute
    # (RunAs) child is queried immediately after Start-Process returns.
    try {
        $repairHandle = $repairProcess.Handle
        if ($repairHandle -eq [IntPtr]::Zero) {
            throw 'the elevated ACL repair process did not expose a usable handle'
        }
        $repairProcess.WaitForExit()
        $repairExitCode = $repairProcess.ExitCode
    }
    finally { $repairProcess.Dispose() }
    if ($repairExitCode -ne 0) {
        throw "Windows permission repair failed with icacls exit code $repairExitCode."
    }

    # Do not assume an exit code of zero means that the requested ACE became
    # effective.  Corporate UAC/ACL policy can let icacls return successfully
    # while an inherited deny or a protected DACL still blocks the account.
    # Read back the exact SID rule before the move retry loop continues, so a
    # failed repair is reported immediately instead of looking like a generic
    # transient directory lock.
    try {
        $repairedAcl = Get-Acl -LiteralPath $targetPath -ErrorAction Stop
        $sidRules = @($repairedAcl.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier]
        ) | Where-Object {
            [string]$_.IdentityReference.Value -eq [string]$sid.Value -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
        })
        $hasModify = $false
        foreach ($sidRule in $sidRules) {
            if (([Security.AccessControl.FileSystemRights]$sidRule.FileSystemRights -band
                [Security.AccessControl.FileSystemRights]::Delete) -ne 0 -and
                ([Security.AccessControl.FileSystemRights]$sidRule.FileSystemRights -band
                [Security.AccessControl.FileSystemRights]::ReadControl) -ne 0) {
                $hasModify = $true
                break
            }
        }
        if (-not $hasModify) {
            throw 'the current account Modify ACE was not visible after the elevated icacls command'
        }
    }
    catch {
        throw "Windows permission repair completed but the current account ACL was not effective: $($_.Exception.Message)"
    }

    $repairedEntry = Get-CoremailExactChildDirectory `
        -Parent $skillsRoot `
        -Name 'coremail-controller'
    if ([string]::IsNullOrWhiteSpace([string]$repairedEntry)) {
        throw 'The plugin directory disappeared during permission repair; no lifecycle move was attempted.'
    }
    [void](Assert-CoremailSafeClaudePath -UserProfile $profilePath -Path $targetPath)
    Write-Host 'The ACL grant was verified. Retrying the protected package move now.' -ForegroundColor Green
    Write-CoremailLifecycleLog 'LEGACY ACL REPAIR RECOVERED mode=system-icacls'
}

function Invoke-CoremailElevatedDirectoryMove {
    <#
      Move one already-identified legacy package with a single, constrained
      UAC approval.  This is the fallback for a directory whose ACL, parent
      delete-child right, or integrity policy still prevents the ordinary
      user process from renaming it after the normal retry/repair path.

      The elevated command is generated in memory and receives a base64 JSON
      payload.  It accepts only the exact active Coremail path and one of the
      two package quarantine parents; it validates the manifest again before
      using the same-volume Directory.Move primitive.  It never takes
      ownership, resets ACLs, recurses, overwrites, or deletes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [switch]$DirectForVerifiedGate,
        [switch]$FailIfBlocked
    )

    $profilePath = [IO.Path]::GetFullPath($UserProfile).TrimEnd('\')
    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $expectedSource = [IO.Path]::GetFullPath(
        (Join-Path $profilePath '.claude\skills\coremail-controller')
    ).TrimEnd('\')
    if (-not [string]::Equals(
        $sourcePath,
        $expectedSource,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Elevated legacy move was refused for an unexpected source path.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        throw 'Elevated legacy move requires the verified package version.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User
    if ($null -eq $sid -or -not $sid.IsAccountSid()) {
        throw 'Elevated legacy move requires a normal Windows account SID.'
    }

    $claudeRoot = [IO.Path]::GetFullPath((Join-Path $profilePath '.claude')).TrimEnd('\')
    $allowedParents = @(
        [IO.Path]::GetFullPath((Join-Path $claudeRoot 'plugin-backups')).TrimEnd('\'),
        [IO.Path]::GetFullPath((Join-Path $claudeRoot 'plugins-disabled')).TrimEnd('\')
    )
    $destinationParent = [IO.Path]::GetFullPath((Split-Path -Parent $destinationPath)).TrimEnd('\')
    if (-not ($allowedParents | Where-Object {
        [string]::Equals($_, $destinationParent, [StringComparison]::OrdinalIgnoreCase)
    })) {
        throw 'Elevated legacy move was refused for an unexpected quarantine directory.'
    }
    $destinationLeaf = Split-Path -Leaf $destinationPath
    if ([string]::IsNullOrWhiteSpace($destinationLeaf) -or
        $destinationLeaf -in @('.', '..') -or
        $destinationLeaf.IndexOfAny([char[]]'\/') -ge 0 -or
        $destinationLeaf -notmatch '^coremail-controller-[A-Za-z0-9-]+$') {
        throw 'Elevated legacy move requires one exact destination directory name.'
    }
    if ([IO.Path]::GetPathRoot($sourcePath) -ine [IO.Path]::GetPathRoot($destinationPath)) {
        throw 'Elevated legacy move requires source and destination on the same volume.'
    }
    # The source is precisely allowlisted above, but its final directory may
    # be the very ACL-protected object that triggered this callback.  Do not
    # require the ordinary token to read that component before elevation;
    # validate the accessible parent and let the elevated helper re-check the
    # complete path and manifest.
    [void](Assert-CoremailSafeClaudePath `
        -UserProfile $profilePath `
        -Path (Split-Path -Parent $sourcePath))
    [void](Assert-CoremailSafeClaudePath -UserProfile $profilePath -Path $destinationParent)
    try {
        $existingDestination = Get-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
        if ($null -ne $existingDestination) {
            throw 'The elevated move destination already exists; no overwrite was attempted.'
        }
    }
    catch {
        if (-not ($_.Exception -is [Management.Automation.ItemNotFoundException]) -and
            -not ($_.Exception -is [IO.FileNotFoundException]) -and
            -not ($_.Exception -is [IO.DirectoryNotFoundException])) {
            throw
        }
    }

    $diagnosticPath = Join-Path ([IO.Path]::GetTempPath()) (
        'coremail-elevated-move-' + [guid]::NewGuid().ToString('N') + '.txt'
    )
    $payload = [ordered]@{
        profile = $profilePath
        source = $sourcePath
        destination = $destinationPath
        allowed_parents = $allowedParents
        expected_version = [string]$ExpectedVersion
        sid = [string]$sid.Value
        diagnostic_path = $diagnosticPath
    }
    $payloadJson = $payload | ConvertTo-Json -Compress -Depth 4
    $payloadBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($payloadJson)
    )
    $elevatedSource = @'
$ErrorActionPreference = 'Stop'
try {
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__COREMAIL_PAYLOAD__')
    )
    $payload = $payloadJson | ConvertFrom-Json
    $profile = [IO.Path]::GetFullPath([string]$payload.profile).TrimEnd('\')
    $source = [IO.Path]::GetFullPath([string]$payload.source).TrimEnd('\')
    $destination = [IO.Path]::GetFullPath([string]$payload.destination).TrimEnd('\')
    $diagnosticPath = [IO.Path]::GetFullPath([string]$payload.diagnostic_path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $diagnosticPath.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The elevated diagnostic path was outside the temporary directory.'
    }
    $expectedSource = [IO.Path]::GetFullPath(
        (Join-Path $profile '.claude\skills\coremail-controller')
    ).TrimEnd('\')
    if (-not [string]::Equals($source, $expectedSource, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The elevated source path did not match the exact Coremail target.'
    }
    $destinationParent = [IO.Path]::GetFullPath((Split-Path -Parent $destination)).TrimEnd('\')
    $destinationLeaf = Split-Path -Leaf $destination
    if ([string]::IsNullOrWhiteSpace($destinationLeaf) -or
        $destinationLeaf -in @('.', '..') -or
        $destinationLeaf.IndexOfAny([char[]]'\/') -ge 0 -or
        $destinationLeaf -notmatch '^coremail-controller-[A-Za-z0-9-]+$') {
        throw 'The elevated destination name was not allowlisted.'
    }
    $parentAllowed = $false
    foreach ($allowedParent in @($payload.allowed_parents)) {
        if ([string]::Equals(
            $destinationParent,
            [IO.Path]::GetFullPath([string]$allowedParent).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $parentAllowed = $true
            break
        }
    }
    if (-not $parentAllowed) { throw 'The elevated destination parent was not allowlisted.' }
    if ([IO.Path]::GetPathRoot($source) -ine [IO.Path]::GetPathRoot($destination)) {
        throw 'The elevated source and destination are on different volumes.'
    }
    $sid = New-Object Security.Principal.SecurityIdentifier([string]$payload.sid)
    if (-not $sid.IsAccountSid()) { throw 'The elevated account SID is not a normal user SID.' }
    foreach ($path in @(
        $profile,
        (Join-Path $profile '.claude'),
        (Join-Path $profile '.claude\skills'),
        $source,
        $destinationParent
    )) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The elevated move path traverses a reparse point: $path"
        }
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw 'The exact Coremail source directory is absent.'
    }
    try {
        $existingDestination = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
        if ($null -ne $existingDestination) {
            throw 'The elevated move destination already exists.'
        }
    }
    catch {
        if (-not ($_.Exception -is [Management.Automation.ItemNotFoundException]) -and
            -not ($_.Exception -is [IO.FileNotFoundException]) -and
            -not ($_.Exception -is [IO.DirectoryNotFoundException])) {
            throw
        }
    }
    $manifestPath = Join-Path $source '.claude-plugin\plugin.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([string]$manifest.name -ne 'coremail-controller' -or
        [string]$manifest.version -ne [string]$payload.expected_version) {
        throw 'The protected source package identity changed before elevated move.'
    }
    $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
        throw 'The protected Windows icacls.exe utility is unavailable to the elevated move.'
    }
    $grant = '*{0}:(OI)(CI)M' -f $sid.Value
    $icaclsPreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        & $icacls $source '/grant' $grant '/L' '/Q' 2>$null | Out-Null
    }
    finally { $ErrorActionPreference = $icaclsPreviousPreference }
    if ($global:LASTEXITCODE -ne 0) {
        throw "The elevated ACL grant failed with icacls exit code $($global:LASTEXITCODE)."
    }
    [IO.Directory]::Move($source, $destination)
    if ((Test-Path -LiteralPath $source -PathType Container) -or
        -not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw 'The elevated directory move did not reach its expected postcondition.'
    }
    exit 0
}
catch {
    $message = $_.Exception.Message
    try {
        $diagnosticEncoding = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $diagnosticPath,
            $message,
            $diagnosticEncoding
        )
    }
    catch { }
    [Console]::Error.WriteLine($message)
    exit 1
}
'@
    $elevatedSource = $elevatedSource.Replace('__COREMAIL_PAYLOAD__', $payloadBase64)
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($elevatedSource)
    )
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
        throw 'The protected Windows PowerShell launcher is unavailable for elevated move.'
    }
    Write-CoremailLifecycleLog (
        "ELEVATED DIRECTORY MOVE REQUESTED source=$sourcePath; destination=$destinationPath; version=$ExpectedVersion"
    )
    $elevatedExitCode = $null
    try {
      if ($DirectForVerifiedGate) {
        # The hosted release orchestrator is already elevated.  This guarded
        # branch executes the exact encoded helper without another secure-
        # desktop prompt so CI can exercise its payload, manifest checks,
        # icacls grant, and Directory.Move postcondition.  It is rejected for
        # every normal/user process and is never used by install/uninstall.
        $gatePrincipal = New-Object Security.Principal.WindowsPrincipal(
            [Security.Principal.WindowsIdentity]::GetCurrent()
        )
        if ($env:COREMAIL_RELEASE_GATE_TESTING -ne 'true' -or
            -not $gatePrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Direct elevated-move testing is restricted to the verified administrator release gate.'
        }
        Write-Host 'Release gate is exercising the exact elevated legacy move helper under its verified administrator token.' -ForegroundColor Yellow
        $directPreviousPreference = $ErrorActionPreference
        try {
            # Windows PowerShell 5.1 promotes native stderr to ErrorRecord
            # values even when a command is expected to return a nonzero code;
            # keep the gate's explicit exit-code path in control.
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = $null
            & $powershell -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>$null | Out-Null
            $elevatedExitCode = $global:LASTEXITCODE
        }
        finally { $ErrorActionPreference = $directPreviousPreference }
      }
      else {
        Write-Host 'The protected legacy package still cannot be moved by the current token. Windows will now request one UAC approval for the exact atomic move.' -ForegroundColor Yellow
        try {
            $elevatedProcess = Start-Process `
                -FilePath $powershell `
                -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-NonInteractive',
                    '-EncodedCommand', $encodedCommand
                ) `
                -Verb RunAs `
                -Wait `
                -PassThru `
                -ErrorAction Stop
        }
        catch {
            throw "Elevated legacy package move was cancelled or could not start: $($_.Exception.Message)"
        }
        try {
            # Keep a process handle alive before reading ExitCode; this is
            # required for the Windows PowerShell 5.1 ShellExecute/RunAs path.
            $elevatedHandle = $elevatedProcess.Handle
            if ($elevatedHandle -eq [IntPtr]::Zero) {
                throw 'the elevated move process did not expose a usable handle'
            }
            $elevatedProcess.WaitForExit()
            $elevatedExitCode = $elevatedProcess.ExitCode
        }
        finally { $elevatedProcess.Dispose() }
      }
      $sourceAfterElevated = Test-Path -LiteralPath $sourcePath -PathType Container
      $destinationAfterElevated = Test-Path -LiteralPath $destinationPath -PathType Container
      if (-not $sourceAfterElevated -and $destinationAfterElevated) {
        Write-Host 'The exact legacy package move completed under the approved UAC action.' -ForegroundColor Green
        Write-CoremailLifecycleLog 'ELEVATED DIRECTORY MOVE RECOVERED mode=system-powershell'
        return
      }
      if ($elevatedExitCode -ne 0) {
        # Before allowing ordinary retries after a failed elevated attempt,
        # re-read the source identity.  A concurrent replacement must never
        # turn a transient access error into permission to move an unknown
        # directory.
        try {
            $identityManifest = Get-Content -LiteralPath (
                Join-Path $sourcePath '.claude-plugin\plugin.json'
            ) -Raw -ErrorAction Stop | ConvertFrom-Json
            if ([string]$identityManifest.name -ne 'coremail-controller' -or
                [string]$identityManifest.version -ne [string]$ExpectedVersion) {
                throw 'the protected source package identity changed'
            }
        }
        catch {
            throw (
                'The elevated legacy package move failed and the source identity could not be revalidated: ' +
                $_.Exception.Message
            )
        }
        $diagnostic = '<no child diagnostic>'
        if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
            try {
                $diagnostic = ([IO.File]::ReadAllText($diagnosticPath)).Trim()
            }
            catch { $diagnostic = '<diagnostic unreadable>' }
        }
        if ([string]::IsNullOrWhiteSpace($diagnostic)) {
            $diagnostic = '<no child diagnostic>'
        }
        Write-Warning (
            "The elevated legacy package move did not complete (exit code ${elevatedExitCode}); " +
            "the source is intact. Child diagnostic: $diagnostic"
        )
        Write-CoremailLifecycleLog (
            "ELEVATED DIRECTORY MOVE BLOCKED exit=$elevatedExitCode; source=$sourcePath; destination=$destinationPath; diagnostic=$diagnostic"
        )
        if ($FailIfBlocked) {
            throw (
                'The elevated legacy package move was blocked; the source remains intact. ' +
                "Child diagnostic: $diagnostic"
            )
        }
        return
      }
      if ($sourceAfterElevated -or -not $destinationAfterElevated) {
        throw 'The elevated move reported success but its source/destination postcondition was not met.'
      }
      Write-Host 'The exact legacy package move completed under the approved UAC action.' -ForegroundColor Green
      Write-CoremailLifecycleLog 'ELEVATED DIRECTORY MOVE RECOVERED mode=system-powershell'
    }
    finally {
        if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
            Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue
        }
    }
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
