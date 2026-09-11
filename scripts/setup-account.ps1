#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('auto', 'windows_simple_mapi', 'imap_smtp')]
    [string]$Transport = 'auto',
    [string]$Username,
    [string]$ImapHost,
    [ValidateRange(1, 65535)][int]$ImapPort = 993,
    [ValidateSet('ssl', 'starttls')][string]$ImapSecurity = 'ssl',
    [string]$SmtpHost,
    [ValidateRange(1, 65535)][int]$SmtpPort = 465,
    [ValidateSet('ssl', 'starttls')][string]$SmtpSecurity = 'ssl',
    [string[]]$AllowedFrom,
    [string]$DraftsFolder,
    [string]$SentFolder,
    [ValidateSet('none', 'append')][string]$SentCopyMode = 'none',
    [string[]]$AttachmentRoots,
    [string]$CaFile,
    [string]$CredentialTarget,
    [ValidateSet('password', 'plain', 'xoauth2', 'oauthbearer')]
    [string]$AuthMethod = 'password',
    [string]$DownloadDirectory,
    [Security.SecureString]$Password,
    [switch]$NonInteractive,
    [switch]$LifecycleLockAlreadyHeld,
    [ValidateSet('none', 'after_credential_write', 'before_config_publish')]
    [string]$TestFailurePoint = 'none',
    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Mail account setup is intended for Windows.'
}

$pluginRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$commonScript = Join-Path $PSScriptRoot 'windows-lifecycle-common.ps1'
$credentialScript = Join-Path $PSScriptRoot 'windows-credential.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf) -or
    -not (Test-Path -LiteralPath $credentialScript -PathType Leaf)) {
    throw 'Mail account transaction support is missing.'
}
. $commonScript
. $credentialScript

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'mail-mcp-server\logs'
    $LogPath = Join-Path $logDirectory (
        'CONFIGURE-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'
    )
}
Initialize-CoremailLifecycleLog -Path $LogPath

$stagedConfigPath = $null
$newCredentialWritten = $false
$configCommitted = $false
$ownsPassword = $false
$lifecycleLockPath = $null
$lifecycleLockStream = $null
$userProfile = $null
$mailRoot = $null

function Read-RequiredValue {
    param([string]$Current, [string]$Prompt)
    $value = $Current
    while ([string]::IsNullOrWhiteSpace($value)) {
        if ($NonInteractive) { throw "$Prompt is required in non-interactive mode." }
        $value = Read-Host $Prompt
    }
    if ($value.Contains("`r") -or $value.Contains("`n")) {
        throw "$Prompt must not contain newlines."
    }
    return $value.Trim()
}

function Get-PinnedPythonRuntime {
    $descriptorPath = Join-Path $pluginRoot 'mcp\python-runtime.json'
    if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        throw 'The pinned Python runtime descriptor is missing. Run INSTALL.cmd before configuring an account.'
    }
    $descriptorItem = Get-Item -LiteralPath $descriptorPath -Force -ErrorAction Stop
    if (($descriptorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The pinned Python runtime descriptor is a link or junction.'
    }
    try { $runtime = Get-Content -LiteralPath $descriptorPath -Raw | ConvertFrom-Json }
    catch { throw "The pinned Python runtime descriptor is invalid: $($_.Exception.Message)" }
    if ([int]$runtime.schema_version -ne 1 -or [string]$runtime.kind -ne 'python' -or
        -not [bool]$runtime.bundled -or [int]$runtime.pointer_bits -ne 64 -or
        [string]$runtime.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw 'The pinned Python runtime descriptor does not describe a bundled 64-bit runtime.'
    }
    $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $pluginRoot 'payload\runtime\python.exe'))
    $executable = [IO.Path]::GetFullPath([string]$runtime.executable)
    if (-not [string]::Equals($executable, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The pinned Python runtime descriptor does not point to the bundled payload/runtime/python.exe.'
    }
    [void](Assert-CoremailSafeDescendantPath -Root $pluginRoot -Path $executable -Label 'bundled Python executable')
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "The pinned Python executable is unavailable: $executable"
    }
    $expectedHash = [string]$runtime.executable_sha256
    $actualHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$' -or $actualHash -ine $expectedHash) {
        throw 'The pinned Python executable changed. Run INSTALL.cmd again before changing account settings.'
    }
    return [pscustomobject]@{ Executable = $executable; PointerBits = [int]$runtime.pointer_bits }
}

function Invoke-PinnedPython {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$CapturePath = '',
        [string]$Label = 'Python helper'
    )
    Invoke-CoremailExternalChecked `
        -Executable ([string]$script:PinnedPython.Executable) `
        -Arguments $Arguments `
        -CapturePath $CapturePath `
        -Label $Label
}

function Test-CoremailClientName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -match '(?i)coremail|lunkr|论客|盈世'
}

function Get-CoremailMapiRegistration {
    $mailRoots = @(
        [pscustomobject]@{ Path = 'Registry::HKEY_CURRENT_USER\Software\Clients\Mail'; Scope = 'current_user' },
        [pscustomobject]@{ Path = 'Registry::HKEY_LOCAL_MACHINE\Software\Clients\Mail'; Scope = 'local_machine' },
        [pscustomobject]@{ Path = 'Registry::HKEY_CURRENT_USER\Software\WOW6432Node\Clients\Mail'; Scope = 'current_user_32bit' },
        [pscustomobject]@{ Path = 'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Clients\Mail'; Scope = 'local_machine_32bit' }
    )
    $defaultClient = $null
    $defaultScope = $null
    foreach ($root in $mailRoots) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        $mailRootItem = Get-Item -LiteralPath $root.Path
        $candidate = [string]($mailRootItem.GetValue(''))
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $defaultClient = $candidate.Trim()
            $defaultScope = $root.Scope
            break
        }
    }
    $recognized = Test-CoremailClientName -Name $defaultClient
    $providerRegistered = $false
    if ($recognized) {
        foreach ($root in $mailRoots) {
            $clientKey = Join-Path $root.Path $defaultClient
            if (-not (Test-Path -LiteralPath $clientKey -PathType Container)) { continue }
            $item = Get-Item -LiteralPath $clientKey
            foreach ($valueName in @('DLLPathEx', 'DLLPath', 'MSIComponentID')) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item.GetValue($valueName))) {
                    $providerRegistered = $true
                    break
                }
            }
            if ($providerRegistered) { break }
        }
    }
    return [pscustomobject]@{
        Client = $defaultClient
        Scope = $defaultScope
        Recognized = $recognized
        ProviderRegistered = $providerRegistered
        Candidate = $recognized -and $providerRegistered
    }
}

function Test-CoremailSharedMapiSession {
    $probeScript = Join-Path $pluginRoot 'mcp\windows_mapi.py'
    $probeOutput = Join-Path ([IO.Path]::GetTempPath()) (
        'coremail-mapi-probe-' + [guid]::NewGuid().ToString('N') + '.json'
    )
    try {
        Invoke-PinnedPython `
            -Arguments @('-B', '-I', $probeScript, '--probe-json') `
            -CapturePath $probeOutput `
            -Label 'Coremail Simple MAPI probe'
        $result = Get-Content -LiteralPath $probeOutput -Raw | ConvertFrom-Json
    }
    finally {
        if (Test-Path -LiteralPath $probeOutput -PathType Leaf) {
            Remove-Item -LiteralPath $probeOutput -Force -ErrorAction SilentlyContinue
        }
    }
    $unicodeSend = $false
    if ($null -ne $result.PSObject.Properties['unicode_send_available']) {
        $unicodeSend = [bool]$result.unicode_send_available
    }
    $reason = 'unusable interface'
    if ($null -ne $result.PSObject.Properties['reason']) { $reason = [string]$result.reason }
    return [pscustomobject]@{
        Code = if ($result.usable) { 0 } else { $reason }
        SharedSession = [bool]$result.shared_session_available
        UnicodeSend = $unicodeSend
        Usable = [bool]$result.usable
        PythonPointerBits = [int]$result.python_pointer_bits
    }
}

try {
    if ($TestFailurePoint -ne 'none' -and $env:MAIL_RELEASE_GATE_TESTING -ne 'true') {
        throw 'Account failure injection is restricted to the Windows release gate.'
    }
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'The current Windows user profile directory could not be resolved.' }
    [void](Assert-CoremailSafeLocalPath -Path $userProfile -Label 'user profile')
    $mailRoot = Join-Path $userProfile 'mail-mcp-server'
    $lifecycleLockPath = Join-Path $mailRoot '.lifecycle.lock'
    [void](Assert-CoremailSafeDescendantPath -Root $userProfile -Path $mailRoot -Label 'mail lifecycle root')
    [void](Assert-CoremailSafeDescendantPath -Root $userProfile -Path $lifecycleLockPath -Label 'mail lifecycle lock')
    if (-not $LifecycleLockAlreadyHeld) {
        $lifecycleLockStream = Enter-CoremailLifecycleLock -Path $lifecycleLockPath
    }
    $script:PinnedPython = Get-PinnedPythonRuntime
    Write-CoremailLifecycleLog "ACCOUNT TRANSACTION started transport=$Transport"

    $registration = $null
    $mapiProbe = $null
    $mapiProbeFailure = $null
    if ($Transport -ne 'imap_smtp') {
        $registration = Get-CoremailMapiRegistration
        if ($registration.Candidate) {
            Write-Host "Recognized default Windows mail client: $($registration.Client)"
            try { $mapiProbe = Test-CoremailSharedMapiSession }
            catch { $mapiProbeFailure = $_.Exception.Message }
        }
    }

    if ($Transport -eq 'auto') {
        if ($null -ne $mapiProbe -and $mapiProbe.Usable) {
            $Transport = 'windows_simple_mapi'
            Write-Host "Using the existing Coremail shared Simple MAPI session through $($mapiProbe.PythonPointerBits)-bit Python. No password will be requested."
        }
        else {
            $Transport = 'imap_smtp'
            if ($null -eq $registration -or -not $registration.Recognized) {
                Write-Host 'No registered Coremail Simple MAPI client was found; using secure IMAP/SMTP setup.'
            }
            elseif (-not $registration.ProviderRegistered) {
                Write-Host 'Coremail is registered but has no Simple MAPI provider; using secure IMAP/SMTP setup.'
            }
            elseif ($null -ne $mapiProbe -and -not $mapiProbe.SharedSession) {
                Write-Host "Coremail has no reusable shared MAPI session (code $($mapiProbe.Code)); using secure IMAP/SMTP setup."
            }
            elseif (-not [string]::IsNullOrWhiteSpace($mapiProbeFailure)) {
                Write-Host 'The Coremail MAPI probe could not run; using secure IMAP/SMTP setup.'
            }
            else {
                Write-Host 'The Coremail MAPI provider cannot perform no-UI Unicode sending; using secure IMAP/SMTP setup.'
            }
        }
    }
    elseif ($Transport -eq 'windows_simple_mapi') {
        if ($null -eq $registration -or -not $registration.Candidate) {
            throw 'windows_simple_mapi was requested, but the default Windows mail client is not a registered Coremail MAPI provider.'
        }
        if ($null -eq $mapiProbe -or -not $mapiProbe.Usable) {
            $code = if ($null -eq $mapiProbe) {
                if ([string]::IsNullOrWhiteSpace($mapiProbeFailure)) { 'not probed' } else { $mapiProbeFailure }
            }
            else { [string]$mapiProbe.Code }
            throw "windows_simple_mapi was requested, but no usable shared session is available (code $code)."
        }
    }

    if ($Transport -eq 'windows_simple_mapi' -and [string]::IsNullOrWhiteSpace($Username)) {
        $whoAmI = Join-Path $env:SystemRoot 'System32\whoami.exe'
        if (Test-Path -LiteralPath $whoAmI -PathType Leaf) {
            try {
                $upn = (& $whoAmI /upn 2>$null | Select-Object -First 1)
                if ($null -ne $upn -and ([string]$upn).Contains('@')) {
                    $Username = ([string]$upn).Trim()
                    Write-Host "Using Windows domain UPN as mailbox identity: $Username"
                }
            }
            catch { $Username = $null }
        }
    }

    $Username = Read-RequiredValue -Current $Username -Prompt 'Full mailbox username (for example user@example.com)'
    if (-not $Username.Contains('@')) { throw 'The mailbox username must be a full email address.' }
    if ($null -eq $AllowedFrom -or $AllowedFrom.Count -eq 0) { $AllowedFrom = @($Username) }
    if ($Transport -eq 'windows_simple_mapi') {
        if ($AllowedFrom.Count -ne 1 -or $AllowedFrom[0] -ine $Username) {
            throw 'windows_simple_mapi requires allowed_from to contain only the active mailbox username.'
        }
        if (-not [string]::IsNullOrWhiteSpace($CaFile) -or
            -not [string]::IsNullOrWhiteSpace($DraftsFolder) -or
            -not [string]::IsNullOrWhiteSpace($SentFolder) -or
            $SentCopyMode -ne 'none' -or $AuthMethod -ne 'password') {
            throw 'CA, Drafts/Sent folder, sent-copy, and protocol authentication settings apply only to imap_smtp.'
        }
    }

    $resolvedRoots = @()
    foreach ($root in @($AttachmentRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $resolved = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($root))
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            throw "Attachment root does not exist: $resolved"
        }
        $resolvedRoots += $resolved
    }
    $resolvedCaFile = $null
    if (-not [string]::IsNullOrWhiteSpace($CaFile)) {
        $resolvedCaFile = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CaFile))
        if (-not (Test-Path -LiteralPath $resolvedCaFile -PathType Leaf)) {
            throw "CA file does not exist: $resolvedCaFile"
        }
    }

    if ($Transport -eq 'imap_smtp') {
        $ImapHost = Read-RequiredValue -Current $ImapHost -Prompt 'IMAP server hostname'
        $SmtpHost = Read-RequiredValue -Current $SmtpHost -Prompt 'SMTP server hostname'
        if ([string]::IsNullOrWhiteSpace($CredentialTarget)) {
            $CredentialTarget = 'MailMcp.Coremail:' + $Username + ':' + [guid]::NewGuid().ToString('N')
        }
        if ($CredentialTarget.Contains("`r") -or $CredentialTarget.Contains("`n") -or
            $CredentialTarget.Length -gt 1024) {
            throw 'Credential target must be a single line no longer than 1024 characters.'
        }
        if (Test-CoremailCredential -Target $CredentialTarget) {
            throw "Credential target '$CredentialTarget' already exists. Omit -CredentialTarget to create a new transactional credential."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($DownloadDirectory)) {
        if ($Transport -ne 'imap_smtp') { throw 'DownloadDirectory is available only with imap_smtp.' }
        $resolvedDownloadDirectory = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DownloadDirectory))
        [void](Assert-CoremailSafeDescendantPath -Root $userProfile -Path $resolvedDownloadDirectory -Label 'attachment download directory')
        if (-not (Test-Path -LiteralPath $resolvedDownloadDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $resolvedDownloadDirectory -Force)
        }
    } else {
        $resolvedDownloadDirectory = $null
    }

    $configDirectory = Join-Path $mailRoot 'config'
    $configPath = Join-Path $configDirectory 'settings.json'
    [void](Assert-CoremailSafeDescendantPath `
        -Root $userProfile `
        -Path $configPath `
        -Label 'mail account configuration')
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

    $rollbackDirectory = Join-Path $mailRoot 'rollback'
    [void](Assert-CoremailSafeDescendantPath -Root $userProfile -Path $rollbackDirectory -Label 'mail rollback directory')
    New-Item -ItemType Directory -Path $rollbackDirectory -Force | Out-Null

    $config = [ordered]@{
        schema_version = 1
        provider = 'coremail'
        transport = $Transport
        username = $Username
        allowed_from = @($AllowedFrom)
        sent_copy_mode = $SentCopyMode
        attachment_roots = @($resolvedRoots)
        max_message_bytes = 10485760
        max_body_chars = 50000
        max_attachment_bytes = 26214400
        max_recipients = 100
        timeout_seconds = 20
        download_directory = $resolvedDownloadDirectory
    }
    if ($Transport -eq 'imap_smtp') {
        $config['auth_method'] = $AuthMethod
        $config['credential_target'] = $CredentialTarget
        $config['imap'] = [ordered]@{ host = $ImapHost; port = $ImapPort; security = $ImapSecurity }
        $config['smtp'] = [ordered]@{ host = $SmtpHost; port = $SmtpPort; security = $SmtpSecurity }
        $config['drafts_folder'] = if ([string]::IsNullOrWhiteSpace($DraftsFolder)) { $null } else { $DraftsFolder }
        $config['sent_folder'] = if ([string]::IsNullOrWhiteSpace($SentFolder)) { $null } else { $SentFolder }
        $config['ca_file'] = $resolvedCaFile
    }

    $stagedConfigPath = Join-Path $configDirectory (
        '.config-' + [guid]::NewGuid().ToString('N') + '.json'
    )
    $json = $config | ConvertTo-Json -Depth 10
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($stagedConfigPath, $json, $utf8)
    Invoke-PinnedPython `
        -Arguments @('-B', '-I', (Join-Path $pluginRoot 'mcp\validate-config.py'), $stagedConfigPath) `
        -Label 'Staged account configuration validation'

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $backupPath = Join-Path $rollbackDirectory (
            'settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
            [guid]::NewGuid().ToString('N').Substring(0, 8) + '.backup'
        )
        [IO.File]::Copy($configPath, $backupPath, $false)
        Write-Host "Previous non-secret configuration backed up to: $backupPath"
        Write-CoremailLifecycleLog "ACCOUNT CONFIG BACKUP path=$backupPath"
    }

    if ($Transport -eq 'imap_smtp') {
        if ($null -eq $Password) {
            if ($NonInteractive) { throw 'Password or access token is required in non-interactive IMAP/SMTP setup.' }
            $credentialPrompt = if ($AuthMethod -eq 'password') { '邮箱或域密码' } else { 'OAuth access token' }
            $Password = Read-Host ($credentialPrompt + '（仅存入 Windows Credential Manager）') -AsSecureString
            $ownsPassword = $true
        }
        if ($Password.Length -eq 0) { throw 'The password or access token must not be empty.' }
        Write-CoremailCredential -Target $CredentialTarget -Username $Username -Password $Password
        $newCredentialWritten = $true
        Write-CoremailLifecycleLog "ACCOUNT CREDENTIAL WRITTEN target=$CredentialTarget"
        if ($TestFailurePoint -eq 'after_credential_write') {
            throw 'Injected release-gate failure after credential write.'
        }
    }
    if ($TestFailurePoint -eq 'before_config_publish') {
        throw 'Injected release-gate failure before configuration publication.'
    }

    Publish-CoremailFileAtomically -Source $stagedConfigPath -Destination $configPath
    $stagedConfigPath = $null
    $configCommitted = $true
    Write-CoremailLifecycleLog 'ACCOUNT CONFIGURATION COMMITTED'

    Write-Host ''
    Write-Host 'Mail account configuration saved.' -ForegroundColor Green
    Write-Host "Transport: $Transport"
    Write-Host "Non-secret settings: $configPath"
    if ($Transport -eq 'windows_simple_mapi') {
        Write-Host 'Authentication: existing provider shared Simple MAPI session (no password copied or stored).'
    }
    else {
        Write-Host "Credential location ($AuthMethod): Windows Credential Manager target '$CredentialTarget'"
    }
    Write-Host "Diagnostic log: $LogPath"
    Write-Host 'Restart Claude Code, then call mail_config_reload and mail_check_connection.'
    Write-Host 'The connector never starts, clicks, captures, or types into a mail-client interface.'
}
catch {
    $accountError = $_
    Write-CoremailLifecycleFailure -ErrorRecord $accountError -Context 'account configuration'
    if ($newCredentialWritten -and -not $configCommitted) {
        try {
            Remove-CoremailCredential -Target $CredentialTarget
            $newCredentialWritten = $false
            Write-CoremailLifecycleLog "ROLLBACK removed unpublished credential target=$CredentialTarget"
        }
        catch {
            Write-CoremailLifecycleFailure -ErrorRecord $_ -Context 'credential rollback'
            throw "Account setup failed before publication, and the newly created credential '$CredentialTarget' could not be removed. The previous config remains active. Original error: $($accountError.Exception.Message)"
        }
    }
    throw
}
finally {
    if ($stagedConfigPath -and (Test-Path -LiteralPath $stagedConfigPath -PathType Leaf)) {
        Remove-Item -LiteralPath $stagedConfigPath -Force -ErrorAction SilentlyContinue
    }
    if ($ownsPassword -and $null -ne $Password) { $Password.Dispose() }
    Exit-CoremailLifecycleLock -Stream $lifecycleLockStream -Path $lifecycleLockPath
}
