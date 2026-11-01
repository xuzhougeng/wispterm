# Unregister shell integration before removing its external files. User config
# and additional user-created files in a portable directory are preserved.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$exe = Join-Path $root 'wispterm.exe'
$menu = Join-Path $root 'context-menu.ps1'
if (Test-Path -LiteralPath $menu) { & $menu -Action Remove -InstallDir $root }
# Do not terminate sessions or remove an unrelated copy's shortcuts.
$running = @(Get-Process -Name wispterm -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $exe } catch { $false }
})
if ($running.Count) { throw 'Close this WispTerm installation before uninstalling it. Your sessions have not been terminated.' }
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @('Microsoft\Windows\Start Menu\Programs','Microsoft\Windows\Start Menu\Programs\Startup')) {
    $link = Join-Path $env:APPDATA "$folder\WispTerm.lnk"
    if ((Test-Path -LiteralPath $link) -and $shell.CreateShortcut($link).TargetPath -eq $exe) { Remove-Item -LiteralPath $link -Force }
}
foreach ($name in @('wispterm.exe','wispterm-ssh-askpass.exe', 'wispterm-ssh-proxy.exe','version.txt','WebView2Loader.dll','conpty.dll','OpenConsole.exe',
                   'Replace-WispTerm.cmd','replace-install.ps1','Add-Context-Menu.cmd','Remove-Context-Menu.cmd','context-menu.ps1')) {
    $path = Join-Path $root $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
$integration = Join-Path $root 'shell-integration'
if (Test-Path -LiteralPath $integration) {
    try { Remove-Item -LiteralPath $integration -Recurse -Force }
    catch { Write-Warning 'The menu is unregistered, but Explorer still holds an extension file. Sign out and back in, then remove the remaining shell-integration folder.' }
}
Write-Host 'WispTerm uninstalled. Your configuration, plugins, and other files are preserved.'
