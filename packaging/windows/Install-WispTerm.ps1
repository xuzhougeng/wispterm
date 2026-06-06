param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\WispTerm'),
    [switch]$Quiet,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WispTermVersion {
    $versionFile = Join-Path $PSScriptRoot 'version.txt'
    if (Test-Path $versionFile) {
        $raw = (Get-Content $versionFile -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return $raw
        }
    }

    return '0.0.0-dev'
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [string]$WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = $TargetPath
    $shortcut.Save()
}

$appName = 'WispTerm'
$publisher = 'WispTerm'
$exeName = 'wispterm.exe'
$sourceExe = Join-Path $PSScriptRoot $exeName
$askPassHelperName = 'wispterm-ssh-askpass.exe'
$sourceAskPassHelper = Join-Path $PSScriptRoot $askPassHelperName
$sourceWebView2Loader = Join-Path $PSScriptRoot 'WebView2Loader.dll'

if (-not (Test-Path $sourceExe)) {
    throw "Missing payload: $sourceExe"
}
if (-not (Test-Path $sourceAskPassHelper)) {
    throw "Missing payload: $sourceAskPassHelper"
}

$resolvedInstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$installedExe = Join-Path $resolvedInstallDir $exeName
$installedAskPassHelper = Join-Path $resolvedInstallDir $askPassHelperName
$installedWebView2Loader = Join-Path $resolvedInstallDir 'WebView2Loader.dll'
$version = Get-WispTermVersion

New-Item -ItemType Directory -Path $resolvedInstallDir -Force | Out-Null
Copy-Item -Path $sourceExe -Destination $installedExe -Force
Copy-Item -Path $sourceAskPassHelper -Destination $installedAskPassHelper -Force
if (Test-Path $sourceWebView2Loader) {
    Copy-Item -Path $sourceWebView2Loader -Destination $installedWebView2Loader -Force
}
Set-Content -Path (Join-Path $resolvedInstallDir 'version.txt') -Value $version -Encoding ASCII

$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WispTerm'
New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null

$startMenuShortcut = Join-Path $startMenuDir 'WispTerm.lnk'
New-Shortcut -ShortcutPath $startMenuShortcut -TargetPath $installedExe -WorkingDirectory $resolvedInstallDir

$uninstallScript = Join-Path $resolvedInstallDir 'Uninstall-WispTerm.ps1'
$uninstallCmd = Join-Path $resolvedInstallDir 'Uninstall-WispTerm.cmd'
$appPathsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\wispterm.exe'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WispTerm'

$uninstallScriptBody = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WispTerm'
$appPathsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\wispterm.exe'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WispTerm'

if (Test-Path $startMenuDir) {
    Remove-Item -Path $startMenuDir -Recurse -Force
}

if (Test-Path $appPathsKey) {
    Remove-Item -Path $appPathsKey -Recurse -Force
}

if (Test-Path $uninstallKey) {
    Remove-Item -Path $uninstallKey -Recurse -Force
}

Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "timeout /t 1 /nobreak >nul & rmdir /s /q `"$installDir`"" -WindowStyle Hidden | Out-Null
'@

Set-Content -Path $uninstallScript -Value $uninstallScriptBody -Encoding ASCII

$uninstallCmdBody = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-WispTerm.ps1"
'@
Set-Content -Path $uninstallCmd -Value $uninstallCmdBody -Encoding ASCII

New-Item -Path $appPathsKey -Force | Out-Null
Set-Item -Path $appPathsKey -Value $installedExe
New-ItemProperty -Path $appPathsKey -Name 'Path' -Value $resolvedInstallDir -PropertyType String -Force | Out-Null

New-Item -Path $uninstallKey -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'DisplayName' -Value $appName -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'DisplayVersion' -Value $version -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'Publisher' -Value $publisher -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'DisplayIcon' -Value $installedExe -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $resolvedInstallDir -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'UninstallString' -Value ('"{0}"' -f $uninstallCmd) -PropertyType String -Force | Out-Null

if (-not $Quiet) {
    Write-Host "Installed WispTerm to $resolvedInstallDir"
    Write-Host 'Start menu entry created: WispTerm'
}

if (-not $NoLaunch) {
    Start-Process -FilePath $installedExe -WorkingDirectory $resolvedInstallDir | Out-Null
}
