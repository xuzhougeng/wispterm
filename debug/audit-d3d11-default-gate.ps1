param(
    [string]$NormalRoot = "",
    [string]$OpenGLRoot = "",
    [string]$EnvironmentRoot = "",
    [string]$MatrixLedger = "",
    [string]$OutDir = "",
    [int]$MinSoakSeconds = 1200,
    [switch]$FailOnIncomplete
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
if ($NormalRoot.Length -eq 0) {
    $NormalRoot = Join-Path $repoRoot "zig-out\d3d11-normal-session-smoke"
}
if ($OpenGLRoot.Length -eq 0) {
    $OpenGLRoot = Join-Path $repoRoot "zig-out\opengl-fallback-session-smoke"
}
if ($EnvironmentRoot.Length -eq 0) {
    $EnvironmentRoot = Join-Path $repoRoot "zig-out\d3d11-env-smoke"
}
if ($OutDir.Length -eq 0) {
    $OutDir = Join-Path $repoRoot ("zig-out\d3d11-default-gate-audit\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

$matrixClasses = @(
    "local-physical",
    "rdp",
    "virtual-machine",
    "hybrid-gpu",
    "weak-integrated-gpu",
    "single-monitor",
    "multi-monitor-same-dpi",
    "multi-monitor-mixed-dpi"
)

function Get-JsonField([object]$Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-True([object]$Value) {
    return ($Value -eq $true)
}

function Test-False([object]$Value) {
    return ($Value -eq $false)
}

function Format-AuditValue([object]$Value) {
    if ($null -eq $Value) {
        return "unknown"
    }
    if ($Value -is [bool]) {
        if ($Value) {
            return "true"
        }
        return "false"
    }
    $text = [string]$Value
    return $text.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
}

function Short-Path([string]$Path) {
    if ($null -eq $Path -or $Path.Length -eq 0) {
        return ""
    }
    if ($Path.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($repoRoot.Length).TrimStart("\", "/")
    }
    return $Path
}

function Read-JsonEntry([string]$Path, [string]$Kind) {
    $file = Get-Item -LiteralPath $Path
    $raw = Get-Content -LiteralPath $file.FullName -Raw
    $json = $raw | ConvertFrom-Json
    return [pscustomobject][ordered]@{
        kind = $Kind
        path = $file.FullName
        name = $file.Name
        last_write_utc = $file.LastWriteTimeUtc.ToString("o")
        json = $json
    }
}

function Read-JsonEntries([string]$Root, [string]$Filter, [string]$Kind) {
    if (!(Test-Path -LiteralPath $Root)) {
        return @()
    }

    $entries = @()
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -Filter $Filter -File)) {
        try {
            $entries += Read-JsonEntry $file.FullName $Kind
        } catch {
            $entries += [pscustomobject][ordered]@{
                kind = $Kind
                path = $file.FullName
                name = $file.Name
                last_write_utc = $file.LastWriteTimeUtc.ToString("o")
                json = $null
                read_error = $_.Exception.Message
            }
        }
    }
    return @($entries)
}

function Select-LatestEvidence([object[]]$Entries, [scriptblock]$Predicate) {
    $matches = @()
    foreach ($entry in $Entries) {
        if ($null -eq (Get-JsonField $entry "json")) {
            continue
        }
        if (& $Predicate $entry) {
            $matches += $entry
        }
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return @($matches | Sort-Object last_write_utc -Descending | Select-Object -First 1)[0]
}

function EvidenceTime([object]$Entry) {
    if ($null -eq $Entry) {
        return $null
    }
    $generated = Get-JsonField $Entry.json "generated_at"
    if ($null -ne $generated) {
        return $generated
    }
    return $Entry.last_write_utc
}

function New-GateRow([string]$Id, [string]$Name, [string]$Status, [object]$Evidence, [string]$Details) {
    return [pscustomobject][ordered]@{
        id = $Id
        name = $Name
        status = $Status
        evidence = if ($null -eq $Evidence) { $null } else { $Evidence.path }
        evidence_time = EvidenceTime $Evidence
        details = $Details
    }
}

function New-EvidenceGate([string]$Id, [string]$Name, [object]$Evidence, [string]$PassDetails, [string]$MissingDetails) {
    if ($null -eq $Evidence) {
        return New-GateRow $Id $Name "missing" $null $MissingDetails
    }
    return New-GateRow $Id $Name "pass" $Evidence $PassDetails
}

function Get-Diagnostics([object]$Entry) {
    return Get-JsonField $Entry.json "diagnostics"
}

function Test-D3D11NormalEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        ((Get-JsonField $json "backend") -eq "d3d11") -and
        (Test-True (Get-JsonField $diag "d3d11_present")) -and
        (Test-True (Get-JsonField $diag "d3d11_init_details")) -and
        (Test-True (Get-JsonField $diag "d3d11_environment")) -and
        (Test-True (Get-JsonField $diag "windows_environment")) -and
        (Test-True (Get-JsonField $diag "d3d11_policy_healthy")) -and
        (Test-True (Get-JsonField $diag "ui_probe_ok")) -and
        (Test-True (Get-JsonField $diag "offscreen_round_trip")) -and
        (Test-False (Get-JsonField $diag "d3d11_recovery_requested")) -and
        (Test-False (Get-JsonField $diag "d3d11_fallback_marker_state")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-RecreateSuccessEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        (Test-True (Get-JsonField $diag "d3d11_recovery_requested")) -and
        (Test-True (Get-JsonField $diag "d3d11_recreate_smoke_requested")) -and
        (Test-True (Get-JsonField $diag "d3d11_recreate_succeeded")) -and
        (Test-True (Get-JsonField $diag "d3d11_resource_restore")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-RecreateFailureEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        ((Get-JsonField $json "mode") -eq "recreate_failure") -and
        ((Get-JsonField $diag "recovery_request_count") -eq 1) -and
        ((Get-JsonField $diag "recreate_attempt_count") -eq 1) -and
        ((Get-JsonField $diag "forced_failure_count") -eq 1) -and
        ((Get-JsonField $diag "escalated_count") -eq 1) -and
        ((Get-JsonField $diag "marker_recorded_count") -eq 1) -and
        ((Get-JsonField $diag "resource_restore_count") -eq 0) -and
        ((Get-JsonField $diag "recreate_success_count") -eq 0) -and
        (Test-True (Get-JsonField $diag "d3d11_fallback_marker_state")) -and
        (Test-False (Get-JsonField $diag "automatic_fallback")) -and
        (Test-True (Get-JsonField $diag "default_unchanged"))
    )
}

function Test-FallbackMarkerEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        (Test-True (Get-JsonField $diag "d3d11_fallback_marker_smoke")) -and
        (Test-True (Get-JsonField $diag "d3d11_fallback_marker_state")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-AutoDryRunEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        (Test-True (Get-JsonField $diag "d3d11_auto_dry_run_smoke")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-RapidResizeEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    $rapid = Get-JsonField $json "rapid_resize"
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        (Test-True (Get-JsonField $rapid "enabled")) -and
        (Test-True (Get-JsonField $rapid "pass")) -and
        (Test-True (Get-JsonField $diag "d3d11_rapid_resize_diagnostics")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-WindowStateEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    $state = Get-JsonField $json "window_state"
    $maximize = Get-JsonField $state "maximize"
    $restore = Get-JsonField $state "restore"
    $minimizeRestore = Get-JsonField $state "minimize_restore"
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        (Test-True (Get-JsonField $state "enabled")) -and
        (Test-True (Get-JsonField $state "pass")) -and
        (Test-True (Get-JsonField $maximize "pass")) -and
        (Test-True (Get-JsonField $restore "pass")) -and
        (Test-True (Get-JsonField $minimizeRestore "pass")) -and
        (Test-True (Get-JsonField $diag "d3d11_window_state_diagnostics")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-FullscreenStartupEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        ((Get-JsonField $json "mode") -eq "fullscreen_startup") -and
        (Test-True (Get-JsonField $diag "d3d11_present")) -and
        (Test-True (Get-JsonField $diag "d3d11_environment")) -and
        (Test-True (Get-JsonField $diag "windows_environment")) -and
        (Test-True (Get-JsonField $diag "d3d11_policy_healthy")) -and
        (Test-True (Get-JsonField $diag "ui_probe_ok")) -and
        (Test-True (Get-JsonField $diag "offscreen_round_trip")) -and
        ((Get-JsonField $diag "d3d11_resize_events") -gt 0) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-SoakEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    $soak = Get-JsonField $json "soak"
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        (Test-True (Get-JsonField $soak "enabled")) -and
        (Test-True (Get-JsonField $soak "pass")) -and
        ((Get-JsonField $soak "duration_seconds") -ge $MinSoakSeconds) -and
        ((Get-JsonField $soak "blank_captures") -eq 0) -and
        (Test-True (Get-JsonField $diag "d3d11_soak_diagnostics")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-OpenGLEvidence([object]$Entry) {
    $json = $Entry.json
    $diag = Get-Diagnostics $Entry
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        ((Get-JsonField $json "backend") -eq "opengl") -and
        (Test-True (Get-JsonField $diag "opengl_backend")) -and
        (Test-True (Get-JsonField $diag "opengl_host_present")) -and
        (Test-True (Get-JsonField $diag "windows_environment")) -and
        (Test-False (Get-JsonField $diag "d3d11_present")) -and
        (Test-False (Get-JsonField $diag "d3d11_recovery_requested")) -and
        (Test-False (Get-JsonField $diag "d3d11_fallback_marker_state")) -and
        (Test-False (Get-JsonField $diag "failure_lines"))
    )
}

function Test-EnvironmentEvidence([object]$Entry) {
    $json = $Entry.json
    $smoke = Get-JsonField $json "smoke"
    $policy = Get-JsonField $json "policy"
    return (
        (Test-True (Get-JsonField $json "pass")) -and
        ((Get-JsonField $json "backend") -eq "d3d11") -and
        (Test-True (Get-JsonField $smoke "d3d11_environment")) -and
        (Test-True (Get-JsonField $smoke "windows_environment")) -and
        (Test-False (Get-JsonField $smoke "failure_lines")) -and
        (Test-False (Get-JsonField $policy "automatic_fallback")) -and
        (Test-False (Get-JsonField $policy "environment_blocking")) -and
        (Test-True (Get-JsonField $policy "default_unchanged"))
    )
}

function Summarize-MatrixLedger([object]$Entry) {
    if ($null -eq $Entry) {
        return [pscustomobject][ordered]@{
            status = "missing"
            details = "matrix-ledger.json not found"
            rows = @()
        }
    }

    $classes = @(Get-JsonField $Entry.json "classes")
    $rows = @()
    foreach ($class in $matrixClasses) {
        $match = @($classes | Where-Object { (Get-JsonField $_ "class") -eq $class } | Select-Object -First 1)
        if ($match.Count -eq 0) {
            $rows += [pscustomobject][ordered]@{ class = $class; status = "missing"; evidence_count = 0 }
        } else {
            $row = $match[0]
            $rows += [pscustomobject][ordered]@{
                class = $class
                status = Get-JsonField $row "status"
                evidence_count = Get-JsonField $row "evidence_count"
                selected_environment_json = Get-JsonField $row "selected_environment_json"
                selected_generated_at = Get-JsonField $row "selected_generated_at"
            }
        }
    }

    $notRecorded = @($rows | Where-Object { $_.status -ne "recorded" })
    if ($notRecorded.Count -eq 0) {
        return [pscustomobject][ordered]@{
            status = "pass"
            details = "all matrix classes are recorded"
            rows = @($rows)
        }
    }

    $parts = @()
    foreach ($status in @("missing", "failing", "mismatch", "operator-review", "recorded-unclassified")) {
        $classesForStatus = @($notRecorded | Where-Object { $_.status -eq $status } | ForEach-Object { $_.class })
        if ($classesForStatus.Count -gt 0) {
            $parts += ("{0}: {1}" -f $status, ($classesForStatus -join ", "))
        }
    }
    return [pscustomobject][ordered]@{
        status = "incomplete"
        details = $parts -join "; "
        rows = @($rows)
    }
}

$normalEntries = @(Read-JsonEntries $NormalRoot "*-normal-session-*.json" "normal-session")
$openglEntries = @(Read-JsonEntries $OpenGLRoot "*-normal-session-*.json" "opengl-normal-session")
$environmentEntries = @(Read-JsonEntries $EnvironmentRoot "environment.json" "environment")
if ($MatrixLedger.Length -gt 0) {
    if (!(Test-Path -LiteralPath $MatrixLedger)) {
        throw "matrix ledger not found: $MatrixLedger"
    }
    $ledgerEntries = @(Read-JsonEntry $MatrixLedger "matrix-ledger")
} else {
    $ledgerEntries = @(Read-JsonEntries $EnvironmentRoot "matrix-ledger.json" "matrix-ledger")
}

$d3d11Normal = Select-LatestEvidence $normalEntries { param($entry) Test-D3D11NormalEvidence $entry }
$recreateSuccess = Select-LatestEvidence $normalEntries { param($entry) Test-RecreateSuccessEvidence $entry }
$recreateFailure = Select-LatestEvidence $normalEntries { param($entry) Test-RecreateFailureEvidence $entry }
$fallbackMarker = Select-LatestEvidence $normalEntries { param($entry) Test-FallbackMarkerEvidence $entry }
$autoDryRun = Select-LatestEvidence $normalEntries { param($entry) Test-AutoDryRunEvidence $entry }
$rapidResize = Select-LatestEvidence $normalEntries { param($entry) Test-RapidResizeEvidence $entry }
$windowState = Select-LatestEvidence $normalEntries { param($entry) Test-WindowStateEvidence $entry }
$fullscreenStartup = Select-LatestEvidence $normalEntries { param($entry) Test-FullscreenStartupEvidence $entry }
$soak = Select-LatestEvidence $normalEntries { param($entry) Test-SoakEvidence $entry }
$openglFallback = Select-LatestEvidence $openglEntries { param($entry) Test-OpenGLEvidence $entry }
$environmentPackage = Select-LatestEvidence $environmentEntries { param($entry) Test-EnvironmentEvidence $entry }
$latestLedger = if ($ledgerEntries.Count -gt 0) { @($ledgerEntries | Sort-Object last_write_utc -Descending | Select-Object -First 1)[0] } else { $null }
$matrixSummary = Summarize-MatrixLedger $latestLedger

$gates = @(
    (New-EvidenceGate "d3d11-normal-session" "D3D11 normal session" $d3d11Normal "healthy D3D11 normal-session artifact found" "no passing D3D11 normal-session artifact with required diagnostics"),
    (New-EvidenceGate "device-recreate-success" "Device recreate success" $recreateSuccess "single-shot recreate/restore artifact found" "no passing -RecreateSmoke artifact"),
    (New-EvidenceGate "device-recreate-failure" "Device recreate failure" $recreateFailure "failed recreate escalated once and wrote marker" "no passing -RecreateFailureSmoke artifact"),
    (New-EvidenceGate "fallback-marker-policy" "Fallback marker policy" $fallbackMarker "fallback marker policy smoke artifact found" "no passing -FallbackMarkerSmoke artifact"),
    (New-EvidenceGate "future-auto-dry-run" "Future-auto dry-run" $autoDryRun "future-auto selector dry-run artifact found" "no passing -AutoDryRunSmoke artifact"),
    (New-EvidenceGate "opengl-fallback" "OpenGL fallback" $openglFallback "OpenGL fallback normal-session artifact found" "no passing -Backend opengl artifact"),
    (New-EvidenceGate "rapid-resize" "Rapid resize" $rapidResize "rapid resize artifact found" "no passing -RapidResizeSmoke artifact"),
    (New-EvidenceGate "window-state" "Window state" $windowState "maximize/restore/minimize artifact found" "no passing -WindowStateSmoke artifact"),
    (New-EvidenceGate "fullscreen-startup" "Fullscreen startup" $fullscreenStartup "fullscreen startup artifact found" "no passing -FullscreenStartupSmoke artifact"),
    (New-EvidenceGate "long-run-soak" "Long-run soak" $soak ("soak artifact found with duration >= {0}s" -f $MinSoakSeconds) ("no passing -SoakMinutes artifact with duration >= {0}s" -f $MinSoakSeconds)),
    (New-EvidenceGate "environment-package" "Environment package" $environmentPackage "environment package artifact found" "no passing environment.json package artifact"),
    (New-GateRow "environment-ledger" "Environment ledger" $matrixSummary.status $latestLedger $matrixSummary.details)
)

$incomplete = @($gates | Where-Object { $_.status -ne "pass" })
$artifactStatus = if ($incomplete.Count -eq 0) { "complete" } else { "incomplete" }
$generatedAt = (Get-Date).ToString("o")

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$auditJsonPath = Join-Path $OutDir "default-gate-audit.json"
$auditMdPath = Join-Path $OutDir "default-gate-audit.md"

$audit = [ordered]@{
    schema = "wispterm-d3d11-default-gate-audit/v1"
    generated_at = $generatedAt
    artifact_status = $artifactStatus
    min_soak_seconds = $MinSoakSeconds
    roots = [ordered]@{
        normal = $NormalRoot
        opengl = $OpenGLRoot
        environment = $EnvironmentRoot
        matrix_ledger = if ($null -eq $latestLedger) { $null } else { $latestLedger.path }
        output = $OutDir
    }
    policy = [ordered]@{
        artifact_only = $true
        does_not_run_smokes = $true
        does_not_infer_build_gates = $true
        does_not_change_default = $true
        automatic_fallback = $false
    }
    counts = [ordered]@{
        normal_session_artifacts = $normalEntries.Count
        opengl_artifacts = $openglEntries.Count
        environment_packages = $environmentEntries.Count
        matrix_ledgers = $ledgerEntries.Count
        passing_gates = @($gates | Where-Object { $_.status -eq "pass" }).Count
        incomplete_gates = $incomplete.Count
    }
    gates = @($gates)
    matrix = [ordered]@{
        status = $matrixSummary.status
        details = $matrixSummary.details
        classes = @($matrixSummary.rows)
    }
}

$audit | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $auditJsonPath -Encoding UTF8

$ledgerPathForMarkdown = if ($null -eq $latestLedger) { "" } else { $latestLedger.path }
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# WispTerm D3D11 Default Gate Artifact Audit") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("Generated at: $generatedAt") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("Artifact status: $artifactStatus") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("This audit reads existing Phase V artifacts only. It does not run smokes, infer build/CI gates, write fallback markers, change renderer selection, or change the Windows default renderer.") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Inputs") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Input | Path |") | Out-Null
$lines.Add("|---|---|") | Out-Null
$lines.Add("| Normal-session root | $(Format-AuditValue (Short-Path $NormalRoot)) |") | Out-Null
$lines.Add("| OpenGL fallback root | $(Format-AuditValue (Short-Path $OpenGLRoot)) |") | Out-Null
$lines.Add("| Environment root | $(Format-AuditValue (Short-Path $EnvironmentRoot)) |") | Out-Null
$lines.Add("| Matrix ledger | $(Format-AuditValue (Short-Path $ledgerPathForMarkdown)) |") | Out-Null
$lines.Add("| Minimum soak seconds | $MinSoakSeconds |") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Gates") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Gate | Status | Evidence | Details |") | Out-Null
$lines.Add("|---|---|---|---|") | Out-Null
foreach ($gate in $gates) {
    $lines.Add("| $(Format-AuditValue $gate.name) | $(Format-AuditValue $gate.status) | $(Format-AuditValue (Short-Path $gate.evidence)) | $(Format-AuditValue $gate.details) |") | Out-Null
}
$lines.Add("") | Out-Null
$lines.Add("## Environment Matrix") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Class | Status | Evidence count | Selected evidence |") | Out-Null
$lines.Add("|---|---|---:|---|") | Out-Null
foreach ($row in $matrixSummary.rows) {
    $lines.Add("| $(Format-AuditValue $row.class) | $(Format-AuditValue $row.status) | $(Format-AuditValue $row.evidence_count) | $(Format-AuditValue (Short-Path $row.selected_environment_json)) |") | Out-Null
}
$lines.Add("") | Out-Null
$lines.Add('Build/test gates remain separate: run `zig build check-sizes`, `zig build test`, `zig build test-full --summary all`, `zig build`, and PR CI before treating Phase V evidence as closeout-ready.') | Out-Null
$lines | Set-Content -LiteralPath $auditMdPath -Encoding UTF8

$summary = [ordered]@{
    artifact_status = $artifactStatus
    incomplete_count = $incomplete.Count
    audit_json = $auditJsonPath
    audit_markdown = $auditMdPath
}
$summary | ConvertTo-Json -Depth 4

if ($FailOnIncomplete -and $artifactStatus -ne "complete") {
    throw "D3D11 default gate artifact audit incomplete: $($incomplete.Count) gate(s) are not passing"
}
