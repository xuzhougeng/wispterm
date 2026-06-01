param()

# Idempotently install the Windows PowerShell WispTerm notifier and wire Claude
# Code Stop/Notification hooks plus Codex config.toml notify.

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param(
        [string] $Path,
        [string] $Text
    )
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-TextOrEmpty {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) {
        return [IO.File]::ReadAllText($Path)
    }
    return ""
}

function Ensure-Property {
    param(
        [object] $Object,
        [string] $Name,
        [object] $Value
    )
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Ensure-ClaudeHook {
    param(
        [object] $Settings,
        [string] $EventName,
        [string] $Command
    )
    $hooks = $Settings.PSObject.Properties["hooks"].Value
    Ensure-Property $hooks $EventName @()
    $entries = @($hooks.PSObject.Properties[$EventName].Value)

    foreach ($entry in $entries) {
        foreach ($hook in @($entry.hooks)) {
            if ($hook.type -eq "command" -and $hook.command -eq $Command) {
                return "present"
            }
        }
    }

    $entries = @($entries + [pscustomobject]@{
        hooks = @([pscustomobject]@{
            type = "command"
            command = $Command
        })
    })
    $hooks.PSObject.Properties[$EventName].Value = $entries
    return "added"
}

function ConvertTo-TomlBasicString {
    param([string] $Value)
    return $Value.Replace("\", "\\").Replace('"', '\"')
}

$ScriptDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
$NotifySrc = Join-Path $ScriptDir "wispterm-notify.ps1"
if (-not (Test-Path -LiteralPath $NotifySrc)) {
    throw "Missing notifier script: $NotifySrc"
}

$DestDir = if ($env:APPDATA) {
    Join-Path $env:APPDATA "wispterm"
} else {
    Join-Path $HOME ".config/wispterm"
}
$Dest = Join-Path $DestDir "wispterm-notify.ps1"
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Copy-Item -LiteralPath $NotifySrc -Destination $Dest -Force
Write-Host "notify program -> $Dest"

$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }

# Claude Code settings.json
$ClaudeDir = Join-Path $HomeDir ".claude"
$ClaudeSettings = Join-Path $ClaudeDir "settings.json"
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
if (-not (Test-Path -LiteralPath $ClaudeSettings)) {
    Write-Utf8NoBom $ClaudeSettings "{}`n"
}
Copy-Item -LiteralPath $ClaudeSettings -Destination "$ClaudeSettings.bak" -Force

try {
    $settings = (Read-TextOrEmpty $ClaudeSettings) | ConvertFrom-Json -ErrorAction Stop
} catch {
    $settings = [pscustomobject]@{}
}
if ($null -eq $settings -or $settings -isnot [pscustomobject]) {
    $settings = [pscustomobject]@{}
}
Ensure-Property $settings "hooks" ([pscustomobject]@{})
$hookDest = $Dest.Replace('"', '\"')
$hookCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$hookDest`""
$stopState = Ensure-ClaudeHook $settings "Stop" $hookCommand
$notificationState = Ensure-ClaudeHook $settings "Notification" $hookCommand
Write-Utf8NoBom $ClaudeSettings (($settings | ConvertTo-Json -Depth 16) + "`n")
Write-Host "claude: Stop $stopState, Notification $notificationState"

# Codex config.toml top-level notify
$CodexDir = Join-Path $HomeDir ".codex"
$CodexConfig = Join-Path $CodexDir "config.toml"
New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null
if (-not (Test-Path -LiteralPath $CodexConfig)) {
    Write-Utf8NoBom $CodexConfig ""
}
Copy-Item -LiteralPath $CodexConfig -Destination "$CodexConfig.bak" -Force

$codexContent = Read-TextOrEmpty $CodexConfig
$firstSection = [regex]::Match($codexContent, "(?m)^\s*\[")
$topLevel = if ($firstSection.Success) { $codexContent.Substring(0, $firstSection.Index) } else { $codexContent }
$existingNotify = [regex]::Match($topLevel, "(?m)^\s*notify\s*=.*$")
$tomlDest = ConvertTo-TomlBasicString $Dest
$notifyLine = "notify = [`"powershell.exe`", `"-NoProfile`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", `"$tomlDest`"]"

if (-not $existingNotify.Success) {
    $newContent = if ($codexContent.Length -gt 0) {
        "$notifyLine`n$codexContent"
    } else {
        "$notifyLine`n"
    }
    Write-Utf8NoBom $CodexConfig $newContent
    Write-Host "codex: notify added -> $Dest"
} elseif ($existingNotify.Value -like "*wispterm-notify.ps1*") {
    Write-Host "codex: notify already set to wispterm-notify"
} else {
    Write-Host "WARN: codex already has a different notify (left untouched): $($existingNotify.Value.Trim())"
}

Write-Host ""
Write-Host "Verify in WispTerm:"
Write-Host "  '{`"hook_event_name`":`"Notification`",`"title`":`"WispTerm`",`"message`":`"setup ok`"}' | powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Dest`""
