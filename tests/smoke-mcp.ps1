param(
    [int]$TimeoutMilliseconds = 15000,
    [switch]$CheckConnection,
    [switch]$IgnoreAccountConfiguration,
    [string]$PythonExecutable = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($CheckConnection -and $IgnoreAccountConfiguration) {
    throw 'CheckConnection and IgnoreAccountConfiguration cannot be used together.'
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The launcher smoke test must run on Windows.'
}

$mcpRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\mcp'))
$runnerPath = Join-Path $mcpRoot 'run-server.ps1'
$serverPath = Join-Path $mcpRoot 'server.py'
if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
        throw "MCP launcher not found: $runnerPath"
    }
}
else {
    $PythonExecutable = [IO.Path]::GetFullPath($PythonExecutable)
    if (-not (Test-Path -LiteralPath $PythonExecutable -PathType Leaf)) {
        throw "Explicit smoke-test Python executable not found: $PythonExecutable"
    }
    if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
        throw "MCP server not found: $serverPath"
    }
}

function ConvertTo-RequestJson {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 24 -Compress)
}

function Read-ServerResponse {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$Timeout
    )
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($Timeout)) {
        throw "Timed out after $Timeout ms waiting for an MCP response."
    }
    $line = $task.Result
    if ([string]::IsNullOrWhiteSpace($line)) {
        $stderr = $Process.StandardError.ReadToEnd()
        throw "MCP server returned no JSON response. stderr: $stderr"
    }
    return ($line | ConvertFrom-Json)
}

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
    $startInfo.FileName = 'powershell.exe'
    $escapedRunnerPath = $runnerPath.Replace('"', '\"')
    $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -File `"$escapedRunnerPath`""
}
else {
    $startInfo.FileName = $PythonExecutable
    $escapedServerPath = $serverPath.Replace('"', '\"')
    $startInfo.Arguments = "-I `"$escapedServerPath`""
}
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
$startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
$startInfo.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'
if ($IgnoreAccountConfiguration) {
    $startInfo.EnvironmentVariables['APPDATA'] = Join-Path (
        [IO.Path]::GetTempPath()
    ) ('coremail-smoke-' + [guid]::NewGuid().ToString('N'))
}

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo

try {
    if (-not $process.Start()) { throw 'Failed to start the MCP launcher.' }

    $process.StandardInput.WriteLine((ConvertTo-RequestJson ([ordered]@{
        jsonrpc = '2.0'
        id = 1
        method = 'initialize'
        params = [ordered]@{
            protocolVersion = '2024-11-05'
            capabilities = [ordered]@{}
            clientInfo = [ordered]@{ name = 'coremail-smoke-test'; version = '0.7.0' }
        }
    })))
    $process.StandardInput.Flush()
    $initialize = Read-ServerResponse -Process $process -Timeout $TimeoutMilliseconds
    if ($initialize.id -ne 1 -or $initialize.result.serverInfo.name -ne 'coremail-headless') {
        throw 'Unexpected initialize response.'
    }

    $process.StandardInput.WriteLine((ConvertTo-RequestJson ([ordered]@{
        jsonrpc = '2.0'
        method = 'notifications/initialized'
        params = [ordered]@{}
    })))
    $process.StandardInput.WriteLine((ConvertTo-RequestJson ([ordered]@{
        jsonrpc = '2.0'
        id = 2
        method = 'tools/list'
        params = [ordered]@{}
    })))
    $process.StandardInput.Flush()
    $toolList = Read-ServerResponse -Process $process -Timeout $TimeoutMilliseconds
    $toolNames = @($toolList.result.tools | ForEach-Object { $_.name })
    $expectedTools = @(
        'coremail_connection_status',
        'coremail_discover_local',
        'coremail_check_connection',
        'coremail_list_folders',
        'coremail_search',
        'coremail_get_message',
        'coremail_set_seen',
        'coremail_prepare_message',
        'coremail_save_draft',
        'coremail_send_prepared'
    )
    foreach ($toolName in $expectedTools) {
        if ($toolName -notin $toolNames) { throw "Missing MCP tool: $toolName" }
    }

    $process.StandardInput.WriteLine((ConvertTo-RequestJson ([ordered]@{
        jsonrpc = '2.0'
        id = 3
        method = 'tools/call'
        params = [ordered]@{
            name = 'coremail_connection_status'
            arguments = [ordered]@{}
        }
    })))
    $process.StandardInput.Flush()
    $status = Read-ServerResponse -Process $process -Timeout $TimeoutMilliseconds
    if ($status.id -ne 3 -or $status.result.isError) {
        throw 'The offline connection-status tool failed.'
    }

    if ($CheckConnection) {
        $process.StandardInput.WriteLine((ConvertTo-RequestJson ([ordered]@{
            jsonrpc = '2.0'
            id = 4
            method = 'tools/call'
            params = [ordered]@{
                name = 'coremail_check_connection'
                arguments = [ordered]@{}
            }
        })))
        $process.StandardInput.Flush()
        $connection = Read-ServerResponse -Process $process -Timeout $TimeoutMilliseconds
        if ($connection.id -ne 4) {
            throw 'The live connection check returned an unexpected response.'
        }
        if ($connection.result.isError) {
            $detail = [string]$connection.result.content[0].text
            throw "The live Coremail connection check failed: $detail"
        }
        Write-Host 'Live Coremail active-transport check passed.'
    }

    Write-Host "Headless MCP smoke test passed. Tools: $($toolNames.Count)"
}
finally {
    try { $process.StandardInput.Close() } catch { }
    if (-not $process.HasExited) {
        if (-not $process.WaitForExit(3000)) { $process.Kill() }
    }
    $process.Dispose()
}
