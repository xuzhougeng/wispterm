param(
    [string]$Shell = "cmd",
    [string]$ExePath = "",
    [string]$WorkingDirectory = "",
    [string]$OutDir = "",
    [int]$WindowX = 90,
    [int]$WindowY = 90,
    [int]$WindowWidth = 1240,
    [int]$WindowHeight = 780,
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
    $OutDir = Join-Path $repoRoot "zig-out\d3d11-normal-session-smoke"
}

if (!(Test-Path -LiteralPath $ExePath)) {
    throw "WispTerm executable not found: $ExePath. Run zig build -Dgpu-backend=d3d11 first."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WispTermD3D11SmokeAutomation {
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
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@

[WispTermD3D11SmokeAutomation]::SetProcessDPIAware() | Out-Null

function Get-WindowRectValue([IntPtr]$Hwnd) {
    [WispTermD3D11SmokeAutomation+RECT]$rect = New-Object WispTermD3D11SmokeAutomation+RECT
    [WispTermD3D11SmokeAutomation]::GetWindowRect($Hwnd, [ref]$rect) | Out-Null
    return $rect
}

function Get-WispTermWindowHandle([System.Diagnostics.Process]$Process) {
    $script:wisptermWindowHandle = [IntPtr]::Zero
    $script:wisptermProcessId = $Process.Id
    $callback = [WispTermD3D11SmokeAutomation+EnumWindowsProc]{
        param([IntPtr]$Hwnd, [IntPtr]$LParam)
        if (![WispTermD3D11SmokeAutomation]::IsWindowVisible($Hwnd)) {
            return $true
        }

        [uint32]$windowProcessId = 0
        [WispTermD3D11SmokeAutomation]::GetWindowThreadProcessId($Hwnd, [ref]$windowProcessId) | Out-Null
        if ($windowProcessId -ne [uint32]$script:wisptermProcessId) {
            return $true
        }

        $className = [System.Text.StringBuilder]::new(256)
        [WispTermD3D11SmokeAutomation]::GetClassNameW($Hwnd, $className, $className.Capacity) | Out-Null
        if ($className.ToString() -eq "WispTermWindowClass") {
            $script:wisptermWindowHandle = $Hwnd
            return $false
        }
        return $true
    }

    [WispTermD3D11SmokeAutomation]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return $script:wisptermWindowHandle
}

function Capture-Window([IntPtr]$Hwnd, [string]$Path) {
    $rect = Get-WindowRectValue $Hwnd
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        throw "Invalid window bounds: $width x $height"
    }

    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, [System.Drawing.Size]::new($width, $height))
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    return @{ Width = $width; Height = $height; Left = $rect.Left; Top = $rect.Top }
}

function Analyze-Image([string]$Path) {
    $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $samples = 0
        $nonDark = 0
        $bright = 0
        $saturated = 0
        for ($y = 0; $y -lt $bitmap.Height; $y += 4) {
            for ($x = 0; $x -lt $bitmap.Width; $x += 4) {
                $color = $bitmap.GetPixel($x, $y)
                $max = [Math]::Max($color.R, [Math]::Max($color.G, $color.B))
                $min = [Math]::Min($color.R, [Math]::Min($color.G, $color.B))
                if ($max -gt 38) { $nonDark++ }
                if ($color.R -gt 145 -and $color.G -gt 145 -and $color.B -gt 145) { $bright++ }
                if (($max - $min) -gt 70 -and $max -gt 110) { $saturated++ }
                $samples++
            }
        }
        return @{
            Samples = $samples
            NonDark = $nonDark
            Bright = $bright
            Saturated = $saturated
            Pass = ($nonDark -gt 700 -and ($bright + $saturated) -gt 80)
        }
    } finally {
        $bitmap.Dispose()
    }
}

function Compare-Images([string]$BeforePath, [string]$AfterPath) {
    $before = [System.Drawing.Bitmap]::FromFile($BeforePath)
    $after = [System.Drawing.Bitmap]::FromFile($AfterPath)
    try {
        $width = [Math]::Min($before.Width, $after.Width)
        $height = [Math]::Min($before.Height, $after.Height)
        $samples = 0
        $changed = 0

        for ($y = 0; $y -lt $height; $y += 4) {
            for ($x = 0; $x -lt $width; $x += 4) {
                $a = $after.GetPixel($x, $y)
                $b = $before.GetPixel($x, $y)
                $delta = [Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B)
                if ($delta -gt 55) {
                    $changed++
                }
                $samples++
            }
        }

        $ratio = 0.0
        if ($samples -gt 0) {
            $ratio = $changed / $samples
        }
        return @{
            Samples = $samples
            Changed = $changed
            ChangedRatio = $ratio
            Pass = ($changed -gt 700 -and $ratio -gt 0.012)
        }
    } finally {
        $before.Dispose()
        $after.Dispose()
    }
}

function Click-WindowCenter([IntPtr]$Hwnd) {
    $rect = Get-WindowRectValue $Hwnd
    $x = [int](($rect.Left + $rect.Right) / 2)
    $y = [int](($rect.Top + $rect.Bottom) / 2)
    [WispTermD3D11SmokeAutomation]::SetCursorPos($x, $y) | Out-Null
    [WispTermD3D11SmokeAutomation]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [WispTermD3D11SmokeAutomation]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Send-KeyChord([byte[]]$Keys) {
    $keyUp = 0x0002
    foreach ($key in $Keys) {
        [WispTermD3D11SmokeAutomation]::keybd_event($key, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 55
    }
    [Array]::Reverse($Keys)
    foreach ($key in $Keys) {
        [WispTermD3D11SmokeAutomation]::keybd_event($key, 0, $keyUp, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 35
    }
}

function Send-CtrlShiftB() {
    Send-KeyChord ([byte[]](0x11, 0x10, 0x42))
}

function Send-CtrlShiftP() {
    Send-KeyChord ([byte[]](0x11, 0x10, 0x50))
}

function Send-CtrlShiftAltE() {
    Send-KeyChord ([byte[]](0x11, 0x10, 0x12, 0x45))
}

function Send-Escape() {
    Send-KeyChord ([byte[]](0x1B))
}

function Wait-ForDiagnosticText([string]$Path, [string]$Pattern, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $Path) {
            $text = Get-Content -LiteralPath $Path -Raw
            if ($text -match $Pattern) {
                return $text
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw
    }
    return ""
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$configPath = Join-Path $OutDir "d3d11-smoke-$timestamp.conf"
$initialShot = Join-Path $OutDir "d3d11-initial-$timestamp.png"
$sidebarShot = Join-Path $OutDir "d3d11-sidebar-$timestamp.png"
$explorerShot = Join-Path $OutDir "d3d11-file-explorer-$timestamp.png"
$paletteShot = Join-Path $OutDir "d3d11-command-palette-$timestamp.png"
$metricsPath = Join-Path $OutDir "d3d11-normal-session-$timestamp.json"
$appDataDir = Join-Path $OutDir "appdata"
$diagnosticPath = Join-Path $appDataDir "wispterm\render-diagnostic.log"

New-Item -ItemType Directory -Force -Path $appDataDir | Out-Null
@"
shell = $Shell
wispterm-debug-render = true
restore-tabs-on-startup = false
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$oldAppData = $env:APPDATA
$oldRenderDiagnostics = $env:WISPTERM_RENDER_DIAGNOSTICS
$oldUiSmoke = $env:WISPTERM_D3D11_UI_SMOKE
$oldOffscreenSmoke = $env:WISPTERM_D3D11_OFFSCREEN_SMOKE

$env:APPDATA = $appDataDir
$env:WISPTERM_RENDER_DIAGNOSTICS = "1"
$env:WISPTERM_D3D11_UI_SMOKE = "1"
$env:WISPTERM_D3D11_OFFSCREEN_SMOKE = "1"

$proc = $null
try {
    $proc = Start-Process -FilePath $ExePath -ArgumentList @("--config", $configPath, "--shell", $Shell) -WorkingDirectory $WorkingDirectory -PassThru

    $deadline = (Get-Date).AddSeconds(15)
    [IntPtr]$wisptermWindow = [IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 250
        $proc.Refresh()
        if ($proc.HasExited) {
            throw "WispTerm exited before a window appeared. ExitCode=$($proc.ExitCode)"
        }
        $wisptermWindow = Get-WispTermWindowHandle $proc
    } while ($wisptermWindow -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)

    if ($wisptermWindow -eq [IntPtr]::Zero) {
        throw "WispTerm window did not appear"
    }

    [WispTermD3D11SmokeAutomation]::ShowWindow($wisptermWindow, 5) | Out-Null
    [WispTermD3D11SmokeAutomation]::SetWindowPos($wisptermWindow, [IntPtr]::Zero, $WindowX, $WindowY, $WindowWidth, $WindowHeight, 0x0040) | Out-Null
    [WispTermD3D11SmokeAutomation]::SetForegroundWindow($wisptermWindow) | Out-Null
    Start-Sleep -Milliseconds 1200
    Click-WindowCenter $wisptermWindow
    Start-Sleep -Milliseconds 900
    Send-Escape
    Start-Sleep -Milliseconds 900

    $initialSize = Capture-Window $wisptermWindow $initialShot
    $initialMetrics = Analyze-Image $initialShot

    Send-CtrlShiftB
    Start-Sleep -Milliseconds 1000
    Capture-Window $wisptermWindow $sidebarShot | Out-Null
    $sidebarDelta = Compare-Images $initialShot $sidebarShot

    Send-CtrlShiftAltE
    Start-Sleep -Milliseconds 1400
    Capture-Window $wisptermWindow $explorerShot | Out-Null
    $explorerDelta = Compare-Images $sidebarShot $explorerShot

    Send-CtrlShiftP
    Start-Sleep -Milliseconds 1000
    Capture-Window $wisptermWindow $paletteShot | Out-Null
    $paletteDelta = Compare-Images $explorerShot $paletteShot

    $diagText = Wait-ForDiagnosticText $diagnosticPath "d3d11-ui-smoke probe .* ok=true" 12
    $hasD3D11Present = $diagText -match "gpu-backend=d3d11 present=dxgi"
    $hasUiProbe = $diagText -match "d3d11-ui-smoke probe .* ok=true"
    $hasOffscreen = $diagText -match "d3d11-offscreen-smoke round-trip active"
    $hasFailures = $diagText -match "present failed|shader compile failed|backbuffer probe failed|resize sync failed"

    $pass = [bool](
        $initialMetrics.Pass -and
        $sidebarDelta.Pass -and
        $explorerDelta.Pass -and
        $paletteDelta.Pass -and
        $hasD3D11Present -and
        $hasUiProbe -and
        $hasOffscreen -and
        !$hasFailures
    )

    $result = [ordered]@{
        pass = $pass
        shell = $Shell
        window = "$($initialSize.Width)x$($initialSize.Height)"
        exe = $ExePath
        config = $configPath
        diagnostic_log = $diagnosticPath
        screenshots = [ordered]@{
            initial = $initialShot
            sidebar = $sidebarShot
            file_explorer = $explorerShot
            command_palette = $paletteShot
        }
        initial = [ordered]@{
            samples = $initialMetrics.Samples
            non_dark = $initialMetrics.NonDark
            bright = $initialMetrics.Bright
            saturated = $initialMetrics.Saturated
            pass = [bool]$initialMetrics.Pass
        }
        sidebar_delta = [ordered]@{
            changed = $sidebarDelta.Changed
            samples = $sidebarDelta.Samples
            changed_ratio = [Math]::Round($sidebarDelta.ChangedRatio, 5)
            pass = [bool]$sidebarDelta.Pass
        }
        file_explorer_delta = [ordered]@{
            changed = $explorerDelta.Changed
            samples = $explorerDelta.Samples
            changed_ratio = [Math]::Round($explorerDelta.ChangedRatio, 5)
            pass = [bool]$explorerDelta.Pass
        }
        command_palette_delta = [ordered]@{
            changed = $paletteDelta.Changed
            samples = $paletteDelta.Samples
            changed_ratio = [Math]::Round($paletteDelta.ChangedRatio, 5)
            pass = [bool]$paletteDelta.Pass
        }
        diagnostics = [ordered]@{
            d3d11_present = [bool]$hasD3D11Present
            ui_probe_ok = [bool]$hasUiProbe
            offscreen_round_trip = [bool]$hasOffscreen
            failure_lines = [bool]$hasFailures
        }
    }

    $json = $result | ConvertTo-Json -Depth 5
    $json | Set-Content -LiteralPath $metricsPath -Encoding UTF8
    $json

    if (!$pass) {
        throw "D3D11 normal-session smoke failed. Inspect metrics=$metricsPath and diagnostic_log=$diagnosticPath"
    }
} finally {
    if (!$KeepOpen -and $proc -ne $null) {
        if (!$proc.HasExited) {
            $proc.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 500
        }
        if (!$proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $env:APPDATA = $oldAppData
    $env:WISPTERM_RENDER_DIAGNOSTICS = $oldRenderDiagnostics
    $env:WISPTERM_D3D11_UI_SMOKE = $oldUiSmoke
    $env:WISPTERM_D3D11_OFFSCREEN_SMOKE = $oldOffscreenSmoke
}
