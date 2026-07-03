param(
    [string]$Shell = "cmd",
    [string]$ExePath = "",
    [string]$WorkingDirectory = "",
    [string]$OutDir = "",
    [int]$WindowX = 90,
    [int]$WindowY = 90,
    [int]$WindowWidth = 1240,
    [int]$WindowHeight = 780,
    [switch]$RecreateSmoke,
    [switch]$RapidResizeSmoke,
    [switch]$FallbackMarkerSmoke,
    [switch]$KeepOpen
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$workingDirectoryProvided = $WorkingDirectory.Length -ne 0
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
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, UIntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@

[WispTermD3D11SmokeAutomation]::SetProcessDPIAware() | Out-Null

function New-SmokeBackgroundImage([string]$Path) {
    $bitmap = New-Object System.Drawing.Bitmap 320, 200
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(245, 54, 181))
        $graphics.FillRectangle([System.Drawing.Brushes]::DeepSkyBlue, 160, 0, 160, 100)
        $graphics.FillRectangle([System.Drawing.Brushes]::Gold, 0, 100, 160, 100)
        $graphics.FillRectangle([System.Drawing.Brushes]::LimeGreen, 160, 100, 160, 100)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 18
        try {
            $graphics.DrawLine($pen, 0, 0, 320, 200)
            $graphics.DrawLine($pen, 320, 0, 0, 200)
        } finally {
            $pen.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function New-SmokePreviewImage([string]$Path) {
    $bitmap = New-Object System.Drawing.Bitmap 420, 260
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(30, 40, 80))
        $graphics.FillRectangle([System.Drawing.Brushes]::OrangeRed, 28, 28, 150, 90)
        $graphics.FillRectangle([System.Drawing.Brushes]::MediumSpringGreen, 210, 34, 170, 110)
        $graphics.FillEllipse([System.Drawing.Brushes]::DeepSkyBlue, 60, 130, 150, 90)
        $graphics.FillEllipse([System.Drawing.Brushes]::Magenta, 235, 145, 110, 80)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 12
        try {
            $graphics.DrawRectangle($pen, 14, 14, 392, 232)
        } finally {
            $pen.Dispose()
        }
    } finally {
        $graphics.Dispose()
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
    }
}

function New-SmokePreviewFixtures([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $markdownPath = Join-Path $Dir "a-preview.md"
    $imagePath = Join-Path $Dir "b-image.png"
    @'
# D3D11 Preview Smoke

This markdown preview is rendered inside a normal WispTerm D3D11 session.

## Evidence

- Markdown heading
- List item
- `inline code`

````zig
const backend = "d3d11";
````
'@ | Set-Content -LiteralPath $markdownPath -Encoding UTF8
    New-SmokePreviewImage $imagePath
    return @{
        Dir = $Dir
        Markdown = $markdownPath
        Image = $imagePath
    }
}

function ConvertTo-HexField([string]$Value) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $builder = New-Object System.Text.StringBuilder
    foreach ($byte in $bytes) {
        [void]$builder.AppendFormat("{0:X2}", $byte)
    }
    return $builder.ToString()
}

function New-SmokeAiProfile([string]$AppDataDir) {
    $wispDir = Join-Path $AppDataDir "wispterm"
    New-Item -ItemType Directory -Force -Path $wispDir | Out-Null
    $profilePath = Join-Path $wispDir "ai_profiles"
    $fields = @(
        "D3D11 Smoke",
        "https://api.invalid.local",
        "d3d11-smoke-key",
        "d3d11-smoke-model",
        "D3D11 smoke profile",
        "disabled",
        "low",
        "false",
        "true",
        "chat_completions",
        "1024",
        "off"
    )
    $line = ($fields | ForEach-Object { ConvertTo-HexField $_ }) -join "`t"
    @(
        "# WispTerm AI Chat profiles. Fields are hex encoded: name, base_url, api_key, model, system_prompt, thinking, reasoning_effort, stream, agent, protocol, max_tokens, vision.",
        $line
    ) | Set-Content -LiteralPath $profilePath -Encoding UTF8
    return $profilePath
}

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

function Invoke-RapidResizeSmoke([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$BaseWidth, [int]$BaseHeight, [string]$ShotPath) {
    $sizes = @(
        @{ Width = [Math]::Max(960, $BaseWidth - 220); Height = [Math]::Max(620, $BaseHeight - 130) },
        @{ Width = $BaseWidth + 160; Height = $BaseHeight + 95 },
        @{ Width = [Math]::Max(1040, $BaseWidth - 120); Height = $BaseHeight + 20 },
        @{ Width = $BaseWidth; Height = $BaseHeight }
    )

    foreach ($size in $sizes) {
        [WispTermD3D11SmokeAutomation]::SetWindowPos($Hwnd, [IntPtr]::Zero, $X, $Y, $size.Width, $size.Height, 0x0040) | Out-Null
        Start-Sleep -Milliseconds 150
    }

    [WispTermD3D11SmokeAutomation]::SetForegroundWindow($Hwnd) | Out-Null
    Start-Sleep -Milliseconds 950
    $finalSize = Capture-Window $Hwnd $ShotPath
    $metrics = Analyze-Image $ShotPath
    $widthDelta = [Math]::Abs($finalSize.Width - $BaseWidth)
    $heightDelta = [Math]::Abs($finalSize.Height - $BaseHeight)

    return @{
        Enabled = $true
        Pass = [bool]($metrics.Pass -and $widthDelta -le 12 -and $heightDelta -le 12)
        Width = $finalSize.Width
        Height = $finalSize.Height
        WidthDelta = $widthDelta
        HeightDelta = $heightDelta
        NonDark = $metrics.NonDark
        Bright = $metrics.Bright
        Saturated = $metrics.Saturated
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

function Analyze-Region([string]$Path, [int]$Left, [int]$Top, [int]$Width, [int]$Height, [int]$Step = 2) {
    $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $right = [Math]::Min($bitmap.Width, $Left + $Width)
        $bottom = [Math]::Min($bitmap.Height, $Top + $Height)
        $samples = 0
        $sumR = 0
        $sumG = 0
        $sumB = 0
        $bright = 0
        $saturated = 0

        for ($y = [Math]::Max(0, $Top); $y -lt $bottom; $y += $Step) {
            for ($x = [Math]::Max(0, $Left); $x -lt $right; $x += $Step) {
                $color = $bitmap.GetPixel($x, $y)
                $max = [Math]::Max($color.R, [Math]::Max($color.G, $color.B))
                $min = [Math]::Min($color.R, [Math]::Min($color.G, $color.B))
                $sumR += $color.R
                $sumG += $color.G
                $sumB += $color.B
                if ($color.R -gt 120 -and $color.G -gt 120 -and $color.B -gt 120) { $bright++ }
                if (($max - $min) -gt 45 -and $max -gt 90) { $saturated++ }
                $samples++
            }
        }

        if ($samples -le 0) {
            return @{ Samples = 0; AvgR = 0.0; AvgG = 0.0; AvgB = 0.0; Luma = 0.0; Bright = 0; Saturated = 0 }
        }

        $avgR = $sumR / $samples
        $avgG = $sumG / $samples
        $avgB = $sumB / $samples
        return @{
            Samples = $samples
            AvgR = $avgR
            AvgG = $avgG
            AvgB = $avgB
            Luma = ($avgR * 0.2126 + $avgG * 0.7152 + $avgB * 0.0722)
            Bright = $bright
            Saturated = $saturated
        }
    } finally {
        $bitmap.Dispose()
    }
}

function Compare-ImageRegion([string]$BeforePath, [string]$AfterPath, [int]$Left, [int]$Top, [int]$Width, [int]$Height, [int]$Step = 2) {
    $before = [System.Drawing.Bitmap]::FromFile($BeforePath)
    $after = [System.Drawing.Bitmap]::FromFile($AfterPath)
    try {
        $right = [Math]::Min([Math]::Min($before.Width, $after.Width), $Left + $Width)
        $bottom = [Math]::Min([Math]::Min($before.Height, $after.Height), $Top + $Height)
        $samples = 0
        $changed = 0

        for ($y = [Math]::Max(0, $Top); $y -lt $bottom; $y += $Step) {
            for ($x = [Math]::Max(0, $Left); $x -lt $right; $x += $Step) {
                $a = $after.GetPixel($x, $y)
                $b = $before.GetPixel($x, $y)
                $delta = [Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B)
                if ($delta -gt 36) {
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
        }
    } finally {
        $before.Dispose()
        $after.Dispose()
    }
}

function Analyze-TabChrome([string]$Active1Path, [string]$Active2Path, [string]$HoverPath) {
    # These are screenshot-space regions for the default visible Windows smoke
    # window. They match the rendered sidebar constants: titlebar, sidebar
    # header, row height, tab text slot, plus icon, and close affordance slot.
    $row1 = @{ Left = 0; Top = 108; Width = 220; Height = 55 }
    $row2 = @{ Left = 0; Top = 163; Width = 220; Height = 55 }
    $row1Text = @{ Left = 46; Top = 118; Width = 118; Height = 30 }
    $row2Text = @{ Left = 46; Top = 173; Width = 118; Height = 30 }
    $plus = @{ Left = 176; Top = 58; Width = 32; Height = 34 }
    $close = @{ Left = 182; Top = 176; Width = 32; Height = 32 }

    $active1Row1 = Analyze-Region $Active1Path $row1.Left $row1.Top $row1.Width $row1.Height 2
    $active1Row2 = Analyze-Region $Active1Path $row2.Left $row2.Top $row2.Width $row2.Height 2
    $active2Row1 = Analyze-Region $Active2Path $row1.Left $row1.Top $row1.Width $row1.Height 2
    $active2Row2 = Analyze-Region $Active2Path $row2.Left $row2.Top $row2.Width $row2.Height 2
    $text1 = Analyze-Region $Active1Path $row1Text.Left $row1Text.Top $row1Text.Width $row1Text.Height 1
    $text2 = Analyze-Region $Active1Path $row2Text.Left $row2Text.Top $row2Text.Width $row2Text.Height 1
    $plusRegion = Analyze-Region $Active1Path $plus.Left $plus.Top $plus.Width $plus.Height 1
    $closeBefore = Analyze-Region $Active2Path $close.Left $close.Top $close.Width $close.Height 1
    $closeAfter = Analyze-Region $HoverPath $close.Left $close.Top $close.Width $close.Height 1
    $closeDelta = Compare-ImageRegion $Active2Path $HoverPath $close.Left $close.Top $close.Width $close.Height 1
    $row2HoverDelta = Compare-ImageRegion $Active2Path $HoverPath $row2.Left $row2.Top $row2.Width $row2.Height 2

    $row1ActiveAdvantage = $active1Row1.Luma - $active1Row2.Luma
    $row2ActiveAdvantage = $active2Row2.Luma - $active2Row1.Luma
    $rowSwapDelta = [Math]::Abs($active2Row1.Luma - $active1Row1.Luma) + [Math]::Abs($active2Row2.Luma - $active1Row2.Luma)
    $textVisible = ($text1.Bright -gt 16 -and $text2.Bright -gt 16)
    $plusVisible = ($plusRegion.Bright -gt 3 -or $plusRegion.Saturated -gt 3)
    $closeAffordance = ($closeAfter.Bright -gt $closeBefore.Bright + 4 -or $closeDelta.Changed -gt 18 -or $row2HoverDelta.Changed -gt 80)
    $activeStateSwap = ($row1ActiveAdvantage -gt 4.0 -and $row2ActiveAdvantage -gt 4.0 -and $rowSwapDelta -gt 10.0)

    return @{
        Pass = [bool]($activeStateSwap -and $textVisible -and $plusVisible -and $closeAffordance)
        ActiveStateSwap = [bool]$activeStateSwap
        TextVisible = [bool]$textVisible
        PlusIconVisible = [bool]$plusVisible
        CloseHoverAffordance = [bool]$closeAffordance
        Row1ActiveAdvantage = $row1ActiveAdvantage
        Row2ActiveAdvantage = $row2ActiveAdvantage
        RowSwapDelta = $rowSwapDelta
        Row1ActiveLuma = $active1Row1.Luma
        Row1InactiveLuma = $active2Row1.Luma
        Row2InactiveLuma = $active1Row2.Luma
        Row2ActiveLuma = $active2Row2.Luma
        Row1TextBright = $text1.Bright
        Row2TextBright = $text2.Bright
        PlusBright = $plusRegion.Bright
        PlusSaturated = $plusRegion.Saturated
        CloseBrightBefore = $closeBefore.Bright
        CloseBrightAfter = $closeAfter.Bright
        CloseChanged = $closeDelta.Changed
        CloseChangedRatio = $closeDelta.ChangedRatio
        Row2HoverChanged = $row2HoverDelta.Changed
        Row2HoverChangedRatio = $row2HoverDelta.ChangedRatio
    }
}

function Analyze-PageSurface(
    [string]$BeforePath,
    [string]$AfterPath,
    [int]$Left,
    [int]$Top,
    [int]$Width,
    [int]$Height,
    [int]$MinChanged,
    [double]$MinChangedRatio,
    [int]$MinBright
) {
    $region = Analyze-Region $AfterPath $Left $Top $Width $Height 2
    $delta = Compare-ImageRegion $BeforePath $AfterPath $Left $Top $Width $Height 2
    $pass = ($delta.Changed -gt $MinChanged -and $delta.ChangedRatio -gt $MinChangedRatio -and $region.Bright -gt $MinBright)

    return @{
        Pass = [bool]$pass
        Changed = $delta.Changed
        ChangedRatio = $delta.ChangedRatio
        Bright = $region.Bright
        Saturated = $region.Saturated
        Luma = $region.Luma
        Samples = $region.Samples
    }
}

function Analyze-BackgroundImageSurface([string]$Path) {
    # Sample the empty terminal field, away from titlebar chrome, prompt text,
    # and the bottom-left D3D11 UI probe. With the generated bright wallpaper
    # and low theme tint, this region should be visibly colored.
    $region = Analyze-Region $Path 300 130 820 440 4
    $pass = ($region.Saturated -gt 900 -and $region.Luma -gt 55.0)

    return @{
        Pass = [bool]$pass
        Samples = $region.Samples
        Bright = $region.Bright
        Saturated = $region.Saturated
        Luma = $region.Luma
        AvgR = $region.AvgR
        AvgG = $region.AvgG
        AvgB = $region.AvgB
    }
}

function Analyze-MarkdownPreviewSurface([string]$BeforePath, [string]$AfterPath) {
    $delta = Compare-ImageRegion $BeforePath $AfterPath 245 54 970 690 4
    $header = Analyze-Region $AfterPath 250 54 960 80 2
    $body = Analyze-Region $AfterPath 270 120 910 560 3
    $pass = ($delta.Changed -gt 1200 -and $delta.ChangedRatio -gt 0.02 -and ($header.Bright + $body.Bright) -gt 280)

    return @{
        Pass = [bool]$pass
        Changed = $delta.Changed
        ChangedRatio = $delta.ChangedRatio
        HeaderBright = $header.Bright
        BodyBright = $body.Bright
        BodyLuma = $body.Luma
        Samples = $body.Samples
    }
}

function Analyze-ImagePreviewSurface([string]$BeforePath, [string]$AfterPath) {
    $delta = Compare-ImageRegion $BeforePath $AfterPath 245 385 970 360 3
    $region = Analyze-Region $AfterPath 285 420 860 280 3
    $pass = ($delta.Changed -gt 1800 -and $delta.ChangedRatio -gt 0.035 -and $region.Saturated -gt 900)

    return @{
        Pass = [bool]$pass
        Changed = $delta.Changed
        ChangedRatio = $delta.ChangedRatio
        Bright = $region.Bright
        Saturated = $region.Saturated
        Luma = $region.Luma
        Samples = $region.Samples
    }
}

function Analyze-StartupShortcutsOverlay([string]$BeforePath, [string]$AfterPath) {
    $delta = Compare-ImageRegion $BeforePath $AfterPath 220 70 800 650 3
    $heading = Analyze-Region $AfterPath 330 76 580 94 2
    $body = Analyze-Region $AfterPath 255 145 730 505 3
    $pass = ($delta.Changed -gt 2500 -and $delta.ChangedRatio -gt 0.028 -and ($heading.Bright + $body.Bright) -gt 520)

    return @{
        Pass = [bool]$pass
        Changed = $delta.Changed
        ChangedRatio = $delta.ChangedRatio
        HeadingBright = $heading.Bright
        BodyBright = $body.Bright
        BodyLuma = $body.Luma
        Samples = $body.Samples
    }
}

function Analyze-AssistantPanelSurface([string]$BeforePath, [string]$AfterPath) {
    $delta = Compare-ImageRegion $BeforePath $AfterPath 840 52 390 692 2
    $header = Analyze-Region $AfterPath 850 58 365 70 2
    $composer = Analyze-Region $AfterPath 858 625 345 105 2
    $pass = ($delta.Changed -gt 4200 -and $delta.ChangedRatio -gt 0.055 -and ($header.Bright + $composer.Bright) -gt 120)

    return @{
        Pass = [bool]$pass
        Changed = $delta.Changed
        ChangedRatio = $delta.ChangedRatio
        HeaderBright = $header.Bright
        ComposerBright = $composer.Bright
        ComposerLuma = $composer.Luma
        Samples = $composer.Samples
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

function Click-WindowPoint([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    Move-MouseWindow $Hwnd $X $Y
    Start-Sleep -Milliseconds 80
    [WispTermD3D11SmokeAutomation]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [WispTermD3D11SmokeAutomation]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function DoubleClick-WindowPoint([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    Click-WindowPoint $Hwnd $X $Y
    Start-Sleep -Milliseconds 130
    Click-WindowPoint $Hwnd $X $Y
}

function Move-MouseWindow([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    $rect = Get-WindowRectValue $Hwnd
    [WispTermD3D11SmokeAutomation]::SetCursorPos($rect.Left + $X, $rect.Top + $Y) | Out-Null
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

function Send-CtrlShiftA() {
    Send-KeyChord ([byte[]](0x11, 0x10, 0x41))
}

function Send-CtrlShiftAltE() {
    Send-KeyChord ([byte[]](0x11, 0x10, 0x12, 0x45))
}

function Send-Enter() {
    Send-KeyChord ([byte[]](0x0D))
}

function Send-AltDigit([byte]$DigitKey) {
    Send-KeyChord ([byte[]](0x12, $DigitKey))
}

function Send-Escape() {
    Send-KeyChord ([byte[]](0x1B))
}

function Send-WindowText([IntPtr]$Hwnd, [string]$Text) {
    foreach ($ch in $Text.ToCharArray()) {
        [WispTermD3D11SmokeAutomation]::SendMessageW($Hwnd, 0x0102, [UIntPtr]([uint32][char]$ch), [IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 35
    }
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
$backgroundImagePath = Join-Path $OutDir "d3d11-background-image-$timestamp.png"
$previewFixtureDir = Join-Path $OutDir "preview-fixture-$timestamp"
$initialShot = Join-Path $OutDir "d3d11-initial-$timestamp.png"
$tabsActive2Shot = Join-Path $OutDir "d3d11-tabs-active2-$timestamp.png"
$tabsCloseHoverShot = Join-Path $OutDir "d3d11-tabs-close-hover-$timestamp.png"
$sidebarShot = Join-Path $OutDir "d3d11-sidebar-$timestamp.png"
$explorerShot = Join-Path $OutDir "d3d11-file-explorer-$timestamp.png"
$markdownPreviewShot = Join-Path $OutDir "d3d11-markdown-preview-$timestamp.png"
$imagePreviewShot = Join-Path $OutDir "d3d11-image-preview-$timestamp.png"
$assistantPanelShot = Join-Path $OutDir "d3d11-assistant-panel-$timestamp.png"
$paletteShot = Join-Path $OutDir "d3d11-command-palette-$timestamp.png"
$startupShortcutsShot = Join-Path $OutDir "d3d11-startup-shortcuts-$timestamp.png"
$settingsShot = Join-Path $OutDir "d3d11-settings-page-$timestamp.png"
$skillCenterShot = Join-Path $OutDir "d3d11-skill-center-$timestamp.png"
$rapidResizeShot = Join-Path $OutDir "d3d11-rapid-resize-$timestamp.png"
$metricsPath = Join-Path $OutDir "d3d11-normal-session-$timestamp.json"
$appDataDir = Join-Path $OutDir "appdata"
$diagnosticPath = Join-Path $appDataDir "wispterm\render-diagnostic.log"

New-Item -ItemType Directory -Force -Path $appDataDir | Out-Null
$statePath = Join-Path $appDataDir "wispterm\state"
Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
New-SmokeBackgroundImage $backgroundImagePath
$previewFixtures = New-SmokePreviewFixtures $previewFixtureDir
$aiProfilePath = New-SmokeAiProfile $appDataDir
if (!$workingDirectoryProvided) {
    $WorkingDirectory = $previewFixtureDir
}
@"
shell = $Shell
wispterm-debug-render = true
restore-tabs-on-startup = false
ai-default-profile = D3D11 Smoke
background-image = $backgroundImagePath
background-opacity = 0.18
background-image-mode = fill
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$oldAppData = $env:APPDATA
$oldRenderDiagnostics = $env:WISPTERM_RENDER_DIAGNOSTICS
$oldUiSmoke = $env:WISPTERM_D3D11_UI_SMOKE
$oldOffscreenSmoke = $env:WISPTERM_D3D11_OFFSCREEN_SMOKE
$oldRecreateSmoke = $env:WISPTERM_D3D11_RECREATE_SMOKE
$oldFallbackMarkerSmoke = $env:WISPTERM_D3D11_FALLBACK_MARKER_SMOKE

$env:APPDATA = $appDataDir
$env:WISPTERM_RENDER_DIAGNOSTICS = "1"
$env:WISPTERM_D3D11_UI_SMOKE = "1"
$env:WISPTERM_D3D11_OFFSCREEN_SMOKE = "1"
if ($RecreateSmoke) {
    $env:WISPTERM_D3D11_RECREATE_SMOKE = "1"
} else {
    Remove-Item Env:WISPTERM_D3D11_RECREATE_SMOKE -ErrorAction SilentlyContinue
}
if ($FallbackMarkerSmoke) {
    $env:WISPTERM_D3D11_FALLBACK_MARKER_SMOKE = "1"
} else {
    Remove-Item Env:WISPTERM_D3D11_FALLBACK_MARKER_SMOKE -ErrorAction SilentlyContinue
}

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

    Send-AltDigit 0x31
    Start-Sleep -Milliseconds 450
    $initialSize = Capture-Window $wisptermWindow $initialShot
    $initialMetrics = Analyze-Image $initialShot
    $backgroundImageMetrics = Analyze-BackgroundImageSurface $initialShot
    $rapidResizeMetrics = @{
        Enabled = [bool]$RapidResizeSmoke
        Pass = $true
        Width = $initialSize.Width
        Height = $initialSize.Height
        WidthDelta = 0
        HeightDelta = 0
        NonDark = 0
        Bright = 0
        Saturated = 0
    }
    if ($RapidResizeSmoke) {
        $rapidResizeMetrics = Invoke-RapidResizeSmoke $wisptermWindow $WindowX $WindowY $initialSize.Width $initialSize.Height $rapidResizeShot
        Start-Sleep -Milliseconds 500
    }

    Send-AltDigit 0x32
    Start-Sleep -Milliseconds 700
    Capture-Window $wisptermWindow $tabsActive2Shot | Out-Null

    Move-MouseWindow $wisptermWindow 198 192
    Start-Sleep -Milliseconds 1100
    Capture-Window $wisptermWindow $tabsCloseHoverShot | Out-Null
    $tabChromeMetrics = Analyze-TabChrome $initialShot $tabsActive2Shot $tabsCloseHoverShot

    Send-AltDigit 0x31
    Start-Sleep -Milliseconds 700

    Move-MouseWindow $wisptermWindow 620 390
    Start-Sleep -Milliseconds 250
    Send-CtrlShiftB
    Start-Sleep -Milliseconds 1000
    Capture-Window $wisptermWindow $sidebarShot | Out-Null
    $sidebarDelta = Compare-Images $initialShot $sidebarShot

    Send-CtrlShiftAltE
    Start-Sleep -Milliseconds 1400
    Capture-Window $wisptermWindow $explorerShot | Out-Null
    $explorerDelta = Compare-Images $sidebarShot $explorerShot

    DoubleClick-WindowPoint $wisptermWindow 92 116
    Start-Sleep -Milliseconds 2200
    Capture-Window $wisptermWindow $markdownPreviewShot | Out-Null
    $markdownPreviewMetrics = Analyze-MarkdownPreviewSurface $explorerShot $markdownPreviewShot

    DoubleClick-WindowPoint $wisptermWindow 92 158
    Start-Sleep -Milliseconds 2200
    Capture-Window $wisptermWindow $imagePreviewShot | Out-Null
    $imagePreviewMetrics = Analyze-ImagePreviewSurface $markdownPreviewShot $imagePreviewShot

    Send-CtrlShiftA
    Start-Sleep -Milliseconds 1300
    Capture-Window $wisptermWindow $assistantPanelShot | Out-Null
    $assistantPanelMetrics = Analyze-AssistantPanelSurface $imagePreviewShot $assistantPanelShot

    Send-CtrlShiftA
    Start-Sleep -Milliseconds 900

    Send-CtrlShiftP
    Start-Sleep -Milliseconds 1000
    Capture-Window $wisptermWindow $paletteShot | Out-Null
    $paletteDelta = Compare-Images $imagePreviewShot $paletteShot

    Send-WindowText $wisptermWindow "keyboard"
    Start-Sleep -Milliseconds 600
    Send-Enter
    Start-Sleep -Milliseconds 1200
    Capture-Window $wisptermWindow $startupShortcutsShot | Out-Null
    $startupShortcutsMetrics = Analyze-StartupShortcutsOverlay $imagePreviewShot $startupShortcutsShot

    Send-Escape
    Start-Sleep -Milliseconds 650
    Click-WindowPoint $wisptermWindow 1078 24
    Start-Sleep -Milliseconds 1100
    Capture-Window $wisptermWindow $settingsShot | Out-Null
    $settingsPageMetrics = Analyze-PageSurface $imagePreviewShot $settingsShot 230 54 780 662 900 0.018 120

    Send-Escape
    Start-Sleep -Milliseconds 650
    Send-CtrlShiftP
    Start-Sleep -Milliseconds 850
    Click-WindowPoint $wisptermWindow 620 496
    Start-Sleep -Milliseconds 1600
    Capture-Window $wisptermWindow $skillCenterShot | Out-Null
    $skillCenterMetrics = Analyze-PageSurface $imagePreviewShot $skillCenterShot 220 46 1010 725 1100 0.014 140

    $diagText = Wait-ForDiagnosticText $diagnosticPath "d3d11-ui-smoke probe .* ok=true" 12
    $hasD3D11Present = $diagText -match "gpu-backend=d3d11 present=dxgi"
    $hasD3D11InitDetails = (
        $diagText -match "gpu-backend=d3d11 present=dxgi .*swap_effect=flip_discard.*fallback_reason=none.*policy_state=healthy.*fallback_candidate=false" -and
        (
            $diagText -match "adapter_vendor=0x[0-9a-fA-F]+.*adapter_device=0x[0-9a-fA-F]+.*adapter_luid=" -or
            $diagText -match "adapter=unknown"
        )
    )
    $hasD3D11PolicyHealthy = $diagText -match "gpu-backend=d3d11 present=dxgi .*policy_state=healthy.*fallback_candidate=false"
    $hasD3D11RecoveryRequested = $diagText -match "gpu-backend=d3d11 recovery requested"
    $hasD3D11RecreateSmokeRequest = $diagText -match "d3d11-recreate-smoke requested device recreate"
    $hasD3D11RecreateSucceeded = $diagText -match "gpu-backend=d3d11 recovery recreate attempt attempted=true succeeded=true"
    $hasD3D11ResourceRestore = $diagText -match "gpu-backend=d3d11 resource recreate restored"
    $hasD3D11FallbackMarkerSmoke = $diagText -match "d3d11-fallback-marker-smoke .*readback_ok=true.*readback_matches=true.*explicit_d3d11_ignored=true.*current_auto_default_unchanged=true.*future_auto_opengl_marker=true.*automatic_fallback=false.*default_unchanged=true"
    $hasUiProbe = $diagText -match "d3d11-ui-smoke probe .* ok=true"
    $hasOffscreen = $diagText -match "d3d11-offscreen-smoke round-trip active"
    $d3d11ResizeEventCount = [regex]::Matches($diagText, "gpu-backend=d3d11 resized swapchain to").Count
    $rapidResizeDiagnostic = if ($RapidResizeSmoke) { $d3d11ResizeEventCount -gt 0 } else { $true }
    $hasFailures = $diagText -match "present failed|shader compile failed|backbuffer probe failed|resize sync failed"
    $recreateExpectation = if ($RecreateSmoke) {
        ($hasD3D11RecoveryRequested -and $hasD3D11RecreateSmokeRequest -and $hasD3D11RecreateSucceeded -and $hasD3D11ResourceRestore)
    } else {
        (!$hasD3D11RecoveryRequested -and !$hasD3D11RecreateSmokeRequest -and !$hasD3D11RecreateSucceeded)
    }
    $stateText = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw } else { "" }
    $hasD3D11FallbackMarkerState = $stateText -match "d3d11-fallback = d3d11:v1;kind=fallback_candidate;.*reason=environment_blocked"
    $fallbackMarkerExpectation = if ($FallbackMarkerSmoke) {
        ($hasD3D11FallbackMarkerSmoke -and $hasD3D11FallbackMarkerState)
    } else {
        (!$hasD3D11FallbackMarkerSmoke)
    }

    $pass = [bool](
        $initialMetrics.Pass -and
        $backgroundImageMetrics.Pass -and
        $tabChromeMetrics.Pass -and
        $sidebarDelta.Pass -and
        $explorerDelta.Pass -and
        $markdownPreviewMetrics.Pass -and
        $imagePreviewMetrics.Pass -and
        $assistantPanelMetrics.Pass -and
        $paletteDelta.Pass -and
        $startupShortcutsMetrics.Pass -and
        $settingsPageMetrics.Pass -and
        $skillCenterMetrics.Pass -and
        $rapidResizeMetrics.Pass -and
        $hasD3D11Present -and
        $hasD3D11InitDetails -and
        $hasD3D11PolicyHealthy -and
        $recreateExpectation -and
        $fallbackMarkerExpectation -and
        $rapidResizeDiagnostic -and
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
        background_image = $backgroundImagePath
        ai_profile = $aiProfilePath
        preview_fixture_dir = $previewFixtureDir
        preview_markdown = $previewFixtures.Markdown
        preview_image = $previewFixtures.Image
        diagnostic_log = $diagnosticPath
        screenshots = [ordered]@{
            initial = $initialShot
            background_image = $initialShot
            tabs_active_2 = $tabsActive2Shot
            tabs_close_hover = $tabsCloseHoverShot
            sidebar = $sidebarShot
            file_explorer = $explorerShot
            markdown_preview = $markdownPreviewShot
            image_preview = $imagePreviewShot
            assistant_panel = $assistantPanelShot
            command_palette = $paletteShot
            startup_shortcuts = $startupShortcutsShot
            settings_page = $settingsShot
            skill_center = $skillCenterShot
            rapid_resize = if ($RapidResizeSmoke) { $rapidResizeShot } else { "" }
        }
        initial = [ordered]@{
            samples = $initialMetrics.Samples
            non_dark = $initialMetrics.NonDark
            bright = $initialMetrics.Bright
            saturated = $initialMetrics.Saturated
            pass = [bool]$initialMetrics.Pass
        }
        background_image_surface = [ordered]@{
            samples = $backgroundImageMetrics.Samples
            bright = $backgroundImageMetrics.Bright
            saturated = $backgroundImageMetrics.Saturated
            avg_r = [Math]::Round($backgroundImageMetrics.AvgR, 3)
            avg_g = [Math]::Round($backgroundImageMetrics.AvgG, 3)
            avg_b = [Math]::Round($backgroundImageMetrics.AvgB, 3)
            luma = [Math]::Round($backgroundImageMetrics.Luma, 3)
            pass = [bool]$backgroundImageMetrics.Pass
        }
        tab_chrome = [ordered]@{
            active_state_swap = [bool]$tabChromeMetrics.ActiveStateSwap
            text_visible = [bool]$tabChromeMetrics.TextVisible
            plus_icon_visible = [bool]$tabChromeMetrics.PlusIconVisible
            close_hover_affordance = [bool]$tabChromeMetrics.CloseHoverAffordance
            row1_active_advantage = [Math]::Round($tabChromeMetrics.Row1ActiveAdvantage, 3)
            row2_active_advantage = [Math]::Round($tabChromeMetrics.Row2ActiveAdvantage, 3)
            row_swap_delta = [Math]::Round($tabChromeMetrics.RowSwapDelta, 3)
            row1_active_luma = [Math]::Round($tabChromeMetrics.Row1ActiveLuma, 3)
            row1_inactive_luma = [Math]::Round($tabChromeMetrics.Row1InactiveLuma, 3)
            row2_inactive_luma = [Math]::Round($tabChromeMetrics.Row2InactiveLuma, 3)
            row2_active_luma = [Math]::Round($tabChromeMetrics.Row2ActiveLuma, 3)
            row1_text_bright = $tabChromeMetrics.Row1TextBright
            row2_text_bright = $tabChromeMetrics.Row2TextBright
            plus_bright = $tabChromeMetrics.PlusBright
            plus_saturated = $tabChromeMetrics.PlusSaturated
            close_bright_before = $tabChromeMetrics.CloseBrightBefore
            close_bright_after = $tabChromeMetrics.CloseBrightAfter
            close_changed = $tabChromeMetrics.CloseChanged
            close_changed_ratio = [Math]::Round($tabChromeMetrics.CloseChangedRatio, 5)
            row2_hover_changed = $tabChromeMetrics.Row2HoverChanged
            row2_hover_changed_ratio = [Math]::Round($tabChromeMetrics.Row2HoverChangedRatio, 5)
            pass = [bool]$tabChromeMetrics.Pass
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
        markdown_preview = [ordered]@{
            changed = $markdownPreviewMetrics.Changed
            changed_ratio = [Math]::Round($markdownPreviewMetrics.ChangedRatio, 5)
            header_bright = $markdownPreviewMetrics.HeaderBright
            body_bright = $markdownPreviewMetrics.BodyBright
            body_luma = [Math]::Round($markdownPreviewMetrics.BodyLuma, 3)
            samples = $markdownPreviewMetrics.Samples
            pass = [bool]$markdownPreviewMetrics.Pass
        }
        image_preview = [ordered]@{
            changed = $imagePreviewMetrics.Changed
            changed_ratio = [Math]::Round($imagePreviewMetrics.ChangedRatio, 5)
            bright = $imagePreviewMetrics.Bright
            saturated = $imagePreviewMetrics.Saturated
            luma = [Math]::Round($imagePreviewMetrics.Luma, 3)
            samples = $imagePreviewMetrics.Samples
            pass = [bool]$imagePreviewMetrics.Pass
        }
        assistant_panel = [ordered]@{
            changed = $assistantPanelMetrics.Changed
            changed_ratio = [Math]::Round($assistantPanelMetrics.ChangedRatio, 5)
            header_bright = $assistantPanelMetrics.HeaderBright
            composer_bright = $assistantPanelMetrics.ComposerBright
            composer_luma = [Math]::Round($assistantPanelMetrics.ComposerLuma, 3)
            samples = $assistantPanelMetrics.Samples
            pass = [bool]$assistantPanelMetrics.Pass
        }
        command_palette_delta = [ordered]@{
            changed = $paletteDelta.Changed
            samples = $paletteDelta.Samples
            changed_ratio = [Math]::Round($paletteDelta.ChangedRatio, 5)
            pass = [bool]$paletteDelta.Pass
        }
        startup_shortcuts = [ordered]@{
            changed = $startupShortcutsMetrics.Changed
            changed_ratio = [Math]::Round($startupShortcutsMetrics.ChangedRatio, 5)
            heading_bright = $startupShortcutsMetrics.HeadingBright
            body_bright = $startupShortcutsMetrics.BodyBright
            body_luma = [Math]::Round($startupShortcutsMetrics.BodyLuma, 3)
            samples = $startupShortcutsMetrics.Samples
            pass = [bool]$startupShortcutsMetrics.Pass
        }
        settings_page = [ordered]@{
            changed = $settingsPageMetrics.Changed
            changed_ratio = [Math]::Round($settingsPageMetrics.ChangedRatio, 5)
            bright = $settingsPageMetrics.Bright
            saturated = $settingsPageMetrics.Saturated
            luma = [Math]::Round($settingsPageMetrics.Luma, 3)
            samples = $settingsPageMetrics.Samples
            pass = [bool]$settingsPageMetrics.Pass
        }
        skill_center = [ordered]@{
            changed = $skillCenterMetrics.Changed
            changed_ratio = [Math]::Round($skillCenterMetrics.ChangedRatio, 5)
            bright = $skillCenterMetrics.Bright
            saturated = $skillCenterMetrics.Saturated
            luma = [Math]::Round($skillCenterMetrics.Luma, 3)
            samples = $skillCenterMetrics.Samples
            pass = [bool]$skillCenterMetrics.Pass
        }
        rapid_resize = [ordered]@{
            enabled = [bool]$rapidResizeMetrics.Enabled
            width = $rapidResizeMetrics.Width
            height = $rapidResizeMetrics.Height
            width_delta = $rapidResizeMetrics.WidthDelta
            height_delta = $rapidResizeMetrics.HeightDelta
            non_dark = $rapidResizeMetrics.NonDark
            bright = $rapidResizeMetrics.Bright
            saturated = $rapidResizeMetrics.Saturated
            pass = [bool]$rapidResizeMetrics.Pass
        }
        diagnostics = [ordered]@{
            d3d11_present = [bool]$hasD3D11Present
            d3d11_init_details = [bool]$hasD3D11InitDetails
            d3d11_policy_healthy = [bool]$hasD3D11PolicyHealthy
            d3d11_resize_events = $d3d11ResizeEventCount
            d3d11_rapid_resize_diagnostics = [bool]$rapidResizeDiagnostic
            d3d11_recovery_requested = [bool]$hasD3D11RecoveryRequested
            d3d11_recreate_smoke_requested = [bool]$hasD3D11RecreateSmokeRequest
            d3d11_recreate_succeeded = [bool]$hasD3D11RecreateSucceeded
            d3d11_resource_restore = [bool]$hasD3D11ResourceRestore
            d3d11_fallback_marker_smoke = [bool]$hasD3D11FallbackMarkerSmoke
            d3d11_fallback_marker_state = [bool]$hasD3D11FallbackMarkerState
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
    $env:WISPTERM_D3D11_RECREATE_SMOKE = $oldRecreateSmoke
    $env:WISPTERM_D3D11_FALLBACK_MARKER_SMOKE = $oldFallbackMarkerSmoke
}
