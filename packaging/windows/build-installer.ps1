# Build the WispTerm Windows installer (installer\wispterm.nsi) from a packaged
# portable tree. Run after package.ps1 and, on a tag release, after
# sign-esigner.ps1 has signed that tree: the installer embeds the files as they
# are, so the payload binaries keep their Authenticode signatures. The setup exe
# itself is signed afterwards with sign-esigner.ps1 -File <setup exe>.
#
#   powershell -ExecutionPolicy Bypass -File .\packaging\windows\build-installer.ps1 -Version v1.45.0
#
# Needs NSIS 3 (makensis). On GitHub's Windows runners: choco install nsis.
# Writes <OutputDir>\wispterm-windows-setup-<Version>.exe and prints its path.

param(
    [string]$PayloadDir = '.\zig-out\dist\portable',
    [string]$OutputDir = '.\zig-out\dist\installer',
    # Release tag or version, e.g. v1.45.0. Defaults to the payload's version.txt.
    [string]$Version,
    [string]$Makensis
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Makensis {
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) { throw "makensis was not found at $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    $onPath = Get-Command 'makensis' -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidates.Add((Join-Path $root 'NSIS\makensis.exe'))
        }
    }
    if ($env:ChocolateyInstall) {
        Get-ChildItem -Path (Join-Path $env:ChocolateyInstall 'lib') -Filter 'makensis.exe' -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates.Add($_.FullName) }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'makensis was not found on PATH, under Program Files\NSIS, or in the Chocolatey lib folder. Install NSIS 3 (choco install nsis).'
}

function Resolve-FullPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location) $Path
    }
    return [IO.Path]::GetFullPath($Path)
}

# "v1.45.0" -> display "1.45.0" and resource "1.45.0.0"; a git-describe
# string keeps its text and gets no resource version.
function Get-InstallerVersions {
    param([Parameter(Mandatory = $true)][string]$Raw)
    $display = $Raw.Trim()
    if ($display -match '^[vV](\d.*)$') { $display = $Matches[1] }
    $resource = $null
    if ($display -match '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$') {
        $fourth = if ($Matches[4]) { $Matches[4] } else { '0' }
        $resource = '{0}.{1}.{2}.{3}' -f $Matches[1], $Matches[2], $Matches[3], $fourth
    }
    return @{ Display = $display; Resource = $resource }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$payload = Resolve-FullPath $PayloadDir
$output = Resolve-FullPath $OutputDir
$script = Join-Path $PSScriptRoot 'installer\wispterm.nsi'
$icon = Join-Path $repoRoot 'assets\wispterm.ico'

if (-not (Test-Path -LiteralPath $payload -PathType Container)) { throw "Payload directory not found: $payload" }
foreach ($required in @('wispterm.exe', 'version.txt', 'uninstall.ps1', 'Uninstall-WispTerm.cmd')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $required) -PathType Leaf)) {
        throw "Payload is missing $required. Run package.ps1 first: $payload"
    }
}
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "NSIS script not found: $script" }
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) { throw "Installer icon not found: $icon" }

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (Get-Content -LiteralPath (Join-Path $payload 'version.txt') -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($Version)) { throw 'Pass -Version: version.txt in the payload is empty.' }
}
$versions = Get-InstallerVersions -Raw $Version
$fileTag = $Version.Trim()
if ($fileTag -match '[\\/:*?"<>|\s]') { throw "Version '$fileTag' cannot be part of a file name." }

New-Item -ItemType Directory -Force -Path $output | Out-Null
$outFile = Join-Path $output "wispterm-windows-setup-$fileTag.exe"
if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }

$makensis = Resolve-Makensis -Explicit $Makensis
$arguments = @(
    '-V2',
    '-WX',
    # The script holds UTF-8 Chinese strings; without this makensis reads it
    # in the runner's ANSI code page.
    '-INPUTCHARSET', 'UTF8',
    "-DPAYLOAD_DIR=$payload",
    "-DOUT_FILE=$outFile",
    "-DICON_FILE=$icon",
    "-DVERSION=$($versions.Display)"
)
if ($versions.Resource) { $arguments += "-DVERSION4=$($versions.Resource)" }
$arguments += $script

Write-Host "Building $outFile with $makensis"
& $makensis @arguments
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $outFile -PathType Leaf)) { throw "makensis did not write $outFile" }

Write-Host "Installer: $outFile"
Write-Output $outFile
