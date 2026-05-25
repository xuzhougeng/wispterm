#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Start TBtools JSON-RPC server in headless mode.
.DESCRIPTION
    Launches the TBtools RPC API server at http://127.0.0.1:8765/rpc
    without opening the GUI. Use Ctrl+C to stop.
.EXAMPLE
    .\start_rpc_server.ps1
    .\start_rpc_server.ps1 -Background
#>
param(
    [switch]$Background,
    [string]$JarPath = $env:TBTOOLS_JAR,
    [string]$JavaExe = "java",
    [int]$Port = 8765
)

if (-not $JarPath) {
    $homePath = if ($env:TBTOOLS_HOME) { $env:TBTOOLS_HOME } else { "C:\Program Files\TBtools" }
    $JarPath = Join-Path $homePath "TBtools_JRE1.6.jar"
}

if (-not (Test-Path $JarPath)) {
    Write-Error "TBtools JAR not found at $JarPath. Set TBTOOLS_HOME or TBTOOLS_JAR if TBtools is installed elsewhere."
    exit 1
}

$rpcUrl = "http://127.0.0.1:$Port/rpc"
$healthUrl = "http://127.0.0.1:$Port/health"
$arguments = @("-cp", $JarPath, "biocjava.rpc.RpcServer")
$startProcessArguments = @("-cp", "`"$JarPath`"", "biocjava.rpc.RpcServer") -join " "

if ($Background) {
    Write-Host "Starting TBtools RPC server in background..."
    $process = Start-Process -FilePath $JavaExe -ArgumentList $startProcessArguments -NoNewWindow -PassThru
    Write-Host "PID: $($process.Id)"
    Write-Host "API: $rpcUrl"
    Write-Host "Health: $healthUrl"
} else {
    Write-Host "Starting TBtools RPC server..."
    Write-Host "API: $rpcUrl"
    Write-Host "Health: $healthUrl"
    Write-Host "Press Ctrl+C to stop."
    & $JavaExe @arguments
}
