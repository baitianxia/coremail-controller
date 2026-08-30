param(
    [ValidateSet('auto', 'windows_simple_mapi', 'imap_smtp')]
    [string]$Transport = 'auto',
    [string]$Username,
    [string]$ImapHost,
    [ValidateRange(1, 65535)]
    [int]$ImapPort = 993,
    [ValidateSet('ssl', 'starttls')]
    [string]$ImapSecurity = 'ssl',
    [string]$SmtpHost,
    [ValidateRange(1, 65535)]
    [int]$SmtpPort = 465,
    [ValidateSet('ssl', 'starttls')]
    [string]$SmtpSecurity = 'ssl',
    [string[]]$AllowedFrom,
    [string]$DraftsFolder,
    [string]$SentFolder,
    [ValidateSet('none', 'append')]
    [string]$SentCopyMode = 'none',
    [string[]]$AttachmentRoots,
    [string]$CaFile,
    [string]$CredentialTarget
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Coremail account setup is intended for Windows.'
}

function Read-RequiredValue {
    param(
        [string]$Current,
        [string]$Prompt
    )
    $value = $Current
    while ([string]::IsNullOrWhiteSpace($value)) {
        $value = Read-Host $Prompt
    }
    if ($value.Contains("`r") -or $value.Contains("`n")) {
        throw "$Prompt must not contain newlines."
    }
    return $value.Trim()
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
        $item = Get-Item -LiteralPath $root.Path
        $candidate = [string]$item.GetValue('')
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
                $value = [string]$item.GetValue($valueName)
                if (-not [string]::IsNullOrWhiteSpace($value)) {
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

function Resolve-CoremailPythonRuntime {
    $command = $null
    $prefix = @()
    if (-not [string]::IsNullOrWhiteSpace($env:COREMAIL_PYTHON)) {
        $candidate = Get-Command $env:COREMAIL_PYTHON -ErrorAction Stop
        $command = $candidate.Source
    }
    else {
        $launcher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
        if ($null -ne $launcher) {
            $command = $launcher.Source
            $prefix = @('-3')
        }
        else {
            foreach ($name in @('python.exe', 'python3.exe', 'python', 'python3')) {
                $candidate = Get-Command $name -ErrorAction SilentlyContinue
                if ($null -ne $candidate) {
                    $command = $candidate.Source
                    break
                }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($command)) {
        throw 'Python 3.10 or newer was not found for the Coremail MAPI probe.'
    }
    return [pscustomobject]@{ Command = $command; Prefix = @($prefix) }
}

function Test-CoremailSharedMapiSession {
    $runtime = Resolve-CoremailPythonRuntime
    $pluginRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $probeScript = Join-Path $pluginRoot 'mcp\windows_mapi.py'
    if (-not (Test-Path -LiteralPath $probeScript -PathType Leaf)) {
        throw "Coremail MAPI probe not found: $probeScript"
    }
    $prefix = @($runtime.Prefix)
    $output = & $runtime.Command @prefix -I $probeScript --probe-json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
        throw 'The Coremail MAPI probe process did not return a result.'
    }
    $result = $output | ConvertFrom-Json
    $unicodeSend = $false
    if ($result.PSObject.Properties.Name -contains 'unicode_send_available') {
        $unicodeSend = [bool]$result.unicode_send_available
    }
    $reason = 'unusable interface'
    if ($result.PSObject.Properties.Name -contains 'reason') {
        $reason = [string]$result.reason
    }
    return [pscustomobject]@{
        Code = if ($result.usable) { 0 } else { $reason }
        SharedSession = [bool]$result.shared_session_available
        UnicodeSend = $unicodeSend
        Usable = [bool]$result.usable
        PythonPointerBits = [int]$result.python_pointer_bits
    }
}

$registration = $null
$mapiProbe = $null
$mapiProbeFailure = $null
if ($Transport -ne 'imap_smtp') {
    $registration = Get-CoremailMapiRegistration
    if ($registration.Candidate) {
        Write-Host "Recognized default Windows mail client: $($registration.Client)"
        try {
            $mapiProbe = Test-CoremailSharedMapiSession
        }
        catch {
            $mapiProbeFailure = $_.Exception.Message
        }
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
            Write-Host 'The Coremail MAPI probe could not run in this process; using secure IMAP/SMTP setup.'
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
        catch {
            $Username = $null
        }
    }
}

$Username = Read-RequiredValue -Current $Username -Prompt 'Full mailbox username (for example user@example.com)'
if (-not $Username.Contains('@')) {
    throw 'The mailbox username must be a full email address.'
}

if ($null -eq $AllowedFrom -or $AllowedFrom.Count -eq 0) {
    $AllowedFrom = @($Username)
}
if ($Transport -eq 'windows_simple_mapi') {
    if ($AllowedFrom.Count -ne 1 -or $AllowedFrom[0] -ine $Username) {
        throw 'windows_simple_mapi requires allowed_from to contain only the active mailbox username.'
    }
    if (-not [string]::IsNullOrWhiteSpace($CaFile) -or
        -not [string]::IsNullOrWhiteSpace($DraftsFolder) -or
        -not [string]::IsNullOrWhiteSpace($SentFolder) -or
        $SentCopyMode -ne 'none') {
        throw 'CA, Drafts/Sent folder, and sent-copy settings apply only to imap_smtp.'
    }
}

$resolvedRoots = @()
foreach ($root in @($AttachmentRoots)) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $expanded = [Environment]::ExpandEnvironmentVariables($root)
    $resolved = [IO.Path]::GetFullPath($expanded)
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
        $CredentialTarget = "ClaudeCode.Coremail:$Username"
    }

    $credentialSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class CoremailCredentialWriter
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public UInt32 Flags;
        public UInt32 Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, UInt32 flags);

    public static void Write(string target, string username, string password)
    {
        byte[] bytes = Encoding.Unicode.GetBytes(password);
        IntPtr blob = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            CREDENTIAL credential = new CREDENTIAL();
            credential.Type = 1;
            credential.TargetName = target;
            credential.CredentialBlobSize = checked((UInt32)bytes.Length);
            credential.CredentialBlob = blob;
            credential.Persist = 2;
            credential.UserName = username;
            if (!CredWrite(ref credential, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            for (int index = 0; index < bytes.Length; index++) bytes[index] = 0;
            for (int index = 0; index < bytes.Length; index++) Marshal.WriteByte(blob, index, 0);
            Marshal.FreeCoTaskMem(blob);
        }
    }
}
'@

    if ($null -eq ('CoremailCredentialWriter' -as [type])) {
        Add-Type -TypeDefinition $credentialSource -Language CSharp | Out-Null
    }
    $securePassword = Read-Host 'Windows domain/Coremail or client-specific password (stored in Windows Credential Manager)' -AsSecureString
    if ($securePassword.Length -eq 0) { throw 'The password must not be empty.' }
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        [CoremailCredentialWriter]::Write($CredentialTarget, $Username, $plainPassword)
        $plainPassword = $null
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        $securePassword.Dispose()
    }
}

$appData = [Environment]::GetFolderPath('ApplicationData')
if ([string]::IsNullOrWhiteSpace($appData)) {
    $appData = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Roaming'
}
$configDirectory = Join-Path $appData 'ClaudeCode\Coremail'
$configPath = Join-Path $configDirectory 'config.json'
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$configPath.backup-$timestamp"
    Copy-Item -LiteralPath $configPath -Destination $backupPath
    Write-Host "Previous non-secret configuration backed up to: $backupPath"
}

$config = [ordered]@{
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
}

if ($Transport -eq 'imap_smtp') {
    $config['credential_target'] = $CredentialTarget
    $config['imap'] = [ordered]@{
        host = $ImapHost
        port = $ImapPort
        security = $ImapSecurity
    }
    $config['smtp'] = [ordered]@{
        host = $SmtpHost
        port = $SmtpPort
        security = $SmtpSecurity
    }
    $config['drafts_folder'] = if ([string]::IsNullOrWhiteSpace($DraftsFolder)) { $null } else { $DraftsFolder }
    $config['sent_folder'] = if ([string]::IsNullOrWhiteSpace($SentFolder)) { $null } else { $SentFolder }
    $config['ca_file'] = $resolvedCaFile
}

$json = $config | ConvertTo-Json -Depth 10
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($configPath, $json, $utf8)

Write-Host ''
Write-Host 'Coremail account configuration saved.'
Write-Host "Transport: $Transport"
Write-Host "Non-secret settings: $configPath"
if ($Transport -eq 'windows_simple_mapi') {
    Write-Host 'Authentication: existing Coremail shared Simple MAPI session (no password copied or stored).'
}
else {
    Write-Host "Password location: Windows Credential Manager target '$CredentialTarget'"
}
Write-Host 'Restart Claude Code or run /reload-plugins, then call coremail_check_connection.'
Write-Host 'The connector never starts, clicks, captures, or types into the Coremail interface.'
