param(
    [string]$ExePath = "",
    [string]$WorkingDirectory = "",
    [string]$OutDir = "",
    [string]$Shell = "cmd",
    [string]$Label = "",
    [int]$WindowX = 80,
    [int]$WindowY = 80,
    [int]$StartWidth = 1100,
    [int]$StartHeight = 720,
    [int]$EndWidth = 1640,
    [int]$EndHeight = 940,
    [int]$Steps = 48,
    [int]$Cycles = 3,
    [int]$StepDelayMs = 8,
    [int]$WarmupMs = 1200,
    [int]$ManualSetupSeconds = 0,
    [int]$CooldownMs = 800,
    [switch]$KeepOpen
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
if ($ExePath.Length -eq 0) {
    $ExePath = Join-Path $repoRoot "zig-out\bin\wispterm.exe"
}
if ($WorkingDirectory.Length -eq 0) {
    $WorkingDirectory = $repoRoot
}
if ($OutDir.Length -eq 0) {
    $OutDir = Join-Path $repoRoot "zig-out\resize-bench"
}
if ($Label.Length -eq 0) {
    $Label = Split-Path -Leaf (Split-Path -Parent $ExePath)
}

if (!(Test-Path -LiteralPath $ExePath)) {
    throw "WispTerm executable not found: $ExePath. Run zig build first."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not ("WispTermResizeBenchNative" -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WispTermResizeBenchNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@
}

[WispTermResizeBenchNative]::SetProcessDPIAware() | Out-Null

function Get-WispTermWindowHandle([System.Diagnostics.Process]$Process) {
    $script:wisptermResizeBenchWindowHandle = [IntPtr]::Zero
    $script:wisptermResizeBenchProcessId = $Process.Id
    $callback = [WispTermResizeBenchNative+EnumWindowsProc]{
        param([IntPtr]$Hwnd, [IntPtr]$LParam)
        if (![WispTermResizeBenchNative]::IsWindowVisible($Hwnd)) {
            return $true
        }

        [uint32]$windowProcessId = 0
        [WispTermResizeBenchNative]::GetWindowThreadProcessId($Hwnd, [ref]$windowProcessId) | Out-Null
        if ($windowProcessId -ne [uint32]$script:wisptermResizeBenchProcessId) {
            return $true
        }

        $className = [System.Text.StringBuilder]::new(256)
        [WispTermResizeBenchNative]::GetClassNameW($Hwnd, $className, $className.Capacity) | Out-Null
        if ($className.ToString() -eq "WispTermWindowClass") {
            $script:wisptermResizeBenchWindowHandle = $Hwnd
            return $false
        }
        return $true
    }

    [WispTermResizeBenchNative]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return $script:wisptermResizeBenchWindowHandle
}

function Invoke-WindowResize([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $flags = 0x0040 -bor 0x0004 # SWP_SHOWWINDOW | SWP_NOZORDER
    if (![WispTermResizeBenchNative]::SetWindowPos($Hwnd, [IntPtr]::Zero, $X, $Y, $Width, $Height, $flags)) {
        throw "SetWindowPos failed for ${Width}x${Height}"
    }
}

function Get-Summary([double[]]$Values) {
    if ($Values.Count -eq 0) {
        return [ordered]@{ count = 0; min = 0; p50 = 0; p95 = 0; max = 0; avg = 0 }
    }
    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count
    $p50Index = [Math]::Min($count - 1, [Math]::Floor(($count - 1) * 0.50))
    $p95Index = [Math]::Min($count - 1, [Math]::Floor(($count - 1) * 0.95))
    $sum = 0.0
    foreach ($value in $sorted) {
        $sum += $value
    }
    return [ordered]@{
        count = $count
        min = [Math]::Round($sorted[0], 3)
        p50 = [Math]::Round($sorted[$p50Index], 3)
        p95 = [Math]::Round($sorted[$p95Index], 3)
        max = [Math]::Round($sorted[$count - 1], 3)
        avg = [Math]::Round($sum / $count, 3)
    }
}

function Get-UiPerfSummaries([string]$LogPath) {
    $groups = @{}
    if (!(Test-Path -LiteralPath $LogPath)) {
        return @()
    }

    Get-Content -LiteralPath $LogPath | ForEach-Object {
        if ($_ -match '^\[ui-perf\]\s+(.+?):\s+(\d+)us$') {
            $label = $Matches[1]
            $valueMs = [double]$Matches[2] / 1000.0
            if (!$groups.ContainsKey($label)) {
                $groups[$label] = [System.Collections.Generic.List[double]]::new()
            }
            $groups[$label].Add($valueMs)
        }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($key in ($groups.Keys | Sort-Object)) {
        $summary = Get-Summary ([double[]]$groups[$key].ToArray())
        $rows.Add([ordered]@{
            label = $key
            count = $summary.count
            min_ms = $summary.min
            p50_ms = $summary.p50
            p95_ms = $summary.p95
            max_ms = $summary.max
            avg_ms = $summary.avg
        })
    }
    return $rows
}

function New-ResizeSequence() {
    $sequence = New-Object System.Collections.Generic.List[object]
    for ($cycle = 0; $cycle -lt $Cycles; $cycle++) {
        for ($i = 0; $i -le $Steps; $i++) {
            $t = if ($Steps -eq 0) { 1.0 } else { $i / [double]$Steps }
            $sequence.Add([ordered]@{
                width = [int][Math]::Round($StartWidth + ($EndWidth - $StartWidth) * $t)
                height = [int][Math]::Round($StartHeight + ($EndHeight - $StartHeight) * $t)
            })
        }
        for ($i = 1; $i -le $Steps; $i++) {
            $t = if ($Steps -eq 0) { 1.0 } else { $i / [double]$Steps }
            $sequence.Add([ordered]@{
                width = [int][Math]::Round($EndWidth + ($StartWidth - $EndWidth) * $t)
                height = [int][Math]::Round($EndHeight + ($StartHeight - $EndHeight) * $t)
            })
        }
    }
    return $sequence
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '_')
$stderrPath = Join-Path $OutDir "resize-benchmark-$safeLabel-$timestamp.stderr.log"
$stdoutPath = Join-Path $OutDir "resize-benchmark-$safeLabel-$timestamp.stdout.log"
$jsonPath = Join-Path $OutDir "resize-benchmark-$safeLabel-$timestamp.json"
$csvPath = Join-Path $OutDir "resize-benchmark-$safeLabel-$timestamp.csv"
Remove-Item -LiteralPath $stderrPath, $stdoutPath -Force -ErrorAction SilentlyContinue

$oldPerf = $env:WISPTERM_UI_PERF
$env:WISPTERM_UI_PERF = "1"
$proc = $null

try {
    $proc = Start-Process -FilePath $ExePath `
        -ArgumentList @("--shell", $Shell) `
        -WorkingDirectory $WorkingDirectory `
        -RedirectStandardError $stderrPath `
        -RedirectStandardOutput $stdoutPath `
        -PassThru

    $deadline = (Get-Date).AddSeconds(12)
    [IntPtr]$wisptermWindow = [IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 150
        $proc.Refresh()
        $wisptermWindow = Get-WispTermWindowHandle $proc
    } while ($wisptermWindow -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)

    if ($wisptermWindow -eq [IntPtr]::Zero) {
        throw "WispTerm window did not appear"
    }

    [WispTermResizeBenchNative]::ShowWindow($wisptermWindow, 5) | Out-Null
    [WispTermResizeBenchNative]::SetForegroundWindow($wisptermWindow) | Out-Null
    Invoke-WindowResize $wisptermWindow $WindowX $WindowY $StartWidth $StartHeight
    Start-Sleep -Milliseconds $WarmupMs
    if ($ManualSetupSeconds -gt 0) {
        Write-Host "Manual setup window: $ManualSetupSeconds seconds. Prepare the UI state to benchmark, then wait."
        Start-Sleep -Seconds $ManualSetupSeconds
    }

    $durations = [System.Collections.Generic.List[double]]::new()
    $sequence = New-ResizeSequence
    $total = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($size in $sequence) {
        $step = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-WindowResize $wisptermWindow $WindowX $WindowY $size.width $size.height
        $step.Stop()
        $durations.Add($step.Elapsed.TotalMilliseconds)
        if ($StepDelayMs -gt 0) {
            Start-Sleep -Milliseconds $StepDelayMs
        }
    }
    $total.Stop()
    Start-Sleep -Milliseconds $CooldownMs

    if (!$KeepOpen) {
        if (!$proc.HasExited) {
            $proc.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 500
        }
        if (!$proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $setWindowSummary = Get-Summary ([double[]]$durations.ToArray())
    $uiPerf = @(Get-UiPerfSummaries $stderrPath)
    $uiPerf | Export-Csv -LiteralPath $csvPath -NoTypeInformation

    $result = [ordered]@{
        label = $Label
        exe = (Resolve-Path -LiteralPath $ExePath).Path
        shell = $Shell
        working_directory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
        steps = $Steps
        cycles = $Cycles
        manual_setup_seconds = $ManualSetupSeconds
        resize_operations = $durations.Count
        total_ms = [Math]::Round($total.Elapsed.TotalMilliseconds, 3)
        set_window_pos_ms = $setWindowSummary
        ui_perf = $uiPerf
        stdout = $stdoutPath
        stderr = $stderrPath
        ui_perf_csv = $csvPath
        result_json = $jsonPath
    }

    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $result | ConvertTo-Json -Depth 5
} finally {
    if ($null -eq $oldPerf) {
        Remove-Item Env:\WISPTERM_UI_PERF -ErrorAction SilentlyContinue
    } else {
        $env:WISPTERM_UI_PERF = $oldPerf
    }

    if (!$KeepOpen -and $null -ne $proc -and !$proc.HasExited) {
        $proc.CloseMainWindow() | Out-Null
        Start-Sleep -Milliseconds 500
        if (!$proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
