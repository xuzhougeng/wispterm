# Authenticode-sign WispTerm's first-party Windows dist binaries with SSL.com
# eSigner CodeSignTool, then verify each signature. Zip archives are never
# signed. Tag releases call this with -Require after packaging and before
# Compress-Archive.
#
# Required environment variables (GitHub Actions secrets; never commit values):
#   ESIGNER_CREDENTIAL_ID  eSigner signing credential id
#   ESIGNER_USERNAME       SSL.com account username
#   ESIGNER_PASSWORD       SSL.com account password
#   ESIGNER_TOTP_SECRET    TOTP seed CodeSignTool uses to compute the OTP
#   ESIGNER_PIN            4-digit eSigner enrollment PIN for that credential
#
# CodeSignTool 1.3.2 batch_sign has no PIN flag. The PIN is required so the
# release credential set is complete; it is not placed on the command line and
# is never written to the log. Signing uses username, password, credential id,
# and the TOTP secret. PE timestamps use TSA_URL. SSL.com's default
# http://ts.ssl.com issues ECDSA timestamps that Windows Authenticode rejects
# ("timestamp certificate does not meet a minimum public key length"). This
# script pins TSA_URL to http://ts.ssl.com/legacy, SSL.com's RFC3161 RSA
# timestamp authority.

param(
    [Parameter(Mandatory = $true)][string]$DistRoot,
    [switch]$Require,
    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CodeSignToolVersion = '1.3.2'
$script:CodeSignToolZipUrl = 'https://github.com/SSLcom/CodeSignTool/releases/download/v1.3.2/CodeSignTool-v1.3.2-windows.zip'
# CodeSignTool's PE signer timestamps with TSA_URL (SPC_RFC3161). Use the
# RSA RFC3161 endpoint so Windows accepts the timestamp certificate.
$script:TimestampUrl = 'http://ts.ssl.com/legacy'
$script:LegacyTimestampUrl = 'http://ts.ssl.com/legacy'
$script:BundleNames = @('portable', 'portable-compat', 'portable-opengl', 'portable-debug')
$script:SignNames = @('wispterm.exe', 'wispterm-ssh-askpass.exe', 'wispterm-shell-extension.dll')
$script:SecretNames = @(
    'ESIGNER_CREDENTIAL_ID',
    'ESIGNER_USERNAME',
    'ESIGNER_PASSWORD',
    'ESIGNER_TOTP_SECRET',
    'ESIGNER_PIN'
)

function Get-SecretValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Require) {
            throw "Tag release signing requires GitHub Actions secret $Name. Secret values are not stored in the repo."
        }
        throw "eSigner signing requires environment variable $Name. Secret values are not stored in the repo."
    }
    if ($value -match "[\r\n]") {
        throw "$Name contains a newline. Refusing to pass it to CodeSignTool."
    }
    return $value
}

function Redact-Text {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $redacted = $Text
    foreach ($name in @('ESIGNER_PASSWORD', 'ESIGNER_TOTP_SECRET', 'ESIGNER_USERNAME', 'ESIGNER_CREDENTIAL_ID')) {
        $secret = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($secret)) {
            $redacted = $redacted.Replace($secret, '[' + $name + ']')
        }
    }
    $pin = [Environment]::GetEnvironmentVariable('ESIGNER_PIN')
    if (-not [string]::IsNullOrEmpty($pin)) {
        $pattern = '(?<!\w)' + [regex]::Escape($pin) + '(?!\w)'
        $redacted = [regex]::Replace($redacted, $pattern, '[ESIGNER_PIN]')
    }
    return $redacted
}

function Resolve-DistRoot {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location) $Path
    }
    return [IO.Path]::GetFullPath($Path)
}

function Get-SignTargets {
    param([Parameter(Mandatory = $true)][string]$Root)

    $targets = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    foreach ($bundle in $script:BundleNames) {
        $bundleRoot = Join-Path $Root $bundle
        if (-not (Test-Path -LiteralPath $bundleRoot)) {
            throw "Missing Windows dist bundle '$bundle' under $Root"
        }

        $found = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
        Get-ChildItem -LiteralPath $bundleRoot -Recurse -File | ForEach-Object {
            # Zip archives, and the context-menu MSIX, are not Authenticode
            # inputs for this step. Microsoft compat binaries keep their own
            # signatures: WebView2Loader.dll, conpty.dll, OpenConsole.exe.
            if ($_.Extension -in @('.zip', '.msix', '.appx')) { return }
            if ($_.Name -in @('WebView2Loader.dll', 'conpty.dll', 'OpenConsole.exe')) { return }
            if ($script:SignNames -contains $_.Name) {
                $found.Add($_)
            }
        }

        foreach ($name in $script:SignNames) {
            $hits = @($found | Where-Object { $_.Name -eq $name })
            if ($hits.Count -lt 1) {
                throw "Bundle '$bundle' is missing required sign target $name"
            }
        }

        foreach ($file in $found) { $targets.Add($file) }
    }

    if ($targets.Count -gt 100) {
        throw "CodeSignTool batch_sign accepts at most 100 files ($($targets.Count) selected)."
    }
    if ($targets.Count -lt 1) {
        throw "No first-party binaries selected under $Root"
    }
    return $targets
}

function Get-TreeHashes {
    param([string]$Root)
    $map = @{}
    Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        $map[$_.FullName] = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
    }
    return $map
}

function Set-CodeSignToolProperty {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $lines = @(Get-Content -LiteralPath $Path)
    $pattern = '^\s*' + [regex]::Escape($Key) + '='
    $updated = $false
    $next = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match $pattern) {
            $next.Add("$Key=$Value")
            $updated = $true
        } else {
            $next.Add($line)
        }
    }
    if (-not $updated) { $next.Add("$Key=$Value") }
    [IO.File]::WriteAllLines($Path, $next.ToArray())
}

function Install-CodeSignTool {
    param([Parameter(Mandatory = $true)][string]$Destination)
    $java = Join-Path $Destination 'jdk-11.0.2\bin\java.exe'
    $jar = Join-Path $Destination "jar\code_sign_tool-$($script:CodeSignToolVersion).jar"
    $props = Join-Path $Destination 'conf\code_sign_tool.properties'
    if ((Test-Path -LiteralPath $java) -and (Test-Path -LiteralPath $jar) -and (Test-Path -LiteralPath $props)) {
        return @{ Java = $java; Jar = $jar; Properties = $props; Root = $Destination }
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $zip = Join-Path $Destination "CodeSignTool-v$($script:CodeSignToolVersion)-windows.zip"
    $attempts = 5
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Write-Host "Downloading CodeSignTool $($script:CodeSignToolVersion) (attempt $attempt/$attempts)"
            Invoke-WebRequest -Uri $script:CodeSignToolZipUrl -OutFile $zip -UseBasicParsing
            break
        } catch {
            if ($attempt -eq $attempts) { throw }
            Start-Sleep -Seconds (15 * $attempt)
        }
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $Destination -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $java)) { throw "CodeSignTool java.exe was not found at $java" }
    if (-not (Test-Path -LiteralPath $jar)) { throw "CodeSignTool jar was not found at $jar" }
    if (-not (Test-Path -LiteralPath $props)) { throw "CodeSignTool properties were not found at $props" }
    return @{ Java = $java; Jar = $jar; Properties = $props; Root = $Destination }
}

function Invoke-CodeSignToolBatch {
    param(
        [Parameter(Mandatory = $true)]$Tool,
        [Parameter(Mandatory = $true)][string]$InputDir,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )
    if (Test-Path -LiteralPath $OutputDir) {
        Remove-Item -LiteralPath $OutputDir -Recurse -Force
    }

    # batch_sign refuses an output directory that already exists and reads
    # ./conf/code_sign_tool.properties from the process working directory.
    $signArgs = @(
        '-jar', $Tool.Jar,
        'batch_sign',
        "-username=$(Get-SecretValue 'ESIGNER_USERNAME')",
        "-password=$(Get-SecretValue 'ESIGNER_PASSWORD')",
        "-credential_id=$(Get-SecretValue 'ESIGNER_CREDENTIAL_ID')",
        "-totp_secret=$(Get-SecretValue 'ESIGNER_TOTP_SECRET')",
        "-input_dir_path=$InputDir",
        "-output_dir_path=$OutputDir"
    )
    $log = Join-Path ([IO.Path]::GetTempPath()) ("codesigntool-" + [guid]::NewGuid().ToString('N') + '.log')
    Push-Location $Tool.Root
    try {
        & $Tool.Java @signArgs *> $log
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $raw = ''
    if (Test-Path -LiteralPath $log) {
        $raw = [IO.File]::ReadAllText($log)
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    $redacted = Redact-Text $raw
    if ($redacted.Length -gt 4000) {
        $redacted = $redacted.Substring($redacted.Length - 4000)
    }
    Write-Host $redacted
    if ($exitCode -ne 0) {
        throw "CodeSignTool batch_sign failed with exit code $exitCode."
    }
    if ($raw -notmatch 'Batch sign command executed successfully') {
        throw 'CodeSignTool batch_sign exited 0 without a success marker.'
    }
    if ($raw -match '(?im)(^|\s)Error:') {
        throw 'CodeSignTool reported an error while signing.'
    }
}

function Assert-AuthenticodeSigned {
    param([Parameter(Mandatory = $true)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode status for $Path is $($signature.Status): $($signature.StatusMessage)"
    }
    if ($null -eq $signature.TimeStamperCertificate) {
        throw "Authenticode signature for $Path has no RFC3161 timestamp certificate."
    }
    $signer = $signature.SignerCertificate.Subject
    $stamped = $signature.TimeStamperCertificate.Subject
    Write-Host "Signed $Path"
    Write-Host "  signer: $signer"
    Write-Host "  timestamp: $stamped"
}

if (-not $ListOnly) {
    foreach ($name in $script:SecretNames) {
        $null = Get-SecretValue $name
    }
}

$resolvedRoot = Resolve-DistRoot $DistRoot
$targets = @(Get-SignTargets -Root $resolvedRoot)

if ($ListOnly) {
    $targets | Sort-Object FullName | ForEach-Object { Write-Output $_.FullName }
    exit 0
}

$before = Get-TreeHashes -Root $resolvedRoot
$targetPaths = @{}
foreach ($file in $targets) { $targetPaths[$file.FullName] = $true }

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $tempRoot ('wispterm-esigner-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'unsigned'
$signed = Join-Path $work 'signed'
$toolDir = Join-Path $tempRoot "CodeSignTool-v$($script:CodeSignToolVersion)"
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    $staged = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($file in ($targets | Sort-Object FullName)) {
        $stagedName = '{0:D3}-{1}' -f $index, $file.Name
        $index += 1
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stage $stagedName) -Force
        $staged.Add([pscustomobject]@{
            Source = $file.FullName
            StagedName = $stagedName
        })
    }

    $tool = Install-CodeSignTool -Destination $toolDir
    Set-CodeSignToolProperty -Path $tool.Properties -Key 'TSA_URL' -Value $script:TimestampUrl
    Set-CodeSignToolProperty -Path $tool.Properties -Key 'TSA_LEGACY_URL' -Value $script:LegacyTimestampUrl
    $configured = [IO.File]::ReadAllText($tool.Properties)
    if ($configured -notmatch '(?m)^TSA_URL=http://ts\.ssl\.com/legacy\s*$') {
        throw 'CodeSignTool TSA_URL is not the SSL.com RFC3161 RSA endpoint http://ts.ssl.com/legacy'
    }

    Write-Host "Signing $($staged.Count) first-party binaries with CodeSignTool $($script:CodeSignToolVersion)"
    Invoke-CodeSignToolBatch -Tool $tool -InputDir $stage -OutputDir $signed

    foreach ($entry in $staged) {
        $signedFile = Join-Path $signed $entry.StagedName
        if (-not (Test-Path -LiteralPath $signedFile)) {
            throw "CodeSignTool did not write $($entry.StagedName)"
        }
        Copy-Item -LiteralPath $signedFile -Destination $entry.Source -Force
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $toolLogs = Join-Path $toolDir 'logs'
    if (Test-Path -LiteralPath $toolLogs) {
        Remove-Item -LiteralPath $toolLogs -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$after = Get-TreeHashes -Root $resolvedRoot
foreach ($path in @($before.Keys)) {
    if (-not $after.ContainsKey($path)) {
        throw "Dist file disappeared during signing: $path"
    }
    if ($targetPaths.ContainsKey($path)) {
        if ($before[$path] -eq $after[$path]) {
            throw "Sign target was not modified: $path"
        }
    } elseif ($before[$path] -ne $after[$path]) {
        throw "Signing modified a file outside the first-party sign set: $path"
    }
}

foreach ($entry in $staged) {
    Assert-AuthenticodeSigned -Path $entry.Source
}

Write-Host "Authenticode verification passed for $($staged.Count) files. Zip archives were not signed."
