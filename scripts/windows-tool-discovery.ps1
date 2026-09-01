#requires -Version 5.1

Set-StrictMode -Version 2.0

function Test-CoremailPortableExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            [IO.Path]::GetFullPath($Path),
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if ($stream.Length -lt 70) { return $false }
        $dosHeader = New-Object byte[] 64
        if ($stream.Read($dosHeader, 0, $dosHeader.Length) -ne $dosHeader.Length -or
            $dosHeader[0] -ne 0x4D -or $dosHeader[1] -ne 0x5A) {
            return $false
        }
        $peOffset = [BitConverter]::ToInt32($dosHeader, 0x3C)
        if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 6)) { return $false }
        $stream.Position = $peOffset
        $peHeader = New-Object byte[] 6
        if ($stream.Read($peHeader, 0, $peHeader.Length) -ne $peHeader.Length) {
            return $false
        }
        return ($peHeader[0] -eq 0x50 -and
            $peHeader[1] -eq 0x45 -and
            $peHeader[2] -eq 0 -and
            $peHeader[3] -eq 0)
    }
    catch { return $false }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Resolve-NpmClaudeInvocation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CommandPath)

    if (-not (Test-Path -LiteralPath $CommandPath -PathType Leaf) -or
        [IO.Path]::GetExtension($CommandPath) -ine '.cmd') {
        return $null
    }

    try {
        $resolvedCommand = (Resolve-Path -LiteralPath $CommandPath -ErrorAction Stop).Path
        $commandRoot = Split-Path -Parent $resolvedCommand
        $packageRootCandidate = Join-Path $commandRoot 'node_modules\@anthropic-ai\claude-code'
        if (-not (Test-Path -LiteralPath $packageRootCandidate -PathType Container)) {
            return $null
        }
        $packageRoot = (Resolve-Path -LiteralPath $packageRootCandidate -ErrorAction Stop).Path
        $packagePath = Join-Path $packageRoot 'package.json'
        $package = Get-Content -LiteralPath $packagePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ([string]$package.name -ne '@anthropic-ai/claude-code') {
            return $null
        }

        $binPath = ''
        if ($package.bin -is [string]) {
            $binPath = [string]$package.bin
        }
        elseif ($null -ne $package.bin) {
            $claudeBin = $package.bin.PSObject.Properties['claude']
            if ($null -ne $claudeBin) { $binPath = [string]$claudeBin.Value }
        }
        if ([string]::IsNullOrWhiteSpace($binPath) -or [IO.Path]::IsPathRooted($binPath)) {
            return $null
        }
        $packageRootFull = [IO.Path]::GetFullPath($packageRoot).TrimEnd('\')
        $cliPath = [IO.Path]::GetFullPath((Join-Path $packageRootFull $binPath))
        if (-not $cliPath.StartsWith(
            $packageRootFull + '\',
            [StringComparison]::OrdinalIgnoreCase
        ) -or -not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
            return $null
        }

        $cliItem = Get-Item -LiteralPath $cliPath -Force -ErrorAction Stop
        if (($cliItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $null
        }
        $cliExtension = [IO.Path]::GetExtension($cliPath)
        if ($cliExtension -ieq '.exe') {
            # Current npm releases replace their declared bin/claude.exe stub
            # with the platform-native PE during postinstall. Execute that
            # declared binary directly; passing it to node.exe is incorrect.
            if (-not (Test-CoremailPortableExecutable -Path $cliPath)) { return $null }
            return [pscustomobject]@{
                CommandPath = $resolvedCommand
                Executable = $cliPath
                Prefix = [string[]]@()
                Kind = 'npm'
                NpmBinKind = 'native'
            }
        }
        if ($cliExtension -notin @('.js', '.cjs', '.mjs')) { return $null }

        $nodeCandidates = @((Join-Path $commandRoot 'node.exe'))
        $nodeCommand = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $nodeCommand) {
            $nodeCandidates += if ($nodeCommand.Source) { $nodeCommand.Source } else { $nodeCommand.Path }
        }
        foreach ($nodeCandidate in $nodeCandidates) {
            if ([string]::IsNullOrWhiteSpace($nodeCandidate) -or
                -not (Test-Path -LiteralPath $nodeCandidate -PathType Leaf)) { continue }
            $resolvedNode = (Resolve-Path -LiteralPath $nodeCandidate -ErrorAction Stop).Path
            if ([IO.Path]::GetExtension($resolvedNode) -ine '.exe') { continue }
            return [pscustomobject]@{
                CommandPath = $resolvedCommand
                Executable = $resolvedNode
                Prefix = [string[]]@($cliPath)
                Kind = 'npm'
                NpmBinKind = 'node'
            }
        }
    }
    catch {
        return $null
    }
    return $null
}

function Resolve-ClaudeCodeInvocation {
    [CmdletBinding()]
    param([string]$ExplicitPath = '')

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates = @($ExplicitPath)
    }
    else {
        foreach ($commandName in @('claude.exe', 'claude.cmd')) {
            $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue
            if ($null -ne $command) {
                $resolved = if ($command.Source) { $command.Source } else { $command.Path }
                if ($resolved) { $candidates += $resolved }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $candidates += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
        }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or
            -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try { $resolvedCandidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path }
        catch { continue }
        $extension = [IO.Path]::GetExtension($resolvedCandidate)
        if ($extension -ieq '.exe') {
            return [pscustomobject]@{
                CommandPath = $resolvedCandidate
                Executable = $resolvedCandidate
                Prefix = [string[]]@()
                Kind = 'native'
            }
        }
        if ($extension -ieq '.cmd') {
            $npmInvocation = Resolve-NpmClaudeInvocation -CommandPath $resolvedCandidate
            if ($null -ne $npmInvocation) { return $npmInvocation }
        }
    }
    return $null
}

function Resolve-CoremailPythonCandidate {
    [CmdletBinding()]
    param([string]$ExplicitPath = '')

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidate = Get-Command $ExplicitPath -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { return $null }
        return [pscustomobject]@{
            Executable = if ($candidate.Source) { $candidate.Source } else { $candidate.Path }
            Prefix = [string[]]@()
        }
    }
    $launcher = Get-Command 'py.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $launcher) {
        return [pscustomobject]@{
            Executable = if ($launcher.Source) { $launcher.Source } else { $launcher.Path }
            Prefix = [string[]]@('-3')
        }
    }
    foreach ($name in @('python.exe', 'python3.exe')) {
        $candidate = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $candidate) {
            return [pscustomobject]@{
                Executable = if ($candidate.Source) { $candidate.Source } else { $candidate.Path }
                Prefix = [string[]]@()
            }
        }
    }
    return $null
}
