param(
    [string]$Shell = "cmd",
    [string]$ExePath = "",
    [string]$OutDir = "",
    [ValidateSet("d3d11", "opengl")]
    [string]$Backend = "d3d11",
    [int]$WindowX = 90,
    [int]$WindowY = 90,
    [int]$WindowWidth = 1240,
    [int]$WindowHeight = 780,
    [switch]$KeepOpen
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ($OutDir.Length -eq 0) {
    $OutDir = Join-Path $repoRoot "zig-out\d3d11-env-smoke\$timestamp"
}

function Get-FirstLine([string]$Text, [string]$Pattern) {
    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($match.Success) {
        return $match.Value
    }
    return ""
}

function Get-Field([string]$Line, [string]$Pattern) {
    $match = [regex]::Match($Line, $Pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

function Convert-HexField([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [Convert]::ToUInt64([string]$Value, 16)
}

function Convert-UIntField([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [UInt64]$Value
}

function Convert-BoolField([object]$Value) {
    if ($null -eq $Value) {
        return $null
    }
    return ([string]$Value) -eq "true"
}

function Read-D3D11Environment([string]$DiagnosticText) {
    $line = Get-FirstLine $DiagnosticText '^.*gpu-backend=d3d11 environment.*$'
    if ($line.Length -eq 0) {
        return [ordered]@{
            available = $false
        }
    }

    return [ordered]@{
        available = $true
        adapter_description = Get-Field $line 'adapter_description="([^"]*)"'
        vendor_id_hex = Get-Field $line 'vendor_id=0x([0-9a-fA-F]+)'
        vendor_id = Convert-HexField (Get-Field $line 'vendor_id=0x([0-9a-fA-F]+)')
        device_id_hex = Get-Field $line 'device_id=0x([0-9a-fA-F]+)'
        device_id = Convert-HexField (Get-Field $line 'device_id=0x([0-9a-fA-F]+)')
        subsys_id_hex = Get-Field $line 'subsys_id=0x([0-9a-fA-F]+)'
        subsys_id = Convert-HexField (Get-Field $line 'subsys_id=0x([0-9a-fA-F]+)')
        revision = Convert-UIntField (Get-Field $line 'revision=([0-9]+)')
        dedicated_video_memory = Convert-UIntField (Get-Field $line 'dedicated_video_memory=([0-9]+)')
        dedicated_system_memory = Convert-UIntField (Get-Field $line 'dedicated_system_memory=([0-9]+)')
        shared_system_memory = Convert-UIntField (Get-Field $line 'shared_system_memory=([0-9]+)')
        adapter_luid = Get-Field $line 'adapter_luid=([0-9a-fA-F]+:[0-9a-fA-F]+)'
        adapter_flags_hex = Get-Field $line 'adapter_flags=0x([0-9a-fA-F]+)'
        adapter_flags = Convert-HexField (Get-Field $line 'adapter_flags=0x([0-9a-fA-F]+)')
        output_count = Convert-UIntField (Get-Field $line 'output_count=([0-9]+)')
        feature_level = Get-Field $line 'feature_level=([0-9_]+|unknown)'
        swap_effect = Get-Field $line 'swap_effect=([A-Za-z0-9_]+)'
        raw = $line
    }
}

function Read-WindowsEnvironment([string]$DiagnosticText) {
    $line = Get-FirstLine $DiagnosticText '^.*windows-environment.*$'
    if ($line.Length -eq 0) {
        return [ordered]@{
            available = $false
        }
    }

    $primaryDpi = Get-Field $line 'primary_dpi=([0-9]+x[0-9]+)'
    $primaryDpiX = $null
    $primaryDpiY = $null
    if ($null -ne $primaryDpi -and $primaryDpi -match '^([0-9]+)x([0-9]+)$') {
        $primaryDpiX = [UInt64]$Matches[1]
        $primaryDpiY = [UInt64]$Matches[2]
    }

    return [ordered]@{
        available = $true
        remote_session = Convert-BoolField (Get-Field $line 'remote_session=(true|false)')
        session_id = Convert-UIntField (Get-Field $line 'session_id=([0-9]+)')
        monitor_count = Convert-UIntField (Get-Field $line 'monitor_count=([0-9]+)')
        mixed_dpi = Convert-BoolField (Get-Field $line 'mixed_dpi=(true|false)')
        primary_dpi = $primaryDpi
        primary_dpi_x = $primaryDpiX
        primary_dpi_y = $primaryDpiY
        system_dpi = Convert-UIntField (Get-Field $line 'system_dpi=([0-9]+)')
        raw = $line
    }
}

function Read-MonitorTopology([string]$DiagnosticText) {
    $items = @()
    $matches = [regex]::Matches($DiagnosticText, '^.*monitor-enum.*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    foreach ($match in $matches) {
        $line = $match.Value
        $items += [ordered]@{
            monitor_rect = Get-Field $line 'rcMonitor=\(([^)]*)\)'
            work_rect = Get-Field $line 'rcWork=\(([^)]*)\)'
            dpi = Get-Field $line 'dpi=([0-9]+x[0-9]+)'
            primary = Convert-BoolField (Get-Field $line 'primary=(true|false)')
            raw = $line
        }
    }
    return @($items)
}

function Copy-SmokeScreenshots([object]$NormalResult, [string]$ScreenshotsDir) {
    New-Item -ItemType Directory -Force -Path $ScreenshotsDir | Out-Null
    $copied = [ordered]@{}
    if ($null -eq $NormalResult.screenshots) {
        return $copied
    }

    foreach ($property in $NormalResult.screenshots.PSObject.Properties) {
        $source = [string]$property.Value
        if ($source.Length -gt 0 -and (Test-Path -LiteralPath $source)) {
            $dest = Join-Path $ScreenshotsDir (Split-Path -Leaf $source)
            Copy-Item -LiteralPath $source -Destination $dest -Force
            $copied[$property.Name] = $dest
        } else {
            $copied[$property.Name] = $source
        }
    }
    return $copied
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$normalOutDir = Join-Path $OutDir "normal-session"
$screenshotsDir = Join-Path $OutDir "screenshots"
$normalScript = Join-Path $scriptDir "test-d3d11-normal-session.ps1"

$normalArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $normalScript,
    "-Shell", $Shell,
    "-OutDir", $normalOutDir,
    "-Backend", $Backend,
    "-WindowX", $WindowX,
    "-WindowY", $WindowY,
    "-WindowWidth", $WindowWidth,
    "-WindowHeight", $WindowHeight
)
if ($ExePath.Length -gt 0) {
    $normalArgs += @("-ExePath", $ExePath)
}
if ($KeepOpen) {
    $normalArgs += "-KeepOpen"
}

& powershell @normalArgs
$normalSessionExitCode = $LASTEXITCODE

$normalJsonPath = Get-ChildItem -LiteralPath $normalOutDir -Filter "*-normal-session-*.json" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if ($null -eq $normalJsonPath -or !(Test-Path -LiteralPath $normalJsonPath)) {
    throw "normal-session result JSON not found under $normalOutDir"
}

$normalResult = Get-Content -LiteralPath $normalJsonPath -Raw | ConvertFrom-Json
$diagnosticPath = [string]$normalResult.diagnostic_log
$diagnosticText = if (Test-Path -LiteralPath $diagnosticPath) {
    Get-Content -LiteralPath $diagnosticPath -Raw
} else {
    ""
}

$copiedScreenshots = Copy-SmokeScreenshots $normalResult $screenshotsDir
$gitBranch = (& git -C $repoRoot branch --show-current).Trim()
$gitCommit = (& git -C $repoRoot rev-parse HEAD).Trim()

$environment = [ordered]@{
    schema = "wispterm-d3d11-environment-smoke/v1"
    generated_at = (Get-Date).ToString("o")
    backend = $Backend
    pass = [bool]$normalResult.pass
    repo = [ordered]@{
        branch = $gitBranch
        commit = $gitCommit
    }
    artifacts = [ordered]@{
        root = $OutDir
        environment_json = (Join-Path $OutDir "environment.json")
        normal_session_json = $normalJsonPath
        diagnostic_log = $diagnosticPath
        screenshots = $copiedScreenshots
    }
    smoke = [ordered]@{
        normal_session_exit_code = $normalSessionExitCode
        visible_session = [bool]$normalResult.pass
        window = $normalResult.window
        d3d11_present = [bool]$normalResult.diagnostics.d3d11_present
        d3d11_environment = [bool]$normalResult.diagnostics.d3d11_environment
        windows_environment = [bool]$normalResult.diagnostics.windows_environment
        d3d11_policy_healthy = [bool]$normalResult.diagnostics.d3d11_policy_healthy
        d3d11_resize_events = $normalResult.diagnostics.d3d11_resize_events
        failure_lines = [bool]$normalResult.diagnostics.failure_lines
    }
    environment = [ordered]@{
        d3d11 = Read-D3D11Environment $diagnosticText
        windows = Read-WindowsEnvironment $diagnosticText
        monitors = Read-MonitorTopology $diagnosticText
    }
    policy = [ordered]@{
        automatic_fallback = $false
        environment_blocking = $false
        default_unchanged = $true
        note = "collector only; no environment classification or fallback decision is applied"
    }
}

$environmentJsonPath = Join-Path $OutDir "environment.json"
$environment | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $environmentJsonPath -Encoding UTF8

$summary = [ordered]@{
    pass = [bool]$normalResult.pass
    backend = $Backend
    environment_json = $environmentJsonPath
    normal_session_json = $normalJsonPath
    diagnostic_log = $diagnosticPath
    screenshots = $screenshotsDir
    normal_session_exit_code = $normalSessionExitCode
    d3d11_environment = [bool]$normalResult.diagnostics.d3d11_environment
    windows_environment = [bool]$normalResult.diagnostics.windows_environment
}
$summary | ConvertTo-Json -Depth 5

if ($normalSessionExitCode -ne 0 -or ![bool]$normalResult.pass) {
    throw "normal-session smoke failed; environment evidence was written to $environmentJsonPath"
}
