#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PythonExecutable = '',
    [string]$ClaudeCommand = '',
    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$commonScript = Join-Path $PSScriptRoot 'windows-lifecycle-common.ps1'
$discoveryScript = Join-Path $PSScriptRoot 'windows-tool-discovery.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf) -or
    -not (Test-Path -LiteralPath $discoveryScript -PathType Leaf)) {
    throw 'Mail assistant lifecycle support scripts are missing.'
}
. $commonScript
. $discoveryScript

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'mail-mcp-server\logs'
    $LogPath = Join-Path $logDirectory (
        'UNINSTALL-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'
    )
}
Initialize-CoremailLifecycleLog -Path $LogPath

$mcpServerName = 'mail-mcp'
$userProfile = $null
$agentRoot = $null
$versionsRoot = $null
$lockPath = $null
$lockStream = $null
$claudeUserConfigPath = $null
$snapshotDirectory = $null
$claudeUserConfigSnapshot = $null
$configMutationStarted = $false
$uninstallCommitted = $false
$preserveSnapshot = $false
$claudeInvocation = $null
$pythonRuntime = $null
$registeredRuntime = $null

function Get-CoremailUserMcpEntry {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }
    try { $payload = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { throw "Claude user configuration is not valid JSON: $ConfigPath" }
    $serversProperty = $payload.PSObject.Properties['mcpServers']
    if ($null -eq $serversProperty -or $null -eq $serversProperty.Value) { return $null }
    $entryProperty = $serversProperty.Value.PSObject.Properties[$mcpServerName]
    if ($null -eq $entryProperty -or $null -eq $entryProperty.Value) { return $null }
    return $entryProperty.Value
}

function Get-CoremailRegisteredRuntimeHint {
    param([Parameter(Mandatory = $true)][object]$Entry)
    try {
        $argsProperty = $Entry.PSObject.Properties['args']
        if ($null -eq $argsProperty -or $null -eq $argsProperty.Value) { return $null }
        $arguments = @($argsProperty.Value | ForEach-Object { [string]$_ })
        for ($index = 0; $index -lt $arguments.Count - 1; $index++) {
            if ([string]::Equals($arguments[$index], '-File', [StringComparison]::OrdinalIgnoreCase)) {
                $scriptPath = [IO.Path]::GetFullPath($arguments[$index + 1])
                if (-not $scriptPath.EndsWith('\mcp\run-server.ps1', [StringComparison]::OrdinalIgnoreCase)) {
                    return $null
                }
                return [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $scriptPath)))
            }
        }
    }
    catch { return $null }
    return $null
}

function Invoke-CoremailUserMcpRemoval {
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    # Use the registrar from the runtime that is actually registered.  The
    # package the user happens to launch the uninstaller from may be an older
    # or partially extracted copy; removing an entry must use the same verified
    # immutable tree whose descriptor was checked below.
    $registrar = Join-Path $registeredRuntime 'scripts\register_claude_user_mcp.py'
    if (-not (Test-Path -LiteralPath $registrar -PathType Leaf)) { throw "The mail MCP registrar is missing: $registrar" }
    $arguments = @(
        '-B', '-I', $registrar, 'unregister',
        '--claude-executable', [string]$claudeInvocation.Executable,
        '--server-name', $mcpServerName,
        '--user-config', $claudeUserConfigPath,
        '--backup', $BackupPath
    )
    foreach ($prefix in @($claudeInvocation.Prefix)) { $arguments += @('--claude-prefix', [string]$prefix) }
    Invoke-CoremailExternalChecked -Executable ([string]$pythonRuntime.Executable) -Arguments $arguments `
        -Label 'Claude user-scope MCP removal'
}

function Get-PinnedRuntimeFromRelease {
    param([Parameter(Mandatory = $true)][string]$Root)
    $expectedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    [void](Assert-CoremailSafeDescendantPath -Root $versionsRoot -Path $expectedRoot -Label 'registered mail runtime')
    $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $expectedRoot 'payload\runtime\python.exe'))
    $descriptorPath = Join-Path $Root 'mcp\python-runtime.json'
    if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        throw "The registered mail runtime has no pinned Python descriptor: $descriptorPath"
    }
    $descriptorItem = Get-Item -LiteralPath $descriptorPath -Force -ErrorAction Stop
    if (($descriptorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The registered mail runtime descriptor is a link or junction: $descriptorPath"
    }
    try { $descriptor = Get-Content -LiteralPath $descriptorPath -Raw | ConvertFrom-Json }
    catch { throw "The registered mail runtime descriptor is invalid: $descriptorPath" }
    if ([int]$descriptor.schema_version -ne 1 -or [string]$descriptor.kind -ne 'python' -or
        -not [bool]$descriptor.bundled -or [int]$descriptor.pointer_bits -ne 64 -or
        [string]$descriptor.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw 'The registered mail runtime descriptor does not describe a bundled 64-bit runtime.'
    }
    $executable = [IO.Path]::GetFullPath([string]$descriptor.executable)
    [void](Assert-CoremailSafeDescendantPath -Root $expectedRoot -Path $executable -Label 'registered Python executable')
    $expectedHash = [string]$descriptor.executable_sha256
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf) -or
        $expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The registered mail Python runtime is unavailable or has an invalid hash.'
    }
    $actualHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) { throw 'The registered mail Python runtime changed; refusing to mutate Claude configuration.' }
    if (-not [string]::Equals($executable, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The registered mail runtime descriptor does not point to its bundled payload/runtime/python.exe.'
    }
    if (-not [string]::IsNullOrWhiteSpace($PythonExecutable) -and
        -not [string]::Equals([IO.Path]::GetFullPath($PythonExecutable), $executable, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'PythonExecutable cannot replace the registered bundled runtime.'
    }
    return [pscustomobject]@{ Executable = $executable }
}

function Assert-CoremailRegisteredRegistrar {
    param([Parameter(Mandatory = $true)][string]$Root)
    $registrar = Join-Path $Root 'scripts\register_claude_user_mcp.py'
    [void](Assert-CoremailSafeDescendantPath -Root $Root -Path $registrar -Label 'registered mail MCP registrar')
    try { $item = Get-Item -LiteralPath $registrar -Force -ErrorAction Stop }
    catch { throw "The registered mail MCP registrar is unavailable: $registrar" }
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-Path -LiteralPath $registrar -PathType Leaf)) {
        throw "The registered mail MCP registrar is not a regular file: $registrar"
    }
    return $registrar
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This uninstaller can run only on Windows.' }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'The current Windows user profile directory could not be resolved.' }
    $claudeUserConfigPath = Resolve-CoremailClaudeUserConfigPath -UserProfile $userProfile
    $entry = Get-CoremailUserMcpEntry -ConfigPath $claudeUserConfigPath
    if ($null -eq $entry) {
        Write-CoremailLifecycleLog 'UNINSTALL no active mail-mcp user-scope entry found'
        Write-Host '邮件助手已经从 Claude 用户级 MCP 中移除。'
        Write-Host 'No runtime or account data was changed.'
        Write-Host "Diagnostic log: $LogPath"
        exit 0
    }
    $registeredRuntime = Get-CoremailRegisteredRuntimeHint -Entry $entry
    Write-CoremailLifecycleLog "UNINSTALL registration found config=$claudeUserConfigPath; runtime_hint=$registeredRuntime"

    $agentRoot = Join-Path $userProfile 'mail-mcp-server'
    $versionsRoot = Join-Path $agentRoot 'versions'
    [void](Assert-CoremailSafeLocalPath -Path $userProfile -Label 'user profile')
    if ($registeredRuntime -and
        -not $registeredRuntime.StartsWith(([IO.Path]::GetFullPath((Join-Path $agentRoot 'versions'))).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "The registered mail runtime is outside the managed versions directory: $registeredRuntime"
    }
    $lockPath = Join-Path $agentRoot '.lifecycle.lock'
    [void](Assert-CoremailSafeDescendantPath -Root $userProfile -Path $agentRoot -Label 'mail lifecycle root')
    [void](Assert-CoremailSafeDescendantPath -Root $userProfile -Path $lockPath -Label 'mail lifecycle lock')
    $lockStream = Enter-CoremailLifecycleLock -Path $lockPath

    if ($null -eq $registeredRuntime) { throw 'The mail MCP entry does not point to a managed runtime; the user MCP entry was not changed.' }
    [void](Assert-CoremailSafeDescendantPath -Root $versionsRoot -Path $registeredRuntime -Label 'registered mail runtime')
    $pythonRuntime = Get-PinnedRuntimeFromRelease -Root $registeredRuntime
    # Do not walk and hash the whole immutable tree here.  A live Claude
    # process is allowed to keep any file in that tree open with
    # FileShare.None; a full verifier would turn an otherwise safe, reversible
    # registration removal into a sharing violation.  The pinned runtime
    # descriptor above verifies the executable that will perform the mutation,
    # and the registrar is checked as a regular file before it is invoked.
    [void](Assert-CoremailRegisteredRegistrar -Root $registeredRuntime)
    $claudeInvocation = Resolve-ClaudeCodeInvocation -ExplicitPath $ClaudeCommand
    if ($null -eq $claudeInvocation) { throw 'Claude Code was not found; the user MCP entry was not changed.' }
    $claudeVersion = Get-CoremailClaudeVersion -Invocation $claudeInvocation -Label 'Claude Code version probe'
    Invoke-CoremailClaudeChecked -Invocation $claudeInvocation -Arguments @('mcp', '--help') `
        -Label 'Claude MCP capability probe' -QuietOnSuccess

    $snapshotDirectory = Join-Path $agentRoot ('rollback\uninstall-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $snapshotDirectory -Force | Out-Null
    $claudeUserConfigSnapshot = Save-CoremailFileSnapshot -Path $claudeUserConfigPath -BackupDirectory $snapshotDirectory -Label 'claude-user-config'
    $configMutationStarted = $true
    Invoke-CoremailUserMcpRemoval -BackupPath (Join-Path $snapshotDirectory 'registrar.backup')
    $configMutationStarted = $false
    $uninstallCommitted = $true

    Write-Host ''
    Write-Host '邮件助手已从 Claude 用户级 MCP 中移除。' -ForegroundColor Green
    Write-Host 'The immutable runtime directories were retained; no files were deleted and no permission repair was attempted.'
    if ($registeredRuntime) { Write-Host "Retained runtime (if present): $registeredRuntime" }
    Write-Host '邮箱配置和 Windows Credential Manager 条目已保留。'
    Write-Host "Diagnostic log: $LogPath"
    exit 0
}
catch {
    $uninstallError = $_
    Write-CoremailLifecycleFailure -ErrorRecord $uninstallError -Context 'uninstall'
    if (-not $uninstallCommitted -and $configMutationStarted -and $null -ne $claudeUserConfigSnapshot) {
        try {
            Restore-CoremailFileSnapshot -Destination ([string]$claudeUserConfigSnapshot.Path) `
                -WasPresent ([bool]$claudeUserConfigSnapshot.WasPresent) -BackupPath ([string]$claudeUserConfigSnapshot.BackupPath)
            Write-CoremailLifecycleLog 'ROLLBACK restored Claude user MCP configuration'
        }
        catch {
            $preserveSnapshot = $true
            Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'uninstall user config rollback'
        }
    }
    Write-Host ''
    Write-Host "Uninstall stopped safely: $($uninstallError.Exception.Message)" -ForegroundColor Red
    Write-Host 'No runtime or mailbox data was deleted.'
    Write-Host "Diagnostic log: $LogPath"
    exit 1
}
finally {
    Exit-CoremailLifecycleLock -Stream $lockStream -Path $lockPath
    if (-not $preserveSnapshot -and $snapshotDirectory -and (Test-Path -LiteralPath $snapshotDirectory -PathType Container)) {
        Remove-Item -LiteralPath $snapshotDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
