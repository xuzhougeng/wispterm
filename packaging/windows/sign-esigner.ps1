# Authenticode-sign WispTerm's first-party Windows dist binaries with SSL.com
# eSigner CodeSignTool, then verify each signature. Zip archives are never
# signed. Tag releases call this with -Require after packaging and before
# Compress-Archive, and once more with -File for the NSIS setup exe that
# build-installer.ps1 wraps around the signed portable tree.
#
# Required environment variables (GitHub Actions secrets; never commit values):
#   ESIGNER_CREDENTIAL_ID  eSigner signing credential id
#   ESIGNER_USERNAME       SSL.com account username
#   ESIGNER_PASSWORD       SSL.com account password
#   ESIGNER_TOTP_SECRET    TOTP seed CodeSignTool uses to compute the OTP
#   ESIGNER_PIN            4-digit eSigner enrollment PIN for that credential
#
# Each file goes through CodeSignTool `sign`, one at a time, like citebox's
# scripts/sign-windows-authenticode.ps1. `batch_sign` only submits hashes, and
# an eSigner credential with Malware Blocker enabled rejects those with
# "hash needs to be scanned first before submitting for signing"; `sign`
# uploads the file, so eSigner scans it before signing. Byte-identical targets
# (the same helper copied into every bundle) are signed once.
#
# CodeSignTool 1.3.2 sign has no PIN flag. The PIN is required so the
# release credential set is complete; it is not placed on the command line and
# is never written to the log. Signing uses username, password, credential id,
# and the TOTP secret. PE timestamps use TSA_URL. SSL.com's default
# http://ts.ssl.com issues ECDSA timestamps that Windows Authenticode rejects
# ("timestamp certificate does not meet a minimum public key length"). This
# script pins TSA_URL to http://ts.ssl.com/legacy, SSL.com's RFC3161 RSA
# timestamp authority.
#
# CodeSignTool 1.3.2 main() discards picocli's exit code, so java exits 0 on
# auth errors, invalid OTPs, and bad arguments. Success is exit 0, the
# "Code signed successfully" marker, no Error:/exception text, and the signed
# copy in the output directory. An invalid OTP is retried into the next TOTP window
# even when the process exits 0. Failures print sanitized stdout, stderr, and
# logs/code_signing_tool.log.

param(
    # Not Mandatory: packaging/windows/sign-esigner.test.ps1 dot-sources this
    # file to call the functions. The entry point still requires -DistRoot or
    # -File.
    [string]$DistRoot,
    # Sign these files in place instead of a dist tree (the setup exe).
    # Not named $File: PowerShell variables are case-insensitive, so a
    # [string[]] $File parameter would also type the `foreach ($file ...)`
    # loops below and strip FileInfo down to its path string.
    [Alias('File')][string[]]$SignFile = @(),
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
$script:SignNames = @('wispterm.exe', 'wispterm-ssh-askpass.exe', 'wispterm-ssh-proxy.exe', 'wispterm-shell-extension.dll')
$script:SecretNames = @(
    'ESIGNER_CREDENTIAL_ID',
    'ESIGNER_USERNAME',
    'ESIGNER_PASSWORD',
    'ESIGNER_TOTP_SECRET',
    'ESIGNER_PIN'
)
# 35s leaves the current 30s TOTP window. Files are signed one after another,
# so a second file in the same window can see its OTP rejected and retries.
$script:OtpRetryDelaySeconds = 35
$script:OtpAttemptLimit = 4
$script:CodeSignTimeoutSeconds = 900

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
    # Longer values first so a short secret that is a substring of another
    # secret cannot split the longer one and leave the rest visible.
    $named = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('ESIGNER_PASSWORD', 'ESIGNER_TOTP_SECRET', 'ESIGNER_USERNAME', 'ESIGNER_CREDENTIAL_ID')) {
        $secret = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($secret)) {
            $named.Add([pscustomobject]@{ Name = $name; Value = $secret })
        }
    }
    foreach ($entry in @($named | Sort-Object { $_.Value.Length } -Descending)) {
        $redacted = $redacted.Replace($entry.Value, '[' + $entry.Name + ']')
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

function ConvertTo-WindowsProcessArgument {
    param([AllowNull()][string]$Argument)
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    $needsQuote = $Argument.IndexOfAny([char[]]@(' ', "`t", '"')) -ge 0
    if (-not $needsQuote) { return $Argument }

    # CommandLineToArgvW quoting. PowerShell 7 passes ArgumentList instead.
    # Windows PowerShell 5.1 only has ProcessStartInfo.Arguments.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            for ($i = 0; $i -lt (($backslashes * 2) + 1); $i++) { [void]$sb.Append('\') }
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        for ($i = 0; $i -lt $backslashes; $i++) { [void]$sb.Append('\') }
        $backslashes = 0
        [void]$sb.Append($ch)
    }
    for ($i = 0; $i -lt ($backslashes * 2); $i++) { [void]$sb.Append('\') }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment,
        [int]$TimeoutSeconds = 900
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
        foreach ($arg in $ArgumentList) {
            [void]$psi.ArgumentList.Add([string]$arg)
        }
    } else {
        $quoted = New-Object System.Collections.Generic.List[string]
        foreach ($arg in $ArgumentList) {
            $quoted.Add((ConvertTo-WindowsProcessArgument $arg))
        }
        $psi.Arguments = ($quoted -join ' ')
    }
    if ($Environment) {
        foreach ($key in @($Environment.Keys)) {
            $psi.Environment[[string]$key] = [string]$Environment[$key]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try {
            $process.Kill($true)
        } catch {
            try { $process.Kill() } catch {}
        }
        $process.WaitForExit()
    } else {
        # WaitForExit(int) can return before the async readers finish.
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $code = if ($timedOut) { 124 } else { $process.ExitCode }
    return @{
        ExitCode = $code
        StdOut = [string]$stdout
        StdErr = [string]$stderr
        TimedOut = [bool]$timedOut
    }
}

function Get-CodeSignDisposition {
    param(
        [int]$ExitCode,
        [string]$Output,
        [bool]$SignedFilesPresent,
        [bool]$TimedOut
    )
    if ($TimedOut) { return 'fail' }
    $text = [string]$Output
    if ($text -match '(?i)invalid\s+otp' -or $text -match '(?i)otp\s+is\s+invalid') {
        return 'retry-otp'
    }
    $hasError = $text -match '(?im)(^|\s)Error\s*:' -or $text -match '(?i)(\bException\b|java\.lang\.)'
    $hasSuccess = $text -match '(?i)Code signed successfully'
    if ($ExitCode -eq 0 -and $SignedFilesPresent -and $hasSuccess -and -not $hasError) {
        return 'success'
    }
    return 'fail'
}

function Trim-DiagnosticText {
    param([AllowNull()][string]$Text, [int]$Max = 16384)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return "(truncated to last $Max characters)`n" + $Text.Substring($Text.Length - $Max)
}

function Format-CapturedOutput {
    param(
        $Result,
        [string]$LogText
    )
    $parts = New-Object System.Collections.Generic.List[string]
    if ($Result.TimedOut) {
        $parts.Add('CodeSignTool timed out.')
    }
    # Redact before trimming so a secret that crosses the cut is already gone.
    if (-not [string]::IsNullOrWhiteSpace($Result.StdOut)) {
        $parts.Add("stdout:`n$((Trim-DiagnosticText (Redact-Text $Result.StdOut)).TrimEnd())")
    }
    if (-not [string]::IsNullOrWhiteSpace($Result.StdErr)) {
        $parts.Add("stderr:`n$((Trim-DiagnosticText (Redact-Text $Result.StdErr)).TrimEnd())")
    }
    if (-not [string]::IsNullOrWhiteSpace($LogText)) {
        $parts.Add("log:`n$((Trim-DiagnosticText (Redact-Text $LogText)).TrimEnd())")
    }
    if ($parts.Count -eq 0) {
        return '(no stdout, stderr, or log)'
    }
    return ($parts -join "`n")
}

function Read-CodeSignToolLog {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $logPath = Join-Path (Join-Path $ToolRoot 'logs') 'code_signing_tool.log'
    if (-not (Test-Path -LiteralPath $logPath)) { return '' }
    try {
        return [IO.File]::ReadAllText($logPath)
    } catch {
        return ''
    }
}

function Clear-CodeSignToolLog {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $logDir = Join-Path $ToolRoot 'logs'
    if (Test-Path -LiteralPath $logDir) {
        Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-ExpectedSignedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames
    )
    if ($ExpectedNames.Count -lt 1) { return $false }
    foreach ($name in $ExpectedNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $OutputDir $name) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Format-CodeSignFailure {
    param(
        [string]$Leaf,
        $Result,
        [string]$LogText,
        [bool]$SignedFilesPresent
    )
    $reason = if ($Result.TimedOut) {
        'timed out'
    } elseif (-not $SignedFilesPresent) {
        'did not write a signed copy'
    } else {
        'rejected the signed result'
    }
    $body = Format-CapturedOutput -Result $Result -LogText $LogText
    return "CodeSignTool sign failed for $Leaf ($reason, exit $($Result.ExitCode)).`n$body"
}

function Invoke-CodeSignToolSign {
    param(
        [Parameter(Mandatory = $true)]$Tool,
        [Parameter(Mandatory = $true)][string]$InputFile,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [int]$OtpRetrySeconds = 35,
        [int]$TimeoutSeconds = 900,
        # Tests substitute the process. Production starts the bundled java.
        [scriptblock]$RunProcess
    )
    $ErrorActionPreference = 'Stop'
    $leaf = [IO.Path]::GetFileName($InputFile)
    for ($attempt = 1; $attempt -le $script:OtpAttemptLimit; $attempt++) {
        if (Test-Path -LiteralPath $OutputDir) {
            Remove-Item -LiteralPath $OutputDir -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        Clear-CodeSignToolLog -ToolRoot $Tool.Root

        # sign reads ./conf/code_sign_tool.properties from the process working
        # directory and writes the signed copy under -output_dir_path. Each
        # secret is its own argument so quotes, spaces, and a trailing
        # backslash survive. Stdin is closed so an OTP prompt cannot hang.
        $signArgs = @(
            '-jar', $Tool.Jar,
            'sign',
            "-username=$(Get-SecretValue 'ESIGNER_USERNAME')",
            "-password=$(Get-SecretValue 'ESIGNER_PASSWORD')",
            "-credential_id=$(Get-SecretValue 'ESIGNER_CREDENTIAL_ID')",
            "-totp_secret=$(Get-SecretValue 'ESIGNER_TOTP_SECRET')",
            "-input_file_path=$InputFile",
            "-output_dir_path=$OutputDir"
        )
        if ($null -ne $RunProcess) {
            $result = & $RunProcess $signArgs $Tool.Root
        } else {
            $result = Invoke-CapturedProcess -FileName $Tool.Java -ArgumentList $signArgs -WorkingDirectory $Tool.Root -TimeoutSeconds $TimeoutSeconds
        }
        if ($null -eq $result) { throw 'CodeSignTool process returned no result.' }

        $logText = Read-CodeSignToolLog -ToolRoot $Tool.Root
        $toolText = @($result.StdOut, $result.StdErr, $logText) -join "`n"
        $signedPresent = Test-ExpectedSignedFiles -OutputDir $OutputDir -ExpectedNames @($leaf)
        $disposition = Get-CodeSignDisposition -ExitCode $result.ExitCode -Output $toolText -SignedFilesPresent $signedPresent -TimedOut $result.TimedOut
        if ($disposition -eq 'success') {
            Write-Host "CodeSignTool signed $leaf."
            return (Join-Path $OutputDir $leaf)
        }

        $failure = Redact-Text (Format-CodeSignFailure -Leaf $leaf -Result $result -LogText $logText -SignedFilesPresent $signedPresent)
        if ($disposition -eq 'retry-otp' -and $attempt -lt $script:OtpAttemptLimit) {
            Write-Host "eSigner rejected the one-time password for $leaf (attempt $attempt/$($script:OtpAttemptLimit)). Waiting ${OtpRetrySeconds}s for the next TOTP window."
            Write-Host $failure
            if ($OtpRetrySeconds -gt 0) {
                Start-Sleep -Seconds $OtpRetrySeconds
            }
            continue
        }
        throw $failure
    }
    throw "CodeSignTool sign failed for $leaf."
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

if ($MyInvocation.InvocationName -ne '.') {
$fileMode = @($SignFile).Count -gt 0
if ($fileMode -and -not [string]::IsNullOrWhiteSpace($DistRoot)) {
    throw 'Pass either -DistRoot <zig-out/dist> or -File <exe>, not both.'
}
if (-not $fileMode -and [string]::IsNullOrWhiteSpace($DistRoot)) {
    throw 'DistRoot is required. Pass -DistRoot <zig-out/dist> or -File <exe>.'
}

if (-not $ListOnly) {
    foreach ($name in $script:SecretNames) {
        $null = Get-SecretValue $name
    }
}

if ($fileMode) {
    $targets = @(foreach ($path in $SignFile) {
        $full = Resolve-DistRoot $path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Sign target not found: $full" }
        if ([IO.Path]::GetExtension($full) -notin @('.exe', '.dll')) { throw "Only .exe and .dll files are signed: $full" }
        Get-Item -LiteralPath $full
    })
} else {
    $resolvedRoot = Resolve-DistRoot $DistRoot
    $targets = @(Get-SignTargets -Root $resolvedRoot)
}

$before = @{}
if ($fileMode) {
    foreach ($target in $targets) {
        $before[$target.FullName] = (Get-FileHash -Algorithm SHA256 -LiteralPath $target.FullName).Hash
    }
} else {
    $before = Get-TreeHashes -Root $resolvedRoot
}
$targetPaths = @{}
foreach ($target in $targets) { $targetPaths[$target.FullName] = $true }

# After the bookkeeping above, so -ListOnly (which CI runs without secrets)
# exercises the same target handling as a real signing run.
if ($ListOnly) {
    $targets | Sort-Object FullName | ForEach-Object { Write-Output $_.FullName }
    exit 0
}

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$work = Join-Path $tempRoot ('wispterm-esigner-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'unsigned'
$signed = Join-Path $work 'signed'
$toolDir = Join-Path $tempRoot "CodeSignTool-v$($script:CodeSignToolVersion)"
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    # One sign call per distinct file content: the askpass helper and shell
    # extension are the same bytes in every bundle.
    $groups = [ordered]@{}
    foreach ($target in ($targets | Sort-Object FullName)) {
        $hash = $before[$target.FullName]
        if (-not $groups.Contains($hash)) {
            $groups[$hash] = New-Object System.Collections.Generic.List[string]
        }
        $groups[$hash].Add($target.FullName)
    }

    $tool = Install-CodeSignTool -Destination $toolDir
    Set-CodeSignToolProperty -Path $tool.Properties -Key 'TSA_URL' -Value $script:TimestampUrl
    Set-CodeSignToolProperty -Path $tool.Properties -Key 'TSA_LEGACY_URL' -Value $script:LegacyTimestampUrl
    $configured = [IO.File]::ReadAllText($tool.Properties)
    if ($configured -notmatch '(?m)^TSA_URL=http://ts\.ssl\.com/legacy\s*$') {
        throw 'CodeSignTool TSA_URL is not the SSL.com RFC3161 RSA endpoint http://ts.ssl.com/legacy'
    }

    Write-Host "Signing $($targets.Count) first-party binaries ($($groups.Count) distinct) with CodeSignTool $($script:CodeSignToolVersion) sign"
    $index = 0
    foreach ($hash in @($groups.Keys)) {
        $paths = $groups[$hash]
        $leaf = [IO.Path]::GetFileName($paths[0])
        $inDir = Join-Path $stage ('{0:D3}' -f $index)
        $outDir = Join-Path $signed ('{0:D3}' -f $index)
        $index += 1
        New-Item -ItemType Directory -Force -Path $inDir | Out-Null
        $stagedFile = Join-Path $inDir $leaf
        Copy-Item -LiteralPath $paths[0] -Destination $stagedFile -Force
        $signedFile = Invoke-CodeSignToolSign -Tool $tool -InputFile $stagedFile -OutputDir $outDir -OtpRetrySeconds $script:OtpRetryDelaySeconds -TimeoutSeconds $script:CodeSignTimeoutSeconds
        foreach ($path in $paths) {
            Copy-Item -LiteralPath $signedFile -Destination $path -Force
        }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $toolLogs = Join-Path $toolDir 'logs'
    if (Test-Path -LiteralPath $toolLogs) {
        Remove-Item -LiteralPath $toolLogs -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$after = @{}
if ($fileMode) {
    foreach ($target in $targets) {
        $after[$target.FullName] = (Get-FileHash -Algorithm SHA256 -LiteralPath $target.FullName).Hash
    }
} else {
    $after = Get-TreeHashes -Root $resolvedRoot
}
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

foreach ($target in $targets) {
    Assert-AuthenticodeSigned -Path $target.FullName
}

Write-Host "Authenticode verification passed for $($targets.Count) files. Zip archives were not signed."
}
