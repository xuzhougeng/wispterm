# Replace the Start-menu / current WispTerm install with the files next to
# this script. Double-click Replace-WispTerm.cmd; do not run the exe from
# inside the zip (Explorer would extract only that one file).

param([switch]$EnableContextMenu)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$zh = (Get-UICulture).Name.StartsWith('zh')
function T([string]$en, [string]$cn) {
    if ($zh) { return $cn }
    return $en
}

function Get-ShortcutTarget([string]$lnk) {
    if (-not (Test-Path -LiteralPath $lnk)) { return $null }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk)
        $target = [string]$shortcut.TargetPath
        if ([string]::IsNullOrWhiteSpace($target)) { return $null }
        return $target
    } catch {
        return $null
    }
}

function Get-InstallDirFromShortcuts {
    $links = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WispTerm.lnk'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\WispTerm.lnk'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\WispTerm.lnk')
    )
    foreach ($lnk in $links) {
        $target = Get-ShortcutTarget $lnk
        if (-not $target) { continue }
        if (-not (Test-Path -LiteralPath $target)) { continue }
        return [System.IO.Path]::GetDirectoryName($target)
    }
    return $null
}

function Stop-TargetExe([string]$exe) {
    $full = [System.IO.Path]::GetFullPath($exe)
    $stopped = $false
    Get-Process -Name 'wispterm' -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $null
        try { $path = $_.MainModule.FileName } catch { return }
        if (-not $path) { return }
        if ([System.IO.Path]::GetFullPath($path) -ne $full) { return }
        $stopped = $true
        try { [void]$_.CloseMainWindow() } catch {}
    }
    if (-not $stopped) { return }

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        $alive = $false
        Get-Process -Name 'wispterm' -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $null
            try { $path = $_.MainModule.FileName } catch { return }
            if ($path -and [System.IO.Path]::GetFullPath($path) -eq $full) { $alive = $true }
        }
        if (-not $alive) { return }
        Start-Sleep -Milliseconds 400
    }

    Get-Process -Name 'wispterm' -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $null
        try { $path = $_.MainModule.FileName } catch { return }
        if ($path -and [System.IO.Path]::GetFullPath($path) -eq $full) {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 400
}

function Copy-LockedFile([string]$src, [string]$dest) {
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    try {
        Copy-Item -LiteralPath $src -Destination $dest -Force
        return
    } catch {
        $bak = "$dest.bak"
        if (Test-Path -LiteralPath $bak) {
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $dest) {
            Move-Item -LiteralPath $dest -Destination $bak -Force
        }
        Copy-Item -LiteralPath $src -Destination $dest -Force
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
    }
}

function Write-StartMenuShortcut([string]$exe, [string]$dir) {
    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    if (-not (Test-Path -LiteralPath $programs)) {
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
    }
    $lnk = Join-Path $programs 'WispTerm.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = $dir
    $shortcut.IconLocation = $exe
    $shortcut.Save()
}

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceExe = Join-Path $sourceDir 'wispterm.exe'
if (-not (Test-Path -LiteralPath $sourceExe)) {
    throw (T 'wispterm.exe was not found next to this script. Extract the whole zip first.' '脚本旁边没有 wispterm.exe。请先把整个 zip 解压到一个文件夹。')
}

$sourceDirFull = [System.IO.Path]::GetFullPath($sourceDir)
$destDir = Get-InstallDirFromShortcuts
$createdInstall = $false
if (-not $destDir) {
    $destDir = Join-Path $env:LOCALAPPDATA 'Programs\WispTerm'
    $createdInstall = $true
}
$destDir = [System.IO.Path]::GetFullPath($destDir)
$destExe = Join-Path $destDir 'wispterm.exe'

if ($destDir -eq $sourceDirFull) {
    $menuScript = Join-Path $destDir 'context-menu.ps1'
    if (Test-Path -LiteralPath $menuScript) {
        $menuAction = if ($EnableContextMenu) { 'Install' } else { 'Refresh' }
        & $menuScript -Action $menuAction -InstallDir $destDir
    }
    Write-Host (T 'This folder is already the install. Starting WispTerm.' '当前文件夹就是安装目录，正在启动 WispTerm。')
    Start-Process -FilePath $destExe -WorkingDirectory $destDir
    exit 0
}

Write-Host (T 'Replacing WispTerm at:' '正在替换:')
Write-Host "  $destDir"
if ($createdInstall) {
    Write-Host (T 'No Start menu shortcut found; installing to the default user location.' '没有找到开始菜单快捷方式，将安装到默认用户目录。')
}

New-Item -ItemType Directory -Path $destDir -Force | Out-Null
if (Test-Path -LiteralPath $destExe) {
    Stop-TargetExe $destExe
}

$payloads = @(
    'wispterm.exe'
    'wispterm-ssh-askpass.exe', 'wispterm-ssh-proxy.exe'
    'version.txt'
    'WebView2Loader.dll'
    'conpty.dll'
    'OpenConsole.exe'
    'Replace-WispTerm.cmd'
    'replace-install.ps1'
    'context-menu.ps1'
    'Add-Context-Menu.cmd'
    'Remove-Context-Menu.cmd'
    'uninstall.ps1'
    'Uninstall-WispTerm.cmd'
)
foreach ($name in $payloads) {
    $src = Join-Path $sourceDir $name
    if (Test-Path -LiteralPath $src) {
        Copy-LockedFile $src (Join-Path $destDir $name)
    }
}

$sourceIntegration = Join-Path $sourceDir 'shell-integration'
if (Test-Path -LiteralPath $sourceIntegration) {
    # Retain previous immutable extension/package directories for rollback.
    # Explorer can keep its old DLL loaded until it releases the COM server.
    Get-ChildItem -LiteralPath $sourceIntegration -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($sourceDir.Length).TrimStart('\')
        Copy-LockedFile $_.FullName (Join-Path $destDir $relative)
    }
}

$srcPlugins = Join-Path $sourceDir 'plugins'
if (Test-Path -LiteralPath $srcPlugins) {
    $destPlugins = Join-Path $destDir 'plugins'
    New-Item -ItemType Directory -Path $destPlugins -Force | Out-Null
    Copy-Item -Path (Join-Path $srcPlugins '*') -Destination $destPlugins -Recurse -Force
}

Write-StartMenuShortcut $destExe $destDir
$menuScript = Join-Path $destDir 'context-menu.ps1'
if (Test-Path -LiteralPath $menuScript) {
    $menuAction = if ($EnableContextMenu) { 'Install' } else { 'Refresh' }
    & $menuScript -Action $menuAction -InstallDir $destDir
}
Start-Process -FilePath $destExe -WorkingDirectory $destDir
Write-Host (T 'Done. WispTerm is starting.' '完成，正在启动 WispTerm。')
