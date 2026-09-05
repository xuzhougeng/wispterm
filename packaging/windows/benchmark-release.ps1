param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$OutputDir = '.\zig-out\release-benchmark'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Tag -notmatch '^(v\d+\.\d+\.\d+|\d+\.\d+(\.\d+)?)$') {
    throw "Invalid release tag: $Tag"
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$reportDir = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))
$profileDir = Join-Path ([IO.Path]::GetTempPath()) ('wispterm-release-bench-' + [Guid]::NewGuid().ToString('N'))
$previousAppData = $env:APPDATA
Push-Location $repoRoot
try {
    # Build only the CLI; do not overwrite the packaged desktop executables.
    & zig build bench -Demit-bench -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) { throw 'Release benchmark build failed' }

    New-Item -ItemType Directory -Force -Path $profileDir, $reportDir | Out-Null
    $env:APPDATA = $profileDir
    & '.\zig-out\bin\wispterm-bench.exe' --case terminal-stream --duration 1000
    if ($LASTEXITCODE -ne 0) { throw 'Release benchmark failed' }

    $reports = @(Get-ChildItem -LiteralPath (Join-Path $profileDir 'wispterm') -Filter 'benchmark-report-*.json')
    if ($reports.Count -ne 1) { throw 'Expected exactly one fresh benchmark report' }
    $report = Get-Content -LiteralPath $reports[0].FullName -Raw | ConvertFrom-Json
    if ($report.app_version -ne $Tag.TrimStart('v') -or $report.os -ne 'windows' -or $report.cpu_arch -ne 'x86_64' -or $report.runner -ne 'cli') {
        throw 'Benchmark version or platform does not match the release'
    }
    $scenarios = @($report.scenarios)
    if ($scenarios.Count -ne 1 -or $scenarios[0].name -ne 'terminal-stream' -or $scenarios[0].unit -ne 'throughput' -or $scenarios[0].value -le 0 -or $scenarios[0].samples -le 0 -or $scenarios[0].duration_ms -lt 1000) {
        throw 'Missing or invalid terminal-stream benchmark result'
    }
    $markdown = [IO.Path]::ChangeExtension($reports[0].FullName, '.md')
    if (!(Test-Path -LiteralPath $markdown) -or (Get-Item -LiteralPath $markdown).Length -eq 0) {
        throw 'Benchmark Markdown report is missing or empty'
    }
    Copy-Item -LiteralPath $reports[0].FullName -Destination (Join-Path $reportDir "benchmark-windows-$Tag.json") -Force
    Copy-Item -LiteralPath $markdown -Destination (Join-Path $reportDir "benchmark-windows-$Tag.md") -Force
    Write-Host "Release benchmark reports: $reportDir"
} finally {
    $env:APPDATA = $previousAppData
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    Pop-Location
}
