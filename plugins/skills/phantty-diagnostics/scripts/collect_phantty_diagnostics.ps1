param(
    [string]$ProblemType = "",
    [string]$UserDescription = "",
    [string]$ReproductionSteps = "",
    [string]$PhanttyExePath = "",
    [switch]$StartupProbe,
    [switch]$EnableCrashDumps,
    [int]$CrashEventDays = 14,
    [int]$StartupProbeTimeoutMs = 8000,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:FailedCommands = New-Object System.Collections.Generic.List[string]
$script:CrashDumpSetup = "not requested"
$script:StartupProbeResult = "not run"
$script:StartupProbeOutput = @()

function Redact-UrlForPublicReport {
    param([string]$Value)
    try {
        $uri = [Uri]$Value.Trim()
        if ($uri.Host) {
            if ($uri.IsDefaultPort) { return "$($uri.Scheme)://$($uri.Host)/..." }
            return "$($uri.Scheme)://$($uri.Host):$($uri.Port)/..."
        }
    } catch {}
    return "<redacted-url>"
}

function Redact-Text {
    param([string]$Text)
    if ($null -eq $Text) { return $null }

    $redacted = [string]$Text
    $esc = [regex]::Escape([string][char]27)
    $oscPattern = $esc + '\][^\x07]*(?:\x07|' + $esc + '\\)'
    $csiPattern = $esc + '\[[0-?]*[ -/]*[@-~]'
    $redacted = [regex]::Replace($redacted, $oscPattern, "")
    $redacted = [regex]::Replace($redacted, $csiPattern, "")
    $redacted = $redacted -replace $esc, ""
    $redacted = [regex]::Replace($redacted, "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", "")

    $pathPairs = @(
        @{ Path = $env:LOCALAPPDATA; Token = "%LOCALAPPDATA%" },
        @{ Path = $env:APPDATA; Token = "%APPDATA%" },
        @{ Path = $env:USERPROFILE; Token = "%USERPROFILE%" },
        @{ Path = $env:TEMP; Token = "%TEMP%" },
        @{ Path = $env:TMP; Token = "%TMP%" }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Sort-Object { $_.Path.Length } -Descending

    foreach ($pair in $pathPairs) {
        $redacted = [regex]::Replace(
            $redacted,
            [regex]::Escape($pair.Path),
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $pair.Token },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $slashPath = $pair.Path -replace '\\', '/'
        if ($slashPath -ne $pair.Path) {
            $redacted = [regex]::Replace(
                $redacted,
                [regex]::Escape($slashPath),
                [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $pair.Token },
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $redacted = [regex]::Replace($redacted, [regex]::Escape($env:COMPUTERNAME), "<computer>", "IgnoreCase")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and $env:USERNAME.Length -ge 3) {
        $namePattern = '(?<![A-Za-z0-9_@.-])' + [regex]::Escape($env:USERNAME) + '(?![A-Za-z0-9_@.-])'
        $redacted = [regex]::Replace($redacted, $namePattern, "<user>", "IgnoreCase")
    }

    $redacted = $redacted -replace 'S-\d-\d+(?:-\d+)+', '<sid>'
    $redacted = $redacted -replace '(?i)(remote\s+session\s+key\s*[:=]\s*)\S+', '$1<redacted>'
    $redacted = $redacted -replace '(?i)((?:api[-_ ]?key|password|token|secret|authorization|bearer)\s*[:=]\s*)\S+', '$1<redacted>'

    $urlPattern = '(https?://[^\s\)>\]"]+)'
    $redacted = [regex]::Replace($redacted, $urlPattern, {
        param($m)
        $url = $m.Groups[1].Value
        if ($url -match '(?i)(github\.com/xuzhougeng/phantty|github\.com/ghostty-org/ghostty)') {
            return $url
        }
        return Redact-UrlForPublicReport $url
    })

    return $redacted
}

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
    return (Redact-Text (($text -replace "`r", "" -replace "`n", " ").Trim()))
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

function Get-DirectoryFileSummary {
    param([string]$Path, [string]$Filter = "*")
    if (-not (Test-PathSafe $Path)) { return "not found" }
    try {
        $items = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -ErrorAction Stop)
        if ($items.Count -eq 0) { return "present (0 matching files)" }
        $latest = $items | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        return "present ($($items.Count) matching files, latest $($latest.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")), $($latest.Length) bytes)"
    } catch {
        return "present (contents unavailable)"
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

function Get-DpiInfo {
    try {
        $desktop = Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -ErrorAction Stop
        $logPixelsProp = $desktop.PSObject.Properties["LogPixels"]
        if ($logPixelsProp) {
            $logPixels = [int]$logPixelsProp.Value
            if ($logPixels -gt 0) {
                $scale = [Math]::Round(($logPixels / 96.0) * 100)
                return "LogPixels=$logPixels (~$scale%)"
            }
        }
        return "default or per-monitor"
    } catch {
        return "unavailable"
    }
}

function Get-MonitorInfo {
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screens = [System.Windows.Forms.Screen]::AllScreens
        foreach ($s in $screens) {
            $primary = if ($s.Primary) { " [primary]" } else { "" }
            $lines.Add("$($s.DeviceName): $($s.Bounds.Width)x$($s.Bounds.Height) bits=$($s.BitsPerPixel)$primary") | Out-Null
        }
    } catch {
        try {
            $monitors = Get-CimInstance Win32_DesktopMonitor -ErrorAction Stop
            foreach ($m in $monitors) {
                $w = if ($m.ScreenWidth) { $m.ScreenWidth } else { "?" }
                $h = if ($m.ScreenHeight) { $m.ScreenHeight } else { "?" }
                $lines.Add("$($m.Name): ${w}x${h}") | Out-Null
            }
        } catch {}
    }
    if ($lines.Count -eq 0) { return "unavailable" }
    return ($lines -join "; ")
}

function Get-CpuSample {
    param([int]$Seconds = 3)
    try {
        $procs = Get-Process -Name phantty -ErrorAction SilentlyContinue
        if (-not $procs) { return "phantty.exe not running during sample" }
        $proc = $procs | Sort-Object CPU -Descending | Select-Object -First 1
        $t0 = $proc.TotalProcessorTime
        $w0 = [DateTime]::UtcNow
        Start-Sleep -Seconds $Seconds
        $proc.Refresh()
        $dt = ($proc.TotalProcessorTime - $t0).TotalSeconds
        $wall = ([DateTime]::UtcNow - $w0).TotalSeconds
        $cores = [Environment]::ProcessorCount
        $pct = [Math]::Round($dt / $wall / $cores * 100, 1)
        $mem = [Math]::Round($proc.WorkingSet64 / 1MB, 1)
        return "~$pct% of one core ($Seconds s sample, $cores logical cores, ${mem} MB working set, PID $($proc.Id))"
    } catch {
        Add-FailedCommand "sample CPU" $_.Exception.Message
        return "unavailable"
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

function Get-RenderDiagnosticLogPath {
    if (-not $env:APPDATA) { return $null }
    return Join-Path $env:APPDATA "phantty\render-diagnostic.log"
}

function Get-OpenGlFromRenderDiagnosticLog {
    $path = Get-RenderDiagnosticLogPath
    if (-not (Test-PathSafe $path)) { return "unavailable" }
    try {
        $match = Select-String -LiteralPath $path -Pattern 'gpu vendor=' -ErrorAction Stop | Select-Object -Last 1
        if ($match) { return Format-Value $match.Line }
    } catch {}
    return "unavailable"
}

function Get-RenderDiagnosticLogExcerpt {
    $path = Get-RenderDiagnosticLogPath
    if (-not (Test-PathSafe $path)) {
        return [pscustomobject]@{
            Summary = "not found"
            Lines = @()
        }
    }

    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $lines = @(Get-Content -LiteralPath $path -Tail 80 -ErrorAction Stop | ForEach-Object { Redact-Text $_ })
        return [pscustomobject]@{
            Summary = "present ($($item.Length) bytes, updated $($item.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")))"
            Lines = $lines
        }
    } catch {
        Add-FailedCommand "read render-diagnostic.log" $_.Exception.Message
        return [pscustomobject]@{
            Summary = "unavailable"
            Lines = @()
        }
    }
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
        OpenGL = Get-OpenGlFromRenderDiagnosticLog
        DpiScaling = Get-DpiInfo
        Monitors = Get-MonitorInfo
        WebView2Runtime = Get-WebView2Version
    }
}

function Get-PhanttyInfo {
    $exe = Find-PhanttyExe $PhanttyExePath
    $exeDir = if ($exe) { Split-Path -Parent $exe } else { $null }
    $versionOutput = if ($exe) { Invoke-CapturedCommand $exe @("--version") 5000 "phantty.exe --version" } else { $null }
    $configPath = if ($exe) { Invoke-CapturedCommand $exe @("--show-config-path") 5000 "phantty.exe --show-config-path" } else { $null }
    if ($configPath -match "(?im)^\s*(?:Config file|Config path):\s*(.+?)\s*$") {
        $configPath = $Matches[1]
    }
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
        ExePathRaw = $exe
        ConfigPathRaw = $configPath
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

function Get-EventDataMap {
    param([System.Diagnostics.Eventing.Reader.EventRecord]$Event)
    $map = @{}
    try {
        [xml]$xml = $Event.ToXml()
        $idx = 0
        foreach ($data in @($xml.Event.EventData.Data)) {
            $name = [string]$data.Name
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = "Data$idx"
            }
            $map[$name] = [string]$data.'#text'
            $idx += 1
        }
    } catch {}
    return $map
}

function Format-CrashEvent {
    param([System.Diagnostics.Eventing.Reader.EventRecord]$Event)
    $map = Get-EventDataMap $Event
    $time = $Event.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
    $provider = Format-Value $Event.ProviderName

    if ($Event.Id -eq 1000) {
        $app = if ($map.ContainsKey("AppName")) { $map["AppName"] } else { "phantty.exe" }
        $module = if ($map.ContainsKey("ModuleName")) { $map["ModuleName"] } else { "unavailable" }
        $code = if ($map.ContainsKey("ExceptionCode")) { $map["ExceptionCode"] } else { "unavailable" }
        $offset = if ($map.ContainsKey("FaultingOffset")) { $map["FaultingOffset"] } else { "unavailable" }
        $path = if ($map.ContainsKey("AppPath")) { Format-Value $map["AppPath"] } else { "unavailable" }
        return "- $time Event $($Event.Id) ${provider}: app=$(Format-Value $app), module=$(Format-Value $module), exception=$(Format-Value $code), offset=$(Format-Value $offset), path=$path"
    }

    $message = ""
    try {
        $message = (($Event.FormatDescription() -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    } catch {}
    if ([string]::IsNullOrWhiteSpace($message)) { $message = "Windows Error Reporting entry" }
    return "- $time Event $($Event.Id) ${provider}: $(Format-Value $message)"
}

function Get-PhanttyCrashEvents {
    param([int]$Days = 14)
    $start = (Get-Date).AddDays(-1 * [Math]::Max(1, $Days))
    $eventLines = New-Object System.Collections.Generic.List[string]
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = "Application"; Id = 1000, 1001; StartTime = $start } -MaxEvents 80 -ErrorAction Stop
        foreach ($event in $events) {
            $map = Get-EventDataMap $event
            $text = ""
            try { $text = $event.FormatDescription() } catch {}
            $values = ($map.Values -join " ") + " " + $text
            if ($values -notmatch "(?i)\bphantty\.exe\b") { continue }
            $eventLines.Add((Format-CrashEvent $event)) | Out-Null
            if ($eventLines.Count -ge 5) { break }
        }
    } catch {
        Add-FailedCommand "read Windows Application crash events" $_.Exception.Message
    }

    if ($eventLines.Count -eq 0) { return @("- No recent phantty.exe crash events found in the Windows Application log.") }
    return @($eventLines)
}

function Get-WerDumpRegistryPath {
    return "HKCU:\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\phantty.exe"
}

function Resolve-WerDumpFolder {
    $path = Get-WerDumpRegistryPath
    $folder = Get-RegistryValue $path "DumpFolder"
    if ([string]::IsNullOrWhiteSpace($folder)) {
        if ($env:LOCALAPPDATA) { return Join-Path $env:LOCALAPPDATA "CrashDumps" }
        return $null
    }
    return [System.Environment]::ExpandEnvironmentVariables([string]$folder)
}

function Enable-WerCrashDumpCollection {
    if (-not $env:LOCALAPPDATA) {
        $script:CrashDumpSetup = "failed (LOCALAPPDATA unavailable)"
        return
    }

    $folder = Join-Path $env:LOCALAPPDATA "CrashDumps"
    $regPath = Get-WerDumpRegistryPath
    try {
        New-Item -Force -Path $folder | Out-Null
        New-Item -Force -Path $regPath | Out-Null
        New-ItemProperty -Force -Path $regPath -Name DumpFolder -PropertyType ExpandString -Value $folder | Out-Null
        New-ItemProperty -Force -Path $regPath -Name DumpType -PropertyType DWord -Value 2 | Out-Null
        New-ItemProperty -Force -Path $regPath -Name DumpCount -PropertyType DWord -Value 5 | Out-Null
        $script:CrashDumpSetup = "enabled for phantty.exe at $(Format-Value $folder) (full dumps; do not post publicly)"
    } catch {
        $script:CrashDumpSetup = "failed ($($_.Exception.Message))"
        Add-FailedCommand "enable WER crash dumps" $_.Exception.Message
    }
}

function Get-WerDumpInfo {
    $regPath = Get-WerDumpRegistryPath
    $dumpType = Get-RegistryValue $regPath "DumpType"
    $dumpCount = Get-RegistryValue $regPath "DumpCount"
    $folder = Resolve-WerDumpFolder
    $folderSummary = if ($folder) { Get-DirectoryFileSummary $folder "phantty*.dmp" } else { "unavailable" }
    $configured = if (Test-PathSafe $regPath) { "yes" } else { "no" }

    return [pscustomobject]@{
        Setup = Format-Value $script:CrashDumpSetup
        Configured = Format-Value $configured
        DumpFolder = Format-Value $folder
        DumpType = Format-Value $dumpType
        DumpCount = Format-Value $dumpCount
        DumpFiles = Format-Value $folderSummary
    }
}

function Invoke-PhanttyStartupProbe {
    param([string]$ExePath, [int]$TimeoutMs = 8000)
    if (-not (Test-PathSafe $ExePath)) {
        $script:StartupProbeResult = "not run (phantty.exe not found)"
        return
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = "--auto-update-check false"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $false
    $psi.EnvironmentVariables["PHANTTY_RENDER_DIAGNOSTICS"] = "1"

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $started = Get-Date
    try {
        [void]$process.Start()
        if ($process.WaitForExit($TimeoutMs)) {
            $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
            $script:StartupProbeResult = "exited within $elapsed ms (exit code $($process.ExitCode))"
        } else {
            $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
            $closed = $false
            try {
                if ($process.MainWindowHandle -ne 0) { $closed = $process.CloseMainWindow() }
            } catch {}
            if ($closed -and $process.WaitForExit(2000)) {
                $script:StartupProbeResult = "survived $elapsed ms, then closed by diagnostic probe"
            } else {
                try { $process.Kill() } catch {}
                $script:StartupProbeResult = "survived $elapsed ms, then killed by diagnostic probe"
            }
        }

        $stdout = ""
        $stderr = ""
        try { $stdout = $process.StandardOutput.ReadToEnd() } catch {}
        try { $stderr = $process.StandardError.ReadToEnd() } catch {}
        $combined = (($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($combined)) {
            $script:StartupProbeOutput = @($combined -split "`r?`n" | Select-Object -First 80 | ForEach-Object { Redact-Text $_ })
        }
    } catch {
        $script:StartupProbeResult = "failed ($($_.Exception.Message))"
        Add-FailedCommand "run startup probe" $_.Exception.Message
    } finally {
        $process.Dispose()
    }
}

function Test-SensitiveConfigKey {
    param([string]$Key, [string]$Line)
    $text = "$Key $Line"
    return $text -match "(?i)(password|token|secret|fingerprint|remote-session-key|authorization|bearer|api-key|private-key|identity-file)"
}

function Redact-RemoteUrl {
    param([string]$Value)
    return Redact-UrlForPublicReport $Value
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
                "- Startup/crash: recent Windows Application Error entries are collected below when available.",
                "- Startup/crash: if WER dumps are enabled, attach dumps only in a private channel because they may contain memory contents."
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
        "(?i)render|dpi|monitor|display|glitch|resize" {
            return @(
                "- Rendering/DPI: monitor count and resolutions are collected in the Rendering section above.",
                "- Rendering/DPI: if render-diagnostic.log is missing or empty, add `phantty-debug-render = true` to your config, restart Phantty, reproduce the issue, then re-run this script.",
                "- Rendering/DPI: attach a screenshot or short screen recording showing the glitch."
            )
        }
        "(?i)cpu|perf|slow|performance|high.cpu" {
            return @(
                "- High CPU: CPU usage sample is in the Rendering section (phantty.exe must be running when the script runs).",
                "- High CPU: note whether CPU stays high continuously or spikes briefly.",
                "- High CPU: check whether a background AI Chat request, remote session, or file preview is active when CPU is high."
            )
        }
        default { return @() }
    }
}

function New-MarkdownReport {
    $phantty = Get-PhanttyInfo
    if ($EnableCrashDumps) { Enable-WerCrashDumpCollection }
    if ($StartupProbe) { Invoke-PhanttyStartupProbe $phantty.ExePathRaw $StartupProbeTimeoutMs }
    $windows = Get-WindowsInfo
    $ssh = Get-SshInfo
    $rendering = Get-RenderingInfo
    $cpuSample = if ($ProblemType -match "(?i)cpu|perf|slow|performance|high.cpu") { Get-CpuSample 3 } else { $null }
    $configLines = Get-ConfigExcerpt $phantty.ConfigPathRaw
    $hints = Get-IssueHints $ProblemType
    $crashEvents = Get-PhanttyCrashEvents $CrashEventDays
    $wer = Get-WerDumpInfo
    $renderLog = Get-RenderDiagnosticLogExcerpt

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("## Phantty Diagnostic Report") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Summary") | Out-Null
    $lines.Add("- Generated at: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz"))") | Out-Null
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
    $lines.Add("- Monitors: $($rendering.Monitors)") | Out-Null
    $lines.Add("- WebView2 runtime: $($rendering.WebView2Runtime)") | Out-Null
    if ($cpuSample) {
        $lines.Add("- phantty.exe CPU sample: $cpuSample") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("### Startup / Crash") | Out-Null
    $lines.Add("- Startup probe: $(Format-Value $script:StartupProbeResult)") | Out-Null
    $lines.Add("- WER dump setup: $($wer.Setup)") | Out-Null
    $lines.Add("- WER local dumps configured: $($wer.Configured)") | Out-Null
    $lines.Add("- WER dump folder: $($wer.DumpFolder)") | Out-Null
    $lines.Add("- WER dump type/count: type=$($wer.DumpType), count=$($wer.DumpCount)") | Out-Null
    $lines.Add("- WER dump files: $($wer.DumpFiles)") | Out-Null
    $lines.Add("- Render diagnostic log: $($renderLog.Summary)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("#### Recent Windows Crash Events") | Out-Null
    foreach ($eventLine in $crashEvents) { $lines.Add($eventLine) | Out-Null }
    $lines.Add("") | Out-Null
    if ($script:StartupProbeOutput.Count -gt 0) {
        $lines.Add("#### Startup Probe Output") | Out-Null
        $lines.Add('```text') | Out-Null
        foreach ($line in $script:StartupProbeOutput) { $lines.Add($line) | Out-Null }
        $lines.Add('```') | Out-Null
        $lines.Add("") | Out-Null
    }
    if ($renderLog.Lines.Count -gt 0) {
        $lines.Add("#### Render Diagnostic Log Excerpt") | Out-Null
        $lines.Add('```text') | Out-Null
        foreach ($line in $renderLog.Lines) { $lines.Add($line) | Out-Null }
        $lines.Add('```') | Out-Null
        $lines.Add("") | Out-Null
    }
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
    $lines.Add('```ini') | Out-Null
    foreach ($line in $configLines) { $lines.Add($line) | Out-Null }
    $lines.Add('```') | Out-Null
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

    $fakeUserPath = Join-Path $env:USERPROFILE "Documents\secret\phantty.exe"
    $redacted = Redact-Text $fakeUserPath
    if ($redacted -match [regex]::Escape($env:USERPROFILE)) { throw "USERPROFILE path was not redacted" }

    $slashPath = ($fakeUserPath -replace '\\', '/')
    $redacted = Redact-Text $slashPath
    if ($redacted -match "C:/Users") { throw "slash-form USERPROFILE path was not redacted" }

    $ansi = Redact-Text "$([char]27)[31m$env:USERNAME$([char]27)[0m"
    if ($ansi -ne "<user>") { throw "ANSI/user prompt text was not sanitized" }

    $secretOutput = Redact-Text "Remote session key: abc123"
    if ($secretOutput -ne "Remote session key: <redacted>") { throw "remote session key output was not redacted" }

    $hints = Get-IssueHints "SSH/SCP"
    if ($hints.Count -lt 1) { throw "SSH/SCP hints missing" }

    $crashHints = Get-IssueHints "startup/crash"
    if ($crashHints.Count -lt 2) { throw "startup/crash hints missing" }

    $renderHints = Get-IssueHints "rendering/DPI"
    if ($renderHints.Count -lt 2) { throw "rendering/DPI hints missing" }

    $cpuHints = Get-IssueHints "high-cpu"
    if ($cpuHints.Count -lt 2) { throw "high-cpu hints missing" }

    "Self-test passed"
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

New-MarkdownReport
