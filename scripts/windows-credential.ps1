#requires -Version 5.1

Set-StrictMode -Version 2.0

$credentialSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class CoremailCredentialStore
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

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, UInt32 type, UInt32 flags, out IntPtr credential);

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, UInt32 type, UInt32 flags);

    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("Advapi32.dll", EntryPoint = "CredFree")]
    private static extern void CredFree(IntPtr buffer);

    public static bool Exists(string target)
    {
        IntPtr pointer;
        if (CredRead(target, 1, 0, out pointer))
        {
            CredFree(pointer);
            return true;
        }
        int error = Marshal.GetLastWin32Error();
        if (error == 1168) return false;
        throw new Win32Exception(error);
    }

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

    public static void Delete(string target)
    {
        if (CredDelete(target, 1, 0)) return;
        int error = Marshal.GetLastWin32Error();
        if (error != 1168) throw new Win32Exception(error);
    }
}
'@

if ($null -eq ('CoremailCredentialStore' -as [type])) {
    Add-Type -TypeDefinition $credentialSource -Language CSharp | Out-Null
}

function Test-CoremailCredential {
    param([Parameter(Mandatory = $true)][string]$Target)
    return [CoremailCredentialStore]::Exists($Target)
}

function Write-CoremailCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][Security.SecureString]$Password
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainText = $null
    try {
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        [CoremailCredentialStore]::Write($Target, $Username, $plainText)
    }
    finally {
        $plainText = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Remove-CoremailCredential {
    param([Parameter(Mandatory = $true)][string]$Target)
    [CoremailCredentialStore]::Delete($Target)
}
