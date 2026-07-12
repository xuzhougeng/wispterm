param(
    [string]$Version,
    [string]$OutputDir = '.\zig-out\dist',
    [string]$WebView2Version = '1.0.3912.50',
    [string]$ConPtyVersion = '1.24.260512001',
    [switch]$SkipBuild,
    [switch]$SkipCompatBundle,
    [switch]$SkipNativeD3D11Bundle,
    [switch]$DebugConsole,
    [string]$Optimize = 'ReleaseFast'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReleaseVersion {
    param([string]$ExplicitVersion)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        return $ExplicitVersion.Trim()
    }

    try {
        $gitVersion = (& git describe --tags --always --dirty 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $trimmed = $gitVersion.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                return $trimmed
            }
        }
    } catch {
    }

    return (Get-Date -Format 'yyyy.MM.dd')
}

function Get-WebView2Loader {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $loaderRelativePath = 'build\native\x64\WebView2Loader.dll'
    $nugetLoader = Join-Path $env:USERPROFILE ".nuget\packages\microsoft.web.webview2\$Version\$loaderRelativePath"
    if (Test-Path $nugetLoader) {
        return $nugetLoader
    }

    $cacheRoot = Join-Path $RepoRoot '.zig-cache\webview2'
    $packageDir = Join-Path $cacheRoot "Microsoft.Web.WebView2.$Version"
    $cachedLoader = Join-Path $packageDir $loaderRelativePath
    if (Test-Path $cachedLoader) {
        return $cachedLoader
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $nupkgPath = Join-Path $cacheRoot "Microsoft.Web.WebView2.$Version.nupkg"
    $zipPath = Join-Path $cacheRoot "Microsoft.Web.WebView2.$Version.zip"
    $packageUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version"

    if (-not (Test-Path $nupkgPath)) {
        Write-Host "Downloading Microsoft.Web.WebView2 $Version"
        Invoke-WebRequest -Uri $packageUrl -OutFile $nupkgPath
    }

    Remove-Item -Path $packageDir -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $nupkgPath -Destination $zipPath -Force
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $packageDir -Force
    } finally {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $cachedLoader)) {
        throw "WebView2Loader.dll was not found in Microsoft.Web.WebView2 $Version."
    }

    return $cachedLoader
}

function Get-ConPtyPair {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $cacheRoot = Join-Path $RepoRoot '.zig-cache\conpty'
    $packageDir = Join-Path $cacheRoot "Microsoft.Windows.Console.ConPTY.$Version"
    $dllPath = Join-Path $packageDir 'runtimes\win-x64\native\conpty.dll'
    $hostPath = Join-Path $packageDir 'build\native\runtimes\x64\OpenConsole.exe'
    if ((Test-Path $dllPath) -and (Test-Path $hostPath)) {
        return @{ Dll = $dllPath; HostExe = $hostPath }
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $nupkgPath = Join-Path $cacheRoot "Microsoft.Windows.Console.ConPTY.$Version.nupkg"
    $zipPath = Join-Path $cacheRoot "Microsoft.Windows.Console.ConPTY.$Version.zip"
    $packageUrl = "https://www.nuget.org/api/v2/package/Microsoft.Windows.Console.ConPTY/$Version"

    if (-not (Test-Path $nupkgPath)) {
        Write-Host "Downloading Microsoft.Windows.Console.ConPTY $Version"
        Invoke-WebRequest -Uri $packageUrl -OutFile $nupkgPath
    }

    Remove-Item -Path $packageDir -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $nupkgPath -Destination $zipPath -Force
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $packageDir -Force
    } finally {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $dllPath)) {
        throw "conpty.dll was not found in Microsoft.Windows.Console.ConPTY $Version."
    }
    if (-not (Test-Path $hostPath)) {
        throw "OpenConsole.exe was not found in Microsoft.Windows.Console.ConPTY $Version."
    }

    return @{ Dll = $dllPath; HostExe = $hostPath }
}

function Copy-PortablePayload {
    param(
        [Parameter(Mandatory = $true)][string]$BinaryPath,
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$ReleaseVersion,
        [string]$WebView2LoaderPath,
        [hashtable]$ConPtyPair
    )

    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    Copy-Item -Path $BinaryPath -Destination (Join-Path $TargetDir 'wispterm.exe') -Force
    $sourceAskPassHelper = Join-Path (Split-Path -Parent $BinaryPath) 'wispterm-ssh-askpass.exe'
    if (-not (Test-Path $sourceAskPassHelper)) {
        throw "Expected SSH askpass helper was not found: $sourceAskPassHelper"
    }
    Copy-Item -Path $sourceAskPassHelper -Destination (Join-Path $TargetDir 'wispterm-ssh-askpass.exe') -Force
    Set-Content -Path (Join-Path $TargetDir 'version.txt') -Value $ReleaseVersion -Encoding ASCII

    $targetPluginsDir = Join-Path $TargetDir 'plugins'
    New-Item -ItemType Directory -Path $targetPluginsDir -Force | Out-Null

    $sourcePluginsDir = Join-Path (Split-Path -Parent $BinaryPath) 'plugins'
    if (Test-Path $sourcePluginsDir) {
        Get-ChildItem -LiteralPath $sourcePluginsDir -Force | Copy-Item -Destination $targetPluginsDir -Recurse -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($WebView2LoaderPath)) {
        Copy-Item -Path $WebView2LoaderPath -Destination (Join-Path $TargetDir 'WebView2Loader.dll') -Force
    }

    if ($null -ne $ConPtyPair) {
        Copy-Item -Path $ConPtyPair.Dll -Destination (Join-Path $TargetDir 'conpty.dll') -Force
        Copy-Item -Path $ConPtyPair.HostExe -Destination (Join-Path $TargetDir 'OpenConsole.exe') -Force
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$resolvedOutputDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))
$releaseVersion = Get-ReleaseVersion -ExplicitVersion $Version

if ($DebugConsole) {
    Push-Location $repoRoot
    try {
        & zig build "-Doptimize=$Optimize" -Ddebug-console
        if ($LASTEXITCODE -ne 0) { throw "zig build -Doptimize=$Optimize -Ddebug-console failed." }
    } finally {
        Pop-Location
    }

    $debugBinary = Join-Path $repoRoot 'zig-out\bin\wispterm.exe'
    if (-not (Test-Path $debugBinary)) { throw "Debug binary not found: $debugBinary" }

    $debugDir = Join-Path $resolvedOutputDir 'portable-debug'
    Remove-Item -Path $debugDir -Recurse -Force -ErrorAction SilentlyContinue

    # Bundle the compat DLLs so the debug build runs on older Windows 10 too.
    $webView2LoaderPath = Get-WebView2Loader -RepoRoot $repoRoot -Version $WebView2Version
    $conPtyPair = Get-ConPtyPair -RepoRoot $repoRoot -Version $ConPtyVersion
    Copy-PortablePayload -BinaryPath $debugBinary -TargetDir $debugDir -ReleaseVersion $releaseVersion -WebView2LoaderPath $webView2LoaderPath -ConPtyPair $conPtyPair

    Write-Host "Debug build ($Optimize, console): $(Join-Path $debugDir 'wispterm.exe')"
    exit 0
}

$nativeD3D11InstallDir = Join-Path $repoRoot 'zig-out-native-d3d11'

if (-not $SkipBuild) {
    Push-Location $repoRoot
    try {
        & zig build -Doptimize=ReleaseFast -Dgpu-backend=opengl
        if ($LASTEXITCODE -ne 0) {
            throw 'zig build -Doptimize=ReleaseFast -Dgpu-backend=opengl failed.'
        }
        if (-not $SkipNativeD3D11Bundle) {
            Remove-Item -Path $nativeD3D11InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            & zig build -Doptimize=ReleaseFast -Dgpu-backend=d3d11 -p $nativeD3D11InstallDir
            if ($LASTEXITCODE -ne 0) {
                throw 'zig build -Doptimize=ReleaseFast -Dgpu-backend=d3d11 failed.'
            }
        }
    } finally {
        Pop-Location
    }
}

$binaryPath = Join-Path $repoRoot 'zig-out\bin\wispterm.exe'
if (-not (Test-Path $binaryPath)) {
    throw "Expected release binary was not found: $binaryPath"
}
$nativeD3D11BinaryPath = Join-Path $nativeD3D11InstallDir 'bin\wispterm.exe'
if (-not $SkipNativeD3D11Bundle -and -not (Test-Path $nativeD3D11BinaryPath)) {
    throw "Expected native D3D11 release binary was not found: $nativeD3D11BinaryPath"
}

$portableDir = Join-Path $resolvedOutputDir 'portable'
$portableCompatDir = Join-Path $resolvedOutputDir 'portable-compat'
$portableNativeD3D11Dir = Join-Path $resolvedOutputDir 'portable-native-d3d11'
$webView2LoaderPath = $null
$conPtyPair = $null

if (-not $SkipCompatBundle) {
    $webView2LoaderPath = Get-WebView2Loader -RepoRoot $repoRoot -Version $WebView2Version
    $conPtyPair = Get-ConPtyPair -RepoRoot $repoRoot -Version $ConPtyVersion
}

Remove-Item -Path $portableDir, $portableCompatDir, $portableNativeD3D11Dir, (Join-Path $resolvedOutputDir 'installer') -Recurse -Force -ErrorAction SilentlyContinue

Copy-PortablePayload -BinaryPath $binaryPath -TargetDir $portableDir -ReleaseVersion $releaseVersion
if ($webView2LoaderPath) {
    Copy-PortablePayload -BinaryPath $binaryPath -TargetDir $portableCompatDir -ReleaseVersion $releaseVersion -WebView2LoaderPath $webView2LoaderPath -ConPtyPair $conPtyPair
}
if (-not $SkipNativeD3D11Bundle) {
    Copy-PortablePayload -BinaryPath $nativeD3D11BinaryPath -TargetDir $portableNativeD3D11Dir -ReleaseVersion $releaseVersion
}

Write-Host "Portable build: $(Join-Path $portableDir 'wispterm.exe')"
if ($webView2LoaderPath) {
    Write-Host "Portable compat build: $(Join-Path $portableCompatDir 'wispterm.exe')"
}
if (-not $SkipNativeD3D11Bundle) {
    Write-Host "Portable native D3D11 build: $(Join-Path $portableNativeD3D11Dir 'wispterm.exe')"
}
