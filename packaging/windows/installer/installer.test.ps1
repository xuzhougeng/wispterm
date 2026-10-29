# End-to-end check of installer\wispterm.nsi on a Windows runner: build the
# setup exe from a stub payload with build-installer.ps1, install it silently
# into a temp folder, check the files, Start-menu shortcut, and Add/Remove
# Programs entry, then uninstall silently and check what is removed and what
# is kept. Needs makensis (choco install nsis) and Windows; no zig build.
#
#   pwsh -NoProfile -File .\packaging\windows\installer\installer.test.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'installer.test.ps1 runs on Windows only.' }

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "ok $Message" } else { Write-Host "FAIL $Message"; $failures.Add($Message) }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -eq $Expected) { Write-Host "ok $Message" } else { Write-Host "FAIL $Message expected [$Expected] actual [$Actual]"; $failures.Add($Message) }
}
function Get-ShortcutTarget {
    param([string]$Link)
    if (-not (Test-Path -LiteralPath $Link)) { return $null }
    $shell = New-Object -ComObject WScript.Shell
    return [string]$shell.CreateShortcut($Link).TargetPath
}

$packaging = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wispterm-installer-' + [guid]::NewGuid().ToString('n'))
$payload = Join-Path $tmp 'payload'
$out = Join-Path $tmp 'out'
$installDir = Join-Path $tmp 'WispTerm'
$startMenuLink = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WispTerm.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'WispTerm.lnk'
$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WispTerm'
$appKey = 'HKCU:\Software\WispTerm'
$version = 'v0.0.1-test'

# A real install on this user would be clobbered by the shortcut and registry
# checks below; refuse rather than guess.
if ((Test-Path -LiteralPath $startMenuLink) -or (Test-Path -LiteralPath $uninstKey)) {
    throw 'WispTerm is already installed for this user. installer.test.ps1 runs on a disposable runner only.'
}

try {
    # Stub payload: the files the installer and uninstall.ps1 care about, with
    # placeholder bytes for the binaries. uninstall.ps1 is the real one.
    New-Item -ItemType Directory -Force -Path (Join-Path $payload 'plugins\skills') | Out-Null
    Set-Content -LiteralPath (Join-Path $payload 'wispterm.exe') -Value 'stub exe' -Encoding ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $payload 'wispterm-ssh-askpass.exe') -Value 'stub askpass' -Encoding ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $payload 'wispterm-ssh-proxy.exe') -Value 'stub proxy' -Encoding ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $payload 'version.txt') -Value $version -Encoding ascii
    Set-Content -LiteralPath (Join-Path $payload 'plugins\skills\sample.md') -Value 'skill' -Encoding ascii
    foreach ($name in @('uninstall.ps1', 'Uninstall-WispTerm.cmd', 'replace-install.ps1', 'Replace-WispTerm.cmd')) {
        Copy-Item -LiteralPath (Join-Path $packaging $name) -Destination (Join-Path $payload $name) -Force
    }

    $built = & (Join-Path $packaging 'build-installer.ps1') -PayloadDir $payload -OutputDir $out -Version $version
    $setup = @($built)[-1]
    Assert-True (Test-Path -LiteralPath $setup -PathType Leaf) 'build-installer.ps1 writes the setup exe'
    Assert-Equal ([IO.Path]::GetFileName($setup)) "wispterm-windows-setup-$version.exe" 'setup exe is named after the version'

    # Leftovers an installed copy may carry: a user file that must survive, and
    # in-place-update debris that Setup clears.
    New-Item -ItemType Directory -Force -Path (Join-Path $installDir '.update\v0.0.0') | Out-Null
    Set-Content -LiteralPath (Join-Path $installDir 'user-note.txt') -Value 'mine' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $installDir 'wispterm.exe.wispterm-old') -Value 'old' -Encoding ascii

    $install = Start-Process -FilePath $setup -ArgumentList @('/S', '/DESKTOP', "/D=$installDir") -Wait -PassThru
    Assert-Equal $install.ExitCode 0 'silent install exits 0'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $installDir 'wispterm.exe'))) 'stub exe' 'wispterm.exe is installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'wispterm-ssh-askpass.exe')) 'askpass helper is installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'wispterm-ssh-proxy.exe')) 'network proxy helper is installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'plugins\skills\sample.md')) 'bundled skills are installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'Uninstall.exe')) 'Uninstall.exe is written'
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'user-note.txt')) 'install keeps a user file in the folder'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installDir 'wispterm.exe.wispterm-old'))) 'install removes in-place-update leftovers'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installDir '.update'))) 'install removes the staging folder'
    Assert-Equal (Get-ShortcutTarget $startMenuLink) (Join-Path $installDir 'wispterm.exe') 'Start-menu shortcut points at the installed exe'
    Assert-Equal (Get-ShortcutTarget $desktopLink) (Join-Path $installDir 'wispterm.exe') '/DESKTOP adds a desktop shortcut'
    $entry = Get-ItemProperty -LiteralPath $uninstKey
    Assert-Equal $entry.DisplayName 'WispTerm' 'Add/Remove Programs entry is written'
    Assert-Equal $entry.DisplayVersion '0.0.1-test' 'DisplayVersion drops the v prefix'
    Assert-Equal $entry.InstallLocation $installDir 'InstallLocation is the install folder'
    Assert-Equal $entry.QuietUninstallString "`"$installDir\Uninstall.exe`" /S" 'QuietUninstallString runs the uninstaller silently'
    Assert-Equal (Get-ItemProperty -LiteralPath $appKey).InstallDir $installDir 'InstallDir is remembered for the next Setup'

    # A second run over the same folder: an upgrade must not fail on the files
    # it wrote before.
    $again = Start-Process -FilePath $setup -ArgumentList @('/S', "/D=$installDir") -Wait -PassThru
    Assert-Equal $again.ExitCode 0 'silent reinstall over the same folder exits 0'

    # _?= runs the uninstaller in place so -Wait and the exit code mean something.
    $uninstall = Start-Process -FilePath (Join-Path $installDir 'Uninstall.exe') -ArgumentList @('/S', "_?=$installDir") -Wait -PassThru
    Assert-Equal $uninstall.ExitCode 0 'silent uninstall exits 0'
    foreach ($name in @('wispterm.exe', 'wispterm-ssh-askpass.exe', 'version.txt', 'uninstall.ps1', 'Uninstall-WispTerm.cmd', 'Replace-WispTerm.cmd', 'replace-install.ps1')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installDir $name))) "uninstall removes $name"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'user-note.txt')) 'uninstall keeps the user file'
    Assert-True (Test-Path -LiteralPath (Join-Path $installDir 'plugins\skills\sample.md')) 'uninstall keeps plugins, as uninstall.ps1 does'
    # With _?= the uninstaller runs from $INSTDIR and, like any running exe,
    # cannot delete itself; a normal run copies itself to %TEMP% first and the
    # in-place Delete succeeds. So only Uninstall.exe may be left beside the
    # user's files here.
    $leftover = @(Get-ChildItem -LiteralPath $installDir -File | Where-Object { $_.Name -ne 'Uninstall.exe' -and $_.Name -ne 'user-note.txt' } | ForEach-Object { $_.Name })
    Assert-Equal ($leftover -join ',') '' 'uninstall leaves no payload file besides the in-place uninstaller'
    $dirs = @(Get-ChildItem -LiteralPath $installDir -Directory | ForEach-Object { $_.Name })
    Assert-Equal ($dirs -join ',') 'plugins' 'uninstall leaves only the plugins folder'
    Assert-True (-not (Test-Path -LiteralPath $startMenuLink)) 'uninstall removes the Start-menu shortcut'
    Assert-True (-not (Test-Path -LiteralPath $desktopLink)) 'uninstall removes the desktop shortcut'
    Assert-True (-not (Test-Path -LiteralPath $uninstKey)) 'uninstall removes the Add/Remove Programs entry'
    Assert-True (-not (Test-Path -LiteralPath $appKey)) 'uninstall removes the WispTerm key once empty'
} finally {
    foreach ($link in @($startMenuLink, $desktopLink)) {
        if ((Test-Path -LiteralPath $link) -and ((Get-ShortcutTarget $link) -like "$tmp*")) {
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($key in @($uninstKey, $appKey)) {
        if (Test-Path -LiteralPath $key) {
            $location = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue)
            if ($location -and (($location.PSObject.Properties['InstallLocation'] -and $location.InstallLocation -like "$tmp*") -or ($location.PSObject.Properties['InstallDir'] -and $location.InstallDir -like "$tmp*"))) {
                Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) assertion(s) failed."
    exit 1
}
Write-Host 'installer tests passed'
