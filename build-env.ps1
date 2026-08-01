# Sets up the environment needed to build WispTerm on this machine, then builds.
# Usage (PowerShell):  .\build-env.ps1            # just set env vars
#          (PowerShell):  .\build-env.ps1 -Build   # set env vars and run `zig build`
#
# Why these are needed (see conversation notes):
#  - ZIG_GLOBAL_CACHE_DIR must live on the SAME drive as the source tree.
#    Zig 0.15.2 panics (assert in Build.Step.Run.convertPathArg) when a run
#    step's cwd and an argument path cross drive letters (source on E:, the
#    default zig cache on C:). Keeping the cache on E: avoids that.
#  - HTTP(S)_PROXY is only required when zig must fetch GitHub dependencies
#    (zigimg, uucode, imgui, etc.). Those are already cached, so an offline
#    build works without the proxy once the cache is warm.

param(
    [switch]$Build,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

# Keep the zig global package cache on the same drive as the source to avoid
# the Zig 0.15.2 cross-drive assert in Run.convertPathArg.
$env:ZIG_GLOBAL_CACHE_DIR = "E:\zig-global-cache"

# Uncomment the next two lines (or export them in your shell) when zig needs to
# fetch dependencies from GitHub through the local proxy.
# $env:HTTP_PROXY  = "http://localhost:11080"
# $env:HTTPS_PROXY = "http://localhost:11080"

Write-Host "ZIG_GLOBAL_CACHE_DIR = $env:ZIG_GLOBAL_CACHE_DIR"

if ($Build) {
    & "zig" build @Arguments
    exit $LASTEXITCODE
}
