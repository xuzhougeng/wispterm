param(
    [Parameter(Mandatory = $true)]
    [string] $ProfileName,
    [string] $RemoteDir = ".config/wispterm/notify-setup"
)

# Install WispTerm notify into a saved WispTerm SSH profile from Windows.
# The profile file is WispTerm's source of truth; this script never prints the
# saved password and uses scp.exe/ssh.exe without ControlMaster options.

$ErrorActionPreference = "Stop"

function ConvertFrom-HexField {
    param([string] $Hex)
    if ([string]::IsNullOrEmpty($Hex)) { return "" }
    if (($Hex.Length % 2) -ne 0) { return $null }
    $bytes = New-Object byte[] ([int]($Hex.Length / 2))
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        try {
            $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
        } catch {
            return $null
        }
    }
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Read-WispTermSshProfiles {
    param([string] $Path)
    $profiles = @()
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }
        $parts = $line -split "`t"
        if ($parts.Count -lt 3) { continue }
        $fields = @()
        for ($i = 0; $i -lt 6; $i++) {
            $raw = if ($i -lt $parts.Count) { $parts[$i] } else { "" }
            $decoded = ConvertFrom-HexField $raw
            if ($null -eq $decoded) { $decoded = "" }
            $fields += $decoded
        }
        $profiles += [pscustomobject]@{
            Name = $fields[0]
            Host = $fields[1]
            User = $fields[2]
            Password = $fields[3]
            Port = if ([string]::IsNullOrWhiteSpace($fields[4])) { "22" } else { $fields[4] }
            ProxyJump = $fields[5]
        }
    }
    return $profiles
}

function Find-Profile {
    param(
        [object[]] $Profiles,
        [string] $Name
    )
    foreach ($profile in $Profiles) {
        if ([string]::Equals($profile.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            return $profile
        }
    }
    foreach ($profile in $Profiles) {
        if ([string]::Equals($profile.Host, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            return $profile
        }
    }
    return $null
}

function Quote-Sh {
    param([string] $Value)
    return [string]::Concat("'", $Value.Replace("'", "'\''"), "'")
}

function Invoke-Checked {
    param(
        [string] $Exe,
        [string[]] $ArgsList,
        [string] $Label
    )
    Write-Host $Label
    & $Exe @ArgsList
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

$ScriptDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
$NotifySrc = Join-Path $ScriptDir "wispterm-notify.sh"
$InstallSrc = Join-Path $ScriptDir "install-wispterm-notify.sh"
if (-not (Test-Path -LiteralPath $NotifySrc)) { throw "Missing notifier script: $NotifySrc" }
if (-not (Test-Path -LiteralPath $InstallSrc)) { throw "Missing installer script: $InstallSrc" }

$profilePath = if ($env:APPDATA) {
    Join-Path $env:APPDATA "wispterm\ssh_hosts"
} else {
    Join-Path $HOME ".config/wispterm/ssh_hosts"
}
if (-not (Test-Path -LiteralPath $profilePath)) {
    throw "WispTerm SSH profile file not found: $profilePath"
}

$profiles = @(Read-WispTermSshProfiles $profilePath)
$profile = Find-Profile $profiles $ProfileName
if ($null -eq $profile) {
    $names = ($profiles | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ", "
    throw "No WispTerm SSH profile matched '$ProfileName'. Available profiles: $names"
}
if ([string]::IsNullOrWhiteSpace($profile.Host) -or [string]::IsNullOrWhiteSpace($profile.User)) {
    throw "Profile '$ProfileName' is missing host or user."
}

$sshExe = "ssh.exe"
$scpExe = "scp.exe"
$dest = "$($profile.User)@$($profile.Host)"
$sshArgs = @()
$scpArgs = @()
if (-not [string]::IsNullOrWhiteSpace($profile.Port)) {
    $sshArgs += @("-p", $profile.Port)
    $scpArgs += @("-P", $profile.Port)
}
if (-not [string]::IsNullOrWhiteSpace($profile.ProxyJump)) {
    $sshArgs += @("-J", $profile.ProxyJump)
    $scpArgs += @("-J", $profile.ProxyJump)
}

$oldAskpass = $env:SSH_ASKPASS
$oldAskpassRequire = $env:SSH_ASKPASS_REQUIRE
$oldDisplay = $env:DISPLAY
$oldPassword = $env:WISPTERM_SSH_PASSWORD
$askpassDir = $null
try {
    if (-not [string]::IsNullOrEmpty($profile.Password)) {
        $askpassDir = Join-Path ([IO.Path]::GetTempPath()) ("wispterm-ssh-askpass-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $askpassDir | Out-Null
        $askpass = Join-Path $askpassDir "askpass.cmd"
        [IO.File]::WriteAllText($askpass, "@echo off`r`necho %WISPTERM_SSH_PASSWORD%`r`n", [Text.Encoding]::ASCII)
        $env:SSH_ASKPASS = $askpass
        $env:SSH_ASKPASS_REQUIRE = "force"
        $env:DISPLAY = "wispterm"
        $env:WISPTERM_SSH_PASSWORD = $profile.Password
    }

    $remoteDirQuoted = Quote-Sh $RemoteDir
    Invoke-Checked $sshExe (@($sshArgs + $dest + "mkdir -p $remoteDirQuoted")) "remote: create notify setup directory"

    $remoteTarget = "${dest}:$RemoteDir/"
    Invoke-Checked $scpExe (@($scpArgs + $NotifySrc + $InstallSrc + $remoteTarget)) "remote: scp notify setup scripts"

    $remoteInstaller = Quote-Sh "$RemoteDir/install-wispterm-notify.sh"
    Invoke-Checked $sshExe (@($sshArgs + $dest + "sh $remoteInstaller")) "remote: run notify installer"
} finally {
    $env:SSH_ASKPASS = $oldAskpass
    $env:SSH_ASKPASS_REQUIRE = $oldAskpassRequire
    $env:DISPLAY = $oldDisplay
    $env:WISPTERM_SSH_PASSWORD = $oldPassword
    if ($askpassDir -and (Test-Path -LiteralPath $askpassDir)) {
        Remove-Item -LiteralPath $askpassDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Installed WispTerm notify on SSH profile '$($profile.Name)' ($dest)."
Write-Host "Verify from the connected SSH tab:"
Write-Host "  echo '{`"hook_event_name`":`"Notification`",`"title`":`"WispTerm`",`"message`":`"setup ok`"}' | ~/.config/wispterm/wispterm-notify.sh"
