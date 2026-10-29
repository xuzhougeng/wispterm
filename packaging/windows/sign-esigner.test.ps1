# Failure detection for packaging/windows/sign-esigner.ps1.
# CodeSignTool 1.3.2 exits 0 on Error: / invalid OTP. These tests run the
# classifier and a stand-in process; they do not call SSL.com.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptPath = Join-Path $PSScriptRoot 'sign-esigner.ps1'
. $scriptPath

$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) {
        $script:failures.Add($Label)
        Write-Host "FAIL $Label"
    } else {
        Write-Host "ok $Label"
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        $script:failures.Add("$Label expected [$Expected] actual [$Actual]")
        Write-Host "FAIL $Label expected [$Expected] actual [$Actual]"
    } else {
        Write-Host "ok $Label"
    }
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Label,
        [string[]]$Secrets = @()
    )
    $leaked = $false
    foreach ($secret in $Secrets) {
        if (-not [string]::IsNullOrEmpty($secret) -and $Text.Contains($secret)) {
            $leaked = $true
        }
    }
    if ($leaked -or -not $Text.Contains($Needle)) {
        $script:failures.Add($Label)
        Write-Host "FAIL $Label"
    } else {
        Write-Host "ok $Label"
    }
}

function Assert-SecretHidden {
    param([string]$Text, [string[]]$Secrets, [string]$Label)
    foreach ($secret in $Secrets) {
        if (-not [string]::IsNullOrEmpty($secret) -and $Text.Contains($secret)) {
            $script:failures.Add("$Label leaked a secret")
            Write-Host "FAIL $Label leaked a secret"
            return
        }
    }
    Write-Host "ok $Label"
}

$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath), [ref]$null, [ref]$parseErrors)
Assert-True ($null -eq $parseErrors -or $parseErrors.Count -eq 0) 'signer script parses'
Assert-Equal $script:OtpRetryDelaySeconds 35 'otp retry waits past one TOTP window'
Assert-Equal $script:OtpAttemptLimit 4 'invalid otp is tried four times'

Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output 'Error: The provided authorization grant is invalid, expired, revoked' -SignedFilesPresent $false -TimedOut $false) 'fail' 'exit 0 plus Error is failure'
Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output 'Error: invalid otp' -SignedFilesPresent $false -TimedOut $false) 'retry-otp' 'invalid otp retries when exit code is 0'
Assert-Equal (Get-CodeSignDisposition -ExitCode 1 -Output 'Error: The OTP is invalid.' -SignedFilesPresent $false -TimedOut $false) 'retry-otp' 'OTP is invalid retries'
Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output 'Code signed successfully: wispterm.exe' -SignedFilesPresent $true -TimedOut $false) 'success' 'success marker and files is success'
Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output 'Code signed successfully: wispterm.exe' -SignedFilesPresent $false -TimedOut $false) 'fail' 'success marker without files is failure'
Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output 'java.lang.IllegalArgumentException: Illegal base64 character' -SignedFilesPresent $false -TimedOut $false) 'fail' 'exception text is failure'
Assert-Equal (Get-CodeSignDisposition -ExitCode 3 -Output 'Code signed successfully: wispterm.exe' -SignedFilesPresent $true -TimedOut $false) 'fail' 'non-zero exit is failure'
Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output "WARNING: sun.reflect.Reflection.getCallerClass is not supported.`nCode signed successfully: wispterm.exe" -SignedFilesPresent $true -TimedOut $false) 'success' 'JVM warning does not hide success'
Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output 'Error: invalid otp' -SignedFilesPresent $false -TimedOut $true) 'fail' 'timeout is not an otp retry'
Assert-Equal (Get-CodeSignDisposition -ExitCode 0 -Output "Error: bad credential`nCode signed successfully: wispterm.exe" -SignedFilesPresent $true -TimedOut $false) 'fail' 'Error: wins over the success marker'

$formatted = Format-CodeSignFailure -Result @{ ExitCode = 0; StdOut = 'Error: nope'; StdErr = 'err-marker'; TimedOut = $false } -LogText 'log-marker' -SignedFilesPresent $false
Assert-Contains $formatted 'did not write a signed copy' 'missing file names the useless failure mode'
Assert-Contains $formatted 'exit 0' 'missing file keeps the exit code'
Assert-Contains $formatted 'Error: nope' 'missing file includes stdout'
Assert-Contains $formatted 'err-marker' 'missing file includes stderr'
Assert-Contains $formatted 'log-marker' 'missing file includes the tool log'
$timedOut = Format-CodeSignFailure -Result @{ ExitCode = 124; StdOut = ''; StdErr = ''; TimedOut = $true } -LogText '' -SignedFilesPresent $false
Assert-Contains $timedOut 'timed out' 'timeout is the failure reason'
$empty = Format-CodeSignFailure -Result @{ ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false } -LogText '' -SignedFilesPresent $false
Assert-Contains $empty '(no stdout, stderr, or log)' 'empty capture says so'

$long = ('x' * 17000) + 'Error: tail-marker'
Assert-Contains (Trim-DiagnosticText $long) 'Error: tail-marker' 'diagnostic trim keeps the tail'
Assert-Contains (Trim-DiagnosticText $long) 'truncated' 'diagnostic trim says it truncated'

Assert-Equal (ConvertTo-WindowsProcessArgument '-jar') '-jar' 'simple arguments stay unquoted'
Assert-Equal (ConvertTo-WindowsProcessArgument '') '""' 'empty arguments are quoted'
Assert-Equal (ConvertTo-WindowsProcessArgument 'P!@^^ss word"12\') '"P!@^^ss word\"12\\"' 'Windows quoting keeps password punctuation'

$python = $null
$pythonLead = @()
foreach ($name in @('python3', 'python')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch 'WindowsApps') {
        $python = $cmd.Source
        break
    }
}
if (-not $python) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py -and $py.Source -notmatch 'WindowsApps') {
        $python = $py.Source
        $pythonLead = @('-3')
    }
}
if (-not $python) { throw 'python3 is required to test CodeSignTool failure detection.' }

function Invoke-Python {
    param([string[]]$ArgumentList, [int]$TimeoutSeconds = 30)
    return Invoke-CapturedProcess -FileName $python -ArgumentList ($pythonLead + $ArgumentList) -TimeoutSeconds $TimeoutSeconds
}

$capture = Invoke-Python -ArgumentList @(
    '-c',
    'import sys; sys.stdout.write("out-line\n"); sys.stderr.write("err-line\n"); raise SystemExit(7)'
) -TimeoutSeconds 30
Assert-Equal $capture.ExitCode 7 'captured process keeps the native exit code'
Assert-True ($capture.StdOut.Contains('out-line') -and $capture.StdErr.Contains('err-line')) 'captured process keeps stdout and stderr'

$secretArg = 'P!@^^ss word"12\'
$quoted = Invoke-Python -ArgumentList @(
    '-c',
    'import sys; sys.stdout.write(sys.argv[1])',
    $secretArg
) -TimeoutSeconds 30
Assert-Equal $quoted.StdOut $secretArg 'process arguments keep password punctuation'
Assert-Equal $quoted.ExitCode 0 'password argument process exits 0'

$stdin = Invoke-Python -ArgumentList @(
    '-c',
    'import sys; data = sys.stdin.read(); sys.stdout.write("stdin-bytes=%d" % len(data))'
) -TimeoutSeconds 30
Assert-Equal $stdin.StdOut 'stdin-bytes=0' 'stdin is closed so an OTP prompt cannot hang'
Assert-Equal $stdin.ExitCode 0 'closed stdin is EOF'

$timeout = Invoke-Python -ArgumentList @('-c', 'import time; time.sleep(30)') -TimeoutSeconds 1
Assert-True ($timeout.TimedOut -and $timeout.ExitCode -eq 124) 'process timeout is reported'

$pwsh = (Get-Process -Id $PID).Path
function Invoke-Signer {
    param([string[]]$ArgumentList, [hashtable]$Environment)
    return Invoke-CapturedProcess -FileName $pwsh -ArgumentList (@('-NoProfile', '-File', $scriptPath) + $ArgumentList) -Environment $Environment -TimeoutSeconds 60
}

$emptySecrets = @{
    ESIGNER_CREDENTIAL_ID = ''
    ESIGNER_USERNAME = ''
    ESIGNER_PASSWORD = ''
    ESIGNER_TOTP_SECRET = ''
    ESIGNER_PIN = ''
}
$missingRoot = Invoke-Signer -ArgumentList @() -Environment $emptySecrets
Assert-Equal $missingRoot.ExitCode 1 'missing DistRoot fails the script'
Assert-Contains ($missingRoot.StdOut + $missingRoot.StdErr) 'DistRoot is required' 'missing DistRoot names the parameter'

$dist = Join-Path ([IO.Path]::GetTempPath()) ('wispterm-dist-' + [guid]::NewGuid().ToString('n'))
$bundleNames = @('portable', 'portable-compat', 'portable-opengl', 'portable-debug')
$signNames = @('wispterm.exe', 'wispterm-ssh-askpass.exe', 'wispterm-ssh-proxy.exe', 'wispterm-shell-extension.dll')
foreach ($bundle in $bundleNames) {
    $bundleRoot = Join-Path $dist $bundle
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    foreach ($name in $signNames) {
        Set-Content -Path (Join-Path $bundleRoot $name) -Value 'unsigned' -Encoding ascii
    }
    Set-Content -Path (Join-Path $bundleRoot 'WebView2Loader.dll') -Value 'microsoft' -Encoding ascii
    Set-Content -Path (Join-Path $bundleRoot 'skip-me.exe') -Value 'nope' -Encoding ascii
    Set-Content -Path (Join-Path $bundleRoot 'bundle.zip') -Value 'zip' -Encoding ascii
}

$listed = Invoke-Signer -ArgumentList @('-DistRoot', $dist, '-ListOnly') -Environment $emptySecrets
Assert-Equal $listed.ExitCode 0 'ListOnly exits 0 without eSigner secrets'
$listText = $listed.StdOut
foreach ($name in $signNames) {
    $hits = @([regex]::Matches($listText, [regex]::Escape($name))).Count
    Assert-Equal $hits 4 "ListOnly emits $name once per bundle"
}
Assert-True ((-not $listText.Contains('WebView2Loader.dll')) -and (-not $listText.Contains('skip-me.exe')) -and (-not $listText.Contains('bundle.zip'))) 'ListOnly skips archives and third-party binaries'

$required = Invoke-Signer -ArgumentList @('-DistRoot', $dist, '-Require') -Environment $emptySecrets
Assert-Equal $required.ExitCode 1 'tag signing still requires every eSigner secret'
Assert-Contains ($required.StdOut + $required.StdErr) 'ESIGNER_CREDENTIAL_ID' 'missing secret failure names the secret'

$setupExe = Join-Path $dist 'wispterm-windows-setup-v0.0.0.exe'
Set-Content -Path $setupExe -Value 'installer' -Encoding ascii
$fileListed = Invoke-Signer -ArgumentList @('-File', $setupExe, '-ListOnly') -Environment $emptySecrets
Assert-Equal $fileListed.ExitCode 0 'File mode ListOnly exits 0 without eSigner secrets'
Assert-Contains $fileListed.StdOut 'wispterm-windows-setup-v0.0.0.exe' 'File mode lists the setup exe'
$fileRequired = Invoke-Signer -ArgumentList @('-File', $setupExe, '-Require') -Environment $emptySecrets
Assert-Equal $fileRequired.ExitCode 1 'File mode still requires every eSigner secret'
$bothModes = Invoke-Signer -ArgumentList @('-File', $setupExe, '-DistRoot', $dist, '-ListOnly') -Environment $emptySecrets
Assert-Equal $bothModes.ExitCode 1 'DistRoot and File together are refused'
$missingFile = Invoke-Signer -ArgumentList @('-File', (Join-Path $dist 'absent.exe'), '-ListOnly') -Environment $emptySecrets
Assert-Equal $missingFile.ExitCode 1 'a missing File target fails'
Assert-Contains ($missingFile.StdOut + $missingFile.StdErr) 'Sign target not found' 'a missing File target is named'

$script:samplePassword = 'P!@^^ss word"12\'
$script:sampleUser = 'signer-user'
$script:sampleCred = 'cred-id-9f3a'
$script:sampleTotp = 'TOTP-SECRET-VALUE-not-real'
$script:samplePin = '9876'
$sampleSecrets = @(
    $script:samplePassword,
    $script:sampleUser,
    $script:sampleCred,
    $script:sampleTotp,
    $script:samplePin
)

$savedSecrets = @{}
foreach ($name in $script:SecretNames) {
    $savedSecrets[$name] = [Environment]::GetEnvironmentVariable($name)
}
[Environment]::SetEnvironmentVariable('ESIGNER_USERNAME', 'user')
[Environment]::SetEnvironmentVariable('ESIGNER_PASSWORD', 'user-password-value')
$redacted = Redact-Text 'user-password-value and user'
Assert-True ((-not $redacted.Contains('user-password-value')) -and $redacted.Contains('[ESIGNER_PASSWORD]') -and $redacted.Contains('[ESIGNER_USERNAME]')) 'longer secrets are redacted before shorter ones'
[Environment]::SetEnvironmentVariable('ESIGNER_PIN', $script:samplePin)
$pinText = Redact-Text 'pin 9876 and token 98761'
Assert-True ($pinText.Contains('[ESIGNER_PIN]') -and $pinText.Contains('98761')) 'pin redaction keeps a longer token'

function Set-SampleSecrets {
    [Environment]::SetEnvironmentVariable('ESIGNER_USERNAME', $script:sampleUser)
    [Environment]::SetEnvironmentVariable('ESIGNER_PASSWORD', $script:samplePassword)
    [Environment]::SetEnvironmentVariable('ESIGNER_CREDENTIAL_ID', $script:sampleCred)
    [Environment]::SetEnvironmentVariable('ESIGNER_TOTP_SECRET', $script:sampleTotp)
    [Environment]::SetEnvironmentVariable('ESIGNER_PIN', $script:samplePin)
}
Set-SampleSecrets

$toolRoot = Join-Path ([IO.Path]::GetTempPath()) ('wispterm-cst-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
$countPath = Join-Path $toolRoot 'count.txt'
$inputDir = Join-Path $toolRoot 'unsigned'
$outputDir = Join-Path $toolRoot 'signed'
New-Item -ItemType Directory -Path $inputDir -Force | Out-Null
$tool = @{
    Java = $python
    Jar = (Join-Path $toolRoot 'code_sign_tool-1.3.2.jar')
    Root = $toolRoot
}
$script:fakeMode = 'auth-error'
$script:passwordArgOk = $false
$script:pinPassed = $false

$run = {
    param($ArgumentList, $WorkingDirectory)
    $path = Join-Path $WorkingDirectory 'count.txt'
    $count = 0
    if (Test-Path -LiteralPath $path) {
        $count = [int]([IO.File]::ReadAllText($path).Trim())
    }
    $count++
    [IO.File]::WriteAllText($path, [string]$count)
    $logDir = Join-Path $WorkingDirectory 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $password = ''
    $signedDir = ''
    foreach ($arg in $ArgumentList) {
        if ($arg.StartsWith('-password=')) { $password = $arg.Substring('-password='.Length) }
        if ($arg.StartsWith('-output_dir_path=')) { $signedDir = $arg.Substring('-output_dir_path='.Length) }
        if ($arg.StartsWith('-pin=')) { $script:pinPassed = $true }
    }
    if ($password -eq $script:samplePassword) { $script:passwordArgOk = $true }
    $cred = [Environment]::GetEnvironmentVariable('ESIGNER_CREDENTIAL_ID')
    $log = "Credential ID in input parameter: $cred`ndetail: signing attempt $count`n"
    [IO.File]::WriteAllText((Join-Path $logDir 'code_signing_tool.log'), $log)
    if ($script:fakeMode -eq 'auth-error') {
        return @{
            ExitCode = 0
            StdOut = "Error: authorization grant is invalid for $password"
            StdErr = 'stderr-marker'
            TimedOut = $false
        }
    }
    if ($script:fakeMode -eq 'invalid-otp') {
        return @{
            ExitCode = 0
            StdOut = 'Error: invalid otp'
            StdErr = ''
            TimedOut = $false
        }
    }
    if ($script:fakeMode -eq 'scan-required') {
        return @{
            ExitCode = 0
            StdOut = 'Error: hash needs to be scanned first before submitting for signing: abc='
            StdErr = ''
            TimedOut = $false
        }
    }
    if ($script:fakeMode -eq 'success') {
        if ($ArgumentList -contains 'sign') { $script:usedSign = $true }
        New-Item -ItemType Directory -Path $signedDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $signedDir 'wispterm.exe'), 'signed-bytes')
        return @{
            ExitCode = 0
            StdOut = 'Code signed successfully: wispterm.exe'
            StdErr = ''
            TimedOut = $false
        }
    }
    return @{
        ExitCode = 0
        StdOut = ''
        StdErr = 'java.lang.IllegalStateException: unexpected mode'
        TimedOut = $false
    }
}

$inputFile = Join-Path $inputDir 'wispterm.exe'
Set-Content -Path $inputFile -Value 'unsigned' -Encoding ascii
$script:usedSign = $false

function Invoke-FakeSign {
    [IO.File]::WriteAllText($countPath, '0')
    Invoke-CodeSignToolSign -Tool $tool -InputFile $inputFile -OutputDir $outputDir -OtpRetrySeconds 0 -TimeoutSeconds 30 -RunProcess $run
}

$script:fakeMode = 'auth-error'
$authMessage = ''
try {
    Invoke-FakeSign
    $authMessage = 'expected auth failure'
} catch {
    $authMessage = [string]$_.Exception.Message
}
Assert-Contains $authMessage 'exit 0' 'exit 0 auth failure keeps the exit code' $sampleSecrets
Assert-Contains $authMessage 'did not write a signed copy' 'exit 0 auth failure says the file is missing' $sampleSecrets
Assert-Contains $authMessage 'Error: authorization grant is invalid' 'exit 0 auth failure includes the CodeSignTool error' $sampleSecrets
Assert-Contains $authMessage 'stderr-marker' 'exit 0 auth failure includes stderr' $sampleSecrets
Assert-Contains $authMessage 'detail: signing attempt' 'exit 0 auth failure includes the tool log' $sampleSecrets
Assert-Contains $authMessage '[ESIGNER_PASSWORD]' 'exit 0 auth failure redacts the password' $sampleSecrets
Assert-Contains $authMessage '[ESIGNER_CREDENTIAL_ID]' 'exit 0 auth failure redacts the credential id' $sampleSecrets
Assert-SecretHidden $authMessage $sampleSecrets 'auth failure output hides secrets'
Assert-True $script:passwordArgOk 'password is passed as one argument'
Assert-True (-not $script:pinPassed) 'pin stays off the sign command line'
Assert-Equal ([IO.File]::ReadAllText($countPath).Trim()) '1' 'auth failure does not retry'

$script:fakeMode = 'invalid-otp'
$otpStarted = [Diagnostics.Stopwatch]::StartNew()
$otpMessage = ''
try {
    Invoke-FakeSign
    $otpMessage = 'expected otp failure'
} catch {
    $otpMessage = [string]$_.Exception.Message
}
$otpStarted.Stop()
Assert-Equal ([IO.File]::ReadAllText($countPath).Trim()) '4' 'invalid otp retries four times when the tool exits 0'
Assert-Contains $otpMessage 'Error: invalid otp' 'final otp failure includes the tool error' $sampleSecrets
Assert-SecretHidden $otpMessage $sampleSecrets 'otp failure output hides secrets'
Assert-True ($otpStarted.Elapsed.TotalSeconds -lt 5) 'tests do not wait out the TOTP window'

$script:fakeMode = 'scan-required'
$scanMessage = ''
try {
    Invoke-FakeSign
    $scanMessage = 'expected scan failure'
} catch {
    $scanMessage = [string]$_.Exception.Message
}
Assert-Contains $scanMessage 'hash needs to be scanned first' 'malware-blocker rejection fails with the tool error' $sampleSecrets
Assert-Equal ([IO.File]::ReadAllText($countPath).Trim()) '1' 'malware-blocker rejection does not retry'

$script:fakeMode = 'success'
$signedPath = Invoke-FakeSign
Assert-Equal $signedPath (Join-Path $outputDir 'wispterm.exe') 'success returns the signed copy path'
Assert-Equal ([IO.File]::ReadAllText($signedPath)) 'signed-bytes' 'success leaves the signed file in place'
Assert-Equal ([IO.File]::ReadAllText($countPath).Trim()) '1' 'success does not retry'
Assert-True $script:usedSign 'signing uses the per-file sign command'

foreach ($name in $script:SecretNames) {
    [Environment]::SetEnvironmentVariable($name, $savedSecrets[$name])
}
$cleanupBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
foreach ($cleanupPath in @($dist, $toolRoot)) {
    $cleanupFull = [IO.Path]::GetFullPath($cleanupPath)
    if (-not $cleanupFull.StartsWith($cleanupBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing cleanup outside the test temporary root: $cleanupFull"
    }
}
Remove-Item -LiteralPath $dist, $toolRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) assertion(s) failed."
    exit 1
}
Write-Host 'sign-esigner tests passed'
