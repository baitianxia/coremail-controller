#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This uninstaller is intended for Windows.'
    }

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw 'The current Windows user profile directory could not be resolved.'
    }
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $claudeRoot = Join-Path $userProfile '.claude'
    $targetRoot = Join-Path $claudeRoot 'skills\coremail-controller'
    $manifestPath = Join-Path $targetRoot '.claude-plugin\plugin.json'

    if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        Write-Host 'Coremail Controller is not installed in the personal skills directory.'
        exit 0
    }

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Refusing to move an unrecognized directory: $targetRoot"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'coremail-controller') {
        throw "Refusing to move a plugin with unexpected identity: $($manifest.name)"
    }

    $disabledRoot = Join-Path $claudeRoot 'plugins-disabled'
    New-Item -ItemType Directory -Path $disabledRoot -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $destination = Join-Path $disabledRoot (
        "coremail-controller-$timestamp-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    )
    try {
        Move-Item -LiteralPath $targetRoot -Destination $destination
    }
    catch [System.UnauthorizedAccessException] {
        throw "Windows denied permission to move '$targetRoot' for '$currentIdentity'. The plugin directory was left unchanged. Disable coremail-controller@skills-dir, reload or exit Claude Code, then grant this Windows identity Modify permission on that exact directory before retrying. Original error: $($_.Exception.Message)"
    }
    catch [System.IO.IOException] {
        throw "Windows could not move '$targetRoot' for '$currentIdentity'. The directory is either still in use or its ACL does not allow this user to modify it; it was left unchanged. Disable coremail-controller@skills-dir, reload or exit Claude Code, verify the directory ACL, and retry. Original error: $($_.Exception.Message)"
    }

    Write-Host 'Coremail Controller has been disabled and moved, not deleted.'
    Write-Host "Recovery location: $destination"
    Write-Host 'Mailbox configuration and Windows Credential Manager entries were preserved.'
    Write-Host 'Restart Claude Code or run /reload-plugins.'
    exit 0
}
catch {
    Write-Host ''
    Write-Host "Uninstall stopped safely: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
