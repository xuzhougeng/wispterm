param(
    [string]$ProblemType = "",
    [string]$UserDescription = "",
    [string]$ReproductionSteps = "",
    [string]$PhanttyExePath = "",
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:FailedCommands = New-Object System.Collections.Generic.List[string]

function Add-FailedCommand {
    param([string]$Label, [string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        $script:FailedCommands.Add($Label) | Out-Null
    } else {
        $script:FailedCommands.Add("$Label ($Reason)") | Out-Null
    }
}

function Format-Value {
    param([object]$Value)
    if ($null -eq $Value) { return "unavailable" }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return "unavailable" }
    return ($text -replace "`r", "" -replace "`n", " ").Trim()
}

function Test-PathSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return Test-Path -LiteralPath $Path } catch { return $false }
}

function Get-FileSummary {
    param([string]$Path)
    if (-not (Test-PathSafe $Path)) { return "not found" }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return "present ($($item.Length) bytes)"
    } catch {
        return "present (size unavailable)"
    }
}

function Invoke-CapturedCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 5000,
        [string]$Label = ""
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-PathSafe $FilePath)) {
        if ($Label) { Add-FailedCommand $Label "command not found" }
        return $null
    }

    $escapedArgs = @()
    foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') {
            $escapedArgs += '"' + (($arg -replace '\\', '\\') -replace '"', '\"') + '"'
        } else {
            $escapedArgs += $arg
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $escapedArgs -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch {}
            if ($Label) { Add-FailedCommand $Label "timeout" }
            return $null
        }
        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        $stderr = $process.StandardError.ReadToEnd().Trim()
        $combined = (($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        if ($process.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($combined)) {
            if ($Label) { Add-FailedCommand $Label "exit $($process.ExitCode)" }
            return $null
        }
        return $combined.Trim()
    } catch {
        if ($Label) { Add-FailedCommand $Label $_.Exception.Message }
        return $null
    } finally {
        $process.Dispose()
    }
}

function Get-CommandPath {
    param([string]$Name)
    try {
        $cmd = Get-Command $Name -ErrorAction Stop | Select-Object -First 1
        return $cmd.Source
    } catch {
        return $null
    }
}

function Find-PhanttyExe {
    param([string]$ProvidedPath)

    if (Test-PathSafe $ProvidedPath) { return (Resolve-Path -LiteralPath $ProvidedPath).Path }

    try {
        $proc = Get-Process -Name phantty -ErrorAction SilentlyContinue |
            Where-Object { $_.Path } |
            Select-Object -First 1
        if ($proc -and (Test-PathSafe $proc.Path)) { return $proc.Path }
    } catch {}

    $fromPath = Get-CommandPath "phantty.exe"
    if (Test-PathSafe $fromPath) { return $fromPath }

    $cwdCandidate = Join-Path (Get-Location).Path "phantty.exe"
    if (Test-PathSafe $cwdCandidate) { return $cwdCandidate }

    return $null
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    try {
        $props = Get-ItemProperty -Path $Path -ErrorAction Stop
        return $props.$Name
    } catch {
        return $null
    }
}

function Get-WindowsInfo {
    $cv = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $product = Get-RegistryValue $cv "ProductName"
    $display = Get-RegistryValue $cv "DisplayVersion"
    $build = Get-RegistryValue $cv "CurrentBuild"
    $ubr = Get-RegistryValue $cv "UBR"
    $edition = (($product, $display) | Where-Object { $_ }) -join " "
    if ($build) {
        if ($ubr -ne $null) { $edition = "$edition (build $build.$ubr)" }
        else { $edition = "$edition (build $build)" }
    }

    $parent = "unavailable"
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
        if ($proc.ParentProcessId) {
            $parentProc = Get-Process -Id $proc.ParentProcessId -ErrorAction SilentlyContinue
            if ($parentProc) { $parent = $parentProc.ProcessName }
        }
    } catch {}

    return [pscustomobject]@{
        Edition = Format-Value $edition
        Architecture = Format-Value $env:PROCESSOR_ARCHITECTURE
        Locale = Format-Value ([System.Globalization.CultureInfo]::CurrentCulture.Name)
        PowerShell = Format-Value ("$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)")
        CurrentShell = Format-Value $parent
    }
}

function Get-SshInfo {
    $ssh = Get-CommandPath "ssh.exe"
    $scp = Get-CommandPath "scp.exe"
    $sshVersion = if ($ssh) { Invoke-CapturedCommand $ssh @("-V") 5000 "ssh.exe -V" } else { $null }
    $scpVersion = if ($scp) { Invoke-CapturedCommand $scp @("-V") 5000 "scp.exe -V" } else { $null }
    if ($scpVersion -and $scpVersion -match "(?i)(unknown option|usage:)") {
        $scpVersion = "unavailable (scp.exe does not expose a version; compare ssh.exe path)"
    }
    if ($scp -and [string]::IsNullOrWhiteSpace($scpVersion)) { $scpVersion = "unavailable" }

    $sshHosts = if ($env:APPDATA) { Join-Path $env:APPDATA "phantty\ssh_hosts" } else { $null }
    $profileCount = "not found"
    if (Test-PathSafe $sshHosts) {
        try {
            $profileCount = @((Get-Content -LiteralPath $sshHosts -ErrorAction Stop) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        } catch {
            $profileCount = "unavailable"
        }
    }

    $sameDir = "unavailable"
    if ($ssh -and $scp) {
        try {
            $sameDir = ([System.IO.Path]::GetDirectoryName($ssh) -eq [System.IO.Path]::GetDirectoryName($scp))
        } catch {}
    }

    return [pscustomobject]@{
        SshPath = Format-Value $ssh
        SshVersion = Format-Value $sshVersion
        ScpPath = Format-Value $scp
        ScpVersion = Format-Value $scpVersion
        SameDirectory = Format-Value $sameDir
        SshHosts = if (Test-PathSafe $sshHosts) { "present" } else { "not found" }
        ProfileCount = Format-Value $profileCount
    }
}

function Get-WebView2Version {
    $roots = @(
        "HKCU:\Software\Microsoft\EdgeUpdate\Clients",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients"
    )
    foreach ($root in $roots) {
        if (-not (Test-PathSafe $root)) { continue }
        try {
            foreach ($child in Get-ChildItem -Path $root -ErrorAction Stop) {
                $props = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction SilentlyContinue
                $nameProp = $props.PSObject.Properties["name"]
                $versionProp = $props.PSObject.Properties["pv"]
                $name = if ($nameProp) { [string]$nameProp.Value } else { "" }
                if ($name -like "*WebView2*") {
                    $version = if ($versionProp) { [string]$versionProp.Value } else { "" }
                    if (-not [string]::IsNullOrWhiteSpace($version)) {
                        return "$name $version"
                    }
                    return $name
                }
            }
        } catch {}
    }
    return "not found"
}

function Get-RenderingInfo {
    $gpuLines = New-Object System.Collections.Generic.List[string]
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
        foreach ($gpu in $gpus) {
            $parts = @()
            if ($gpu.Name) { $parts += $gpu.Name }
            if ($gpu.DriverVersion) { $parts += "driver $($gpu.DriverVersion)" }
            if ($parts.Count -gt 0) { $gpuLines.Add(($parts -join ", ")) | Out-Null }
        }
    } catch {}

    return [pscustomobject]@{
        GPU = if ($gpuLines.Count -gt 0) { $gpuLines -join "; " } else { "unavailable" }
        OpenGL = "unavailable"
        DpiScaling = "unavailable"
        WebView2Runtime = Get-WebView2Version
    }
}

function Get-PhanttyInfo {
    $exe = Find-PhanttyExe $PhanttyExePath
    $exeDir = if ($exe) { Split-Path -Parent $exe } else { $null }
    $versionOutput = if ($exe) { Invoke-CapturedCommand $exe @("--version") 5000 "phantty.exe --version" } else { $null }
    $configPath = if ($exe) { Invoke-CapturedCommand $exe @("--show-config-path") 5000 "phantty.exe --show-config-path" } else { $null }
    if ([string]::IsNullOrWhiteSpace($configPath) -and $env:APPDATA) {
        $configPath = Join-Path $env:APPDATA "phantty\config"
    }

    $versionTxt = if ($exeDir) { Join-Path $exeDir "version.txt" } else { $null }
    $versionTxtValue = $null
    if (Test-PathSafe $versionTxt) {
        try { $versionTxtValue = (Get-Content -LiteralPath $versionTxt -TotalCount 1 -ErrorAction Stop).Trim() } catch {}
    }

    $loader = if ($exeDir) { Join-Path $exeDir "WebView2Loader.dll" } else { $null }
    $portableConfig = if ($exeDir) { Join-Path $exeDir "phantty.conf" } else { $null }
    $package = "unknown"
    if ($exeDir) {
        if (Test-PathSafe $loader) { $package = "portable-webview2 or WebView-enabled package" }
        else { $package = "portable or installed package (WebView2Loader.dll not found)" }
    }

    $appDataDir = if ($env:APPDATA) { Join-Path $env:APPDATA "phantty" } else { $null }
    $appDataConfig = if ($env:APPDATA) { Join-Path $env:APPDATA "phantty\config" } else { $null }
    $session = if ($appDataDir) { Join-Path $appDataDir "session.json" } else { $null }
    $logs = if ($appDataDir) { Join-Path $appDataDir "logs" } else { $null }

    return [pscustomobject]@{
        ExePath = Format-Value $exe
        ExeDir = $exeDir
        Version = Format-Value $versionOutput
        VersionTxt = Format-Value $versionTxtValue
        Package = Format-Value $package
        ConfigPath = Format-Value $configPath
        PortableConfig = Get-FileSummary $portableConfig
        WebView2Loader = Get-FileSummary $loader
        AppDataConfig = Get-FileSummary $appDataConfig
        SessionJson = Get-FileSummary $session
        Logs = if (Test-PathSafe $logs) { "present" } else { "not found" }
    }
}

function Test-SensitiveConfigKey {
    param([string]$Key, [string]$Line)
    $text = "$Key $Line"
    return $text -match "(?i)(password|token|secret|fingerprint|remote-session-key|authorization|bearer|api-key|private-key|identity-file)"
}

function Redact-RemoteUrl {
    param([string]$Value)
    try {
        $uri = [Uri]$Value.Trim()
        if ($uri.Host) {
            if ($uri.IsDefaultPort) { return "$($uri.Scheme)://$($uri.Host)/..." }
            return "$($uri.Scheme)://$($uri.Host):$($uri.Port)/..."
        }
    } catch {}
    return "<redacted>"
}

function Redact-ConfigLine {
    param([string]$Line)
    if ($Line -match "^\s*#") { return $Line }
    if ($Line -notmatch "^\s*([^=:#]+?)\s*=\s*(.*)$") {
        if (Test-SensitiveConfigKey "" $Line) { return "<redacted>" }
        return $Line
    }

    $key = $Matches[1].Trim()
    $value = $Matches[2]
    if ($key -match "(?i)^remote-server-url$") {
        return "$key = $(Redact-RemoteUrl $value)"
    }
    if (Test-SensitiveConfigKey $key $Line) {
        return "$key = <redacted>"
    }
    return $Line
}

function Get-ConfigExcerpt {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-PathSafe $Path)) {
        return @("# config not found")
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $maxBytes = 32768
        $maxLines = 160
        $lines = Get-Content -LiteralPath $Path -TotalCount $maxLines -ErrorAction Stop
        $redacted = @($lines | ForEach-Object { Redact-ConfigLine $_ })
        if ($item.Length -gt $maxBytes -or $lines.Count -ge $maxLines) {
            $redacted += "# truncated for issue report"
        }
        return $redacted
    } catch {
        Add-FailedCommand "read Phantty config" $_.Exception.Message
        return @("# config unavailable")
    }
}

function Get-IssueHints {
    param([string]$Type)
    switch -Regex ($Type) {
        "(?i)startup|crash" {
            return @(
                "- Startup/crash: describe whether a window appears before exit.",
                "- Startup/crash: check Windows Event Viewer for an Application Error mentioning phantty.exe."
            )
        }
        "(?i)keyboard|input" {
            return @(
                "- Keyboard/input: include the exact key combination, keyboard layout, IME, and target CLI/TUI.",
                "- Keyboard/input: mention whether the key works in Windows Terminal or another terminal."
            )
        }
        "(?i)selection|copy|scroll" {
            return @(
                "- Selection/copy/scrolling: include theme/background settings and whether the issue happens in a shell, Codex CLI, or another TUI.",
                "- Selection/copy/scrolling: attach a screenshot or short screen recording if the visual selection is wrong."
            )
        }
        "(?i)ssh|scp" {
            return @(
                "- SSH/SCP: include whether password auth or key auth is used, but do not paste the password or private key.",
                "- SSH/SCP: include the exact OpenSSH error text if an operation fails."
            )
        }
        "(?i)file explorer" {
            return @(
                "- File explorer: state whether the local or SSH file explorer is involved.",
                "- File explorer: include the file type and path pattern without secrets."
            )
        }
        "(?i)webview|browser" {
            return @(
                "- WebView2/browser panel: mention whether the package includes WebView2Loader.dll.",
                "- WebView2/browser panel: include the URL type or workflow, but redact credentials."
            )
        }
        "(?i)update|updater" {
            return @(
                "- Updater: include the current package flavor and version.txt value.",
                "- Updater: include updater log text only after reviewing it for secrets."
            )
        }
        "(?i)remote" {
            return @(
                "- Remote console: do not paste remote session keys, fingerprints, or relay secrets.",
                "- Remote console: include whether the browser login page or console shell is failing."
            )
        }
        default { return @() }
    }
}

function New-MarkdownReport {
    $phantty = Get-PhanttyInfo
    $windows = Get-WindowsInfo
    $ssh = Get-SshInfo
    $rendering = Get-RenderingInfo
    $configLines = Get-ConfigExcerpt $phantty.ConfigPath
    $hints = Get-IssueHints $ProblemType

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("## Phantty Diagnostic Report") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Summary") | Out-Null
    $lines.Add("- Problem type: $(Format-Value $ProblemType)") | Out-Null
    $lines.Add("- User description: $(Format-Value $UserDescription)") | Out-Null
    $lines.Add("- Reproduction steps: $(Format-Value $ReproductionSteps)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Phantty") | Out-Null
    $lines.Add("- Version: $($phantty.Version)") | Out-Null
    $lines.Add("- version.txt: $($phantty.VersionTxt)") | Out-Null
    $lines.Add("- Package: $($phantty.Package)") | Out-Null
    $lines.Add("- Executable path: $($phantty.ExePath)") | Out-Null
    $lines.Add("- Config path: $($phantty.ConfigPath)") | Out-Null
    $lines.Add("- Portable config: $($phantty.PortableConfig)") | Out-Null
    $lines.Add("- WebView2Loader.dll: $($phantty.WebView2Loader)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Windows") | Out-Null
    $lines.Add("- Edition/version/build: $($windows.Edition)") | Out-Null
    $lines.Add("- Architecture: $($windows.Architecture)") | Out-Null
    $lines.Add("- Locale: $($windows.Locale)") | Out-Null
    $lines.Add("- PowerShell: $($windows.PowerShell)") | Out-Null
    $lines.Add("- Current shell: $($windows.CurrentShell)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### SSH/SCP") | Out-Null
    $lines.Add("- ssh.exe path: $($ssh.SshPath)") | Out-Null
    $lines.Add("- ssh.exe version: $($ssh.SshVersion)") | Out-Null
    $lines.Add("- scp.exe path: $($ssh.ScpPath)") | Out-Null
    $lines.Add("- scp.exe version: $($ssh.ScpVersion)") | Out-Null
    $lines.Add("- ssh/scp same directory: $($ssh.SameDirectory)") | Out-Null
    $lines.Add("- ssh_hosts exists: $($ssh.SshHosts)") | Out-Null
    $lines.Add("- saved profile count: $($ssh.ProfileCount)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Rendering") | Out-Null
    $lines.Add("- GPU: $($rendering.GPU)") | Out-Null
    $lines.Add("- OpenGL: $($rendering.OpenGL)") | Out-Null
    $lines.Add("- DPI/scaling: $($rendering.DpiScaling)") | Out-Null
    $lines.Add("- WebView2 runtime: $($rendering.WebView2Runtime)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Relevant Files") | Out-Null
    $lines.Add("- `%APPDATA%\phantty\config`: $($phantty.AppDataConfig)") | Out-Null
    $lines.Add("- `%APPDATA%\phantty\session.json`: $($phantty.SessionJson)") | Out-Null
    $lines.Add("- `%APPDATA%\phantty\logs`: $($phantty.Logs)") | Out-Null
    $lines.Add("- portable `phantty.conf`: $($phantty.PortableConfig)") | Out-Null
    $lines.Add("") | Out-Null
    if ($hints.Count -gt 0) {
        $lines.Add("### Issue-Type Notes") | Out-Null
        foreach ($hint in $hints) { $lines.Add($hint) | Out-Null }
        $lines.Add("") | Out-Null
    }
    $lines.Add("### Config Excerpt") | Out-Null
    $lines.Add("````ini") | Out-Null
    foreach ($line in $configLines) { $lines.Add($line) | Out-Null }
    $lines.Add("````") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Notes") | Out-Null
    $lines.Add("- Sensitive fields redacted: yes") | Out-Null
    if ($script:FailedCommands.Count -eq 0) {
        $lines.Add("- Commands that failed: none") | Out-Null
    } else {
        $lines.Add("- Commands that failed: $($script:FailedCommands -join '; ')") | Out-Null
    }
    $lines.Add("- Please review this report before posting it publicly.") | Out-Null
    return ($lines -join "`n")
}

function Invoke-SelfTest {
    $line = Redact-ConfigLine "remote-session-key = secret-value"
    if ($line -ne "remote-session-key = <redacted>") { throw "remote-session-key was not redacted" }

    $line = Redact-ConfigLine "remote-server-url = https://example.com/path?token=abc"
    if ($line -ne "remote-server-url = https://example.com/...") { throw "remote-server-url was not reduced to origin" }

    $line = Redact-ConfigLine "keybind = ctrl+shift+p=toggle_command_palette"
    if ($line -ne "keybind = ctrl+shift+p=toggle_command_palette") { throw "safe keybind was incorrectly redacted" }

    $hints = Get-IssueHints "SSH/SCP"
    if ($hints.Count -lt 1) { throw "SSH/SCP hints missing" }

    "Self-test passed"
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

New-MarkdownReport
