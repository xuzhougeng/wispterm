param(
    [string]$InputRoot = "",
    [string]$OutDir = "",
    [switch]$FailOnMissing
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
if ($InputRoot.Length -eq 0) {
    $InputRoot = Join-Path $repoRoot "zig-out\d3d11-env-smoke"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ($OutDir.Length -eq 0) {
    $OutDir = Join-Path $InputRoot "matrix-ledger-$timestamp"
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

function Format-LedgerValue([object]$Value) {
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

function Short-Commit([object]$Commit) {
    if ($null -eq $Commit) {
        return "unknown"
    }
    $text = [string]$Commit
    if ($text.Length -gt 8) {
        return $text.Substring(0, 8)
    }
    return $text
}

function EvidenceStatus([object]$Entry) {
    if ($Entry.pass -ne $true) {
        return "failing"
    }
    if ($Entry.class_match -eq $true) {
        return "recorded"
    }
    if ($Entry.class_match -eq $false) {
        return "mismatch"
    }
    if ($Entry.class -eq "hybrid-gpu") {
        return "operator-review"
    }
    return "recorded-unclassified"
}

function StatusRank([string]$Status) {
    switch ($Status) {
        "recorded" { return 0 }
        "operator-review" { return 1 }
        "recorded-unclassified" { return 2 }
        "mismatch" { return 3 }
        "failing" { return 4 }
    }
    return 5
}

function Get-CollectionSpec([string]$Class) {
    $requireClassMatch = $true
    $operatorAction = "Run the collector on a machine or session that actually matches this class."
    $note = "Use -RequireMatrixClass so a mismatched run stays visible as non-passing evidence."

    switch ($Class) {
        "local-physical" {
            $operatorAction = "Run on a non-remote physical Windows machine with a non-virtual D3D11 adapter."
        }
        "rdp" {
            $operatorAction = "Run from inside an RDP session."
        }
        "virtual-machine" {
            $operatorAction = "Run inside the target VM and keep the adapter facts if the heuristic does not match."
            $note = "Use -RequireMatrixClass when the VM adapter is expected to be detectable; otherwise rerun without it and review the adapter facts."
        }
        "hybrid-gpu" {
            $requireClassMatch = $false
            $operatorAction = "Run on a hybrid-GPU laptop or workstation and add operator confirmation of the topology in the PR or issue."
            $note = "Hybrid topology cannot be proven from the single DXGI adapter diagnostic, so the ledger reports operator-review until the evidence is explicitly accepted."
        }
        "weak-integrated-gpu" {
            $operatorAction = "Run on an integrated GPU with <= 1 GiB dedicated video memory."
        }
        "single-monitor" {
            $operatorAction = "Run with exactly one active monitor."
        }
        "multi-monitor-same-dpi" {
            $operatorAction = "Run with more than one active monitor and matching DPI values."
        }
        "multi-monitor-mixed-dpi" {
            $operatorAction = "Run with more than one active monitor and mixed DPI values."
        }
    }

    $command = "powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-environment-smoke.ps1 -MatrixClass $Class"
    if ($requireClassMatch) {
        $command += " -RequireMatrixClass"
    }

    return [pscustomobject][ordered]@{
        require_class_match = $requireClassMatch
        command = $command
        operator_action = $operatorAction
        note = $note
    }
}

function Get-CollectionReason([string]$Status) {
    switch ($Status) {
        "missing" { return "No evidence package exists for this class." }
        "operator-review" { return "Evidence exists but still needs explicit operator confirmation or acceptance." }
        "recorded-unclassified" { return "Evidence passed, but class_match is null and does not prove the requested class." }
        "mismatch" { return "Evidence exists, but detected facts contradict the requested class." }
        "failing" { return "Evidence exists, but the smoke failed." }
    }
    return "Status is not recorded."
}

function Add-MarkdownRow([object]$Lines, [object[]]$Values) {
    $cells = @()
    foreach ($value in $Values) {
        $cells += (Format-LedgerValue $value)
    }
    $Lines.Add("| $($cells -join ' | ') |") | Out-Null
}

if (!(Test-Path -LiteralPath $InputRoot)) {
    throw "input root not found: $InputRoot"
}

$jsonFiles = Get-ChildItem -LiteralPath $InputRoot -Recurse -Filter "environment.json" -File
$entries = @()

foreach ($file in $jsonFiles) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw
    $json = $raw | ConvertFrom-Json
    $matrix = Get-JsonField $json "matrix"
    if ($null -eq $matrix) {
        continue
    }

    $environment = Get-JsonField $json "environment"
    $d3d11 = Get-JsonField $environment "d3d11"
    $windows = Get-JsonField $environment "windows"
    $detection = Get-JsonField $matrix "detection"
    $policy = Get-JsonField $json "policy"
    $repo = Get-JsonField $json "repo"
    $artifacts = Get-JsonField $json "artifacts"

    $class = [string](Get-JsonField $matrix "requested_class")
    if ($class.Length -eq 0) {
        $class = "unspecified"
    }

    $entry = [ordered]@{
        class = $class
        status = $null
        pass = [bool](Get-JsonField $json "pass")
        class_match = Get-JsonField $matrix "class_match"
        require_class_match = [bool](Get-JsonField $matrix "require_class_match")
        generated_at = Get-JsonField $json "generated_at"
        branch = Get-JsonField $repo "branch"
        commit = Get-JsonField $repo "commit"
        root = Get-JsonField $artifacts "root"
        environment_json = $file.FullName
        matrix_summary = Get-JsonField $artifacts "matrix_summary"
        normal_session_json = Get-JsonField $artifacts "normal_session_json"
        diagnostic_log = Get-JsonField $artifacts "diagnostic_log"
        adapter_description = Get-JsonField $d3d11 "adapter_description"
        feature_level = Get-JsonField $d3d11 "feature_level"
        dedicated_video_memory = Get-JsonField $d3d11 "dedicated_video_memory"
        output_count = Get-JsonField $d3d11 "output_count"
        remote_session = Get-JsonField $detection "remote_session"
        monitor_count = Get-JsonField $detection "monitor_count"
        mixed_dpi = Get-JsonField $detection "mixed_dpi"
        virtual_machine_candidate = Get-JsonField $detection "virtual_machine_candidate"
        integrated_gpu_candidate = Get-JsonField $detection "integrated_gpu_candidate"
        weak_integrated_gpu_candidate = Get-JsonField $detection "weak_integrated_gpu_candidate"
        environment_blocking = Get-JsonField $policy "environment_blocking"
        automatic_fallback = Get-JsonField $policy "automatic_fallback"
        default_unchanged = Get-JsonField $policy "default_unchanged"
    }
    $entry.status = EvidenceStatus $entry
    $entries += [pscustomobject]$entry
}

$classRows = @()
foreach ($class in $matrixClasses) {
    $candidates = @($entries | Where-Object { $_.class -eq $class } | Sort-Object @{ Expression = { StatusRank $_.status }; Ascending = $true }, @{ Expression = { $_.generated_at }; Descending = $true })
    $best = if ($candidates.Count -gt 0) { $candidates[0] } else { $null }
    $status = if ($null -eq $best) { "missing" } else { $best.status }
    $classRows += [pscustomobject][ordered]@{
        class = $class
        status = $status
        evidence_count = $candidates.Count
        selected_environment_json = if ($null -eq $best) { $null } else { $best.environment_json }
        selected_matrix_summary = if ($null -eq $best) { $null } else { $best.matrix_summary }
        selected_commit = if ($null -eq $best) { $null } else { $best.commit }
        selected_generated_at = if ($null -eq $best) { $null } else { $best.generated_at }
        selected_class_match = if ($null -eq $best) { $null } else { $best.class_match }
        selected_pass = if ($null -eq $best) { $null } else { $best.pass }
        selected_adapter = if ($null -eq $best) { $null } else { $best.adapter_description }
        selected_monitor_count = if ($null -eq $best) { $null } else { $best.monitor_count }
        selected_mixed_dpi = if ($null -eq $best) { $null } else { $best.mixed_dpi }
    }
}

$missing = @($classRows | Where-Object { $_.status -eq "missing" })
$generatedAt = (Get-Date).ToString("o")
$ledger = [ordered]@{
    schema = "wispterm-d3d11-environment-matrix-ledger/v1"
    generated_at = $generatedAt
    input_root = $InputRoot
    evidence_count = $entries.Count
    missing_count = $missing.Count
    policy = [ordered]@{
        record_only = $true
        environment_blocking = $false
        automatic_fallback = $false
        default_unchanged = $true
    }
    classes = @($classRows)
    evidence = @($entries)
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ledgerJsonPath = Join-Path $OutDir "matrix-ledger.json"
$ledgerMdPath = Join-Path $OutDir "matrix-ledger.md"
$collectionPlanJsonPath = Join-Path $OutDir "matrix-collection-plan.json"
$collectionPlanMdPath = Join-Path $OutDir "matrix-collection-plan.md"
$ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ledgerJsonPath -Encoding UTF8

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# WispTerm D3D11 Environment Matrix Ledger") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("Generated at: $generatedAt") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("Input root: $InputRoot") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("This ledger aggregates record-only Phase V evidence packages. It does not imply environment blocking, fallback-marker writes, or a Windows default renderer change.") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("## Matrix Status") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Class | Status | Evidence | Commit | Generated | Class match | Pass | Adapter | Monitors | Mixed DPI | Summary |") | Out-Null
$lines.Add("|---|---|---:|---|---|---|---|---|---:|---|---|") | Out-Null
foreach ($row in $classRows) {
    Add-MarkdownRow $lines @(
        $row.class,
        $row.status,
        $row.evidence_count,
        (Short-Commit $row.selected_commit),
        $row.selected_generated_at,
        $row.selected_class_match,
        $row.selected_pass,
        $row.selected_adapter,
        $row.selected_monitor_count,
        $row.selected_mixed_dpi,
        $row.selected_matrix_summary
    )
}

$lines.Add("") | Out-Null
$lines.Add("## All Evidence Packages") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Class | Status | Pass | Class match | Generated | Commit | Adapter | Monitors | Mixed DPI | Environment JSON |") | Out-Null
$lines.Add("|---|---|---|---|---|---|---|---:|---|---|") | Out-Null
foreach ($entry in ($entries | Sort-Object generated_at)) {
    Add-MarkdownRow $lines @(
        $entry.class,
        $entry.status,
        $entry.pass,
        $entry.class_match,
        $entry.generated_at,
        (Short-Commit $entry.commit),
        $entry.adapter_description,
        $entry.monitor_count,
        $entry.mixed_dpi,
        $entry.environment_json
    )
}

if ($missing.Count -gt 0) {
    $lines.Add("") | Out-Null
    $lines.Add("## Missing Classes") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($row in $missing) {
        $lines.Add("- $($row.class)") | Out-Null
    }
}

$lines | Set-Content -LiteralPath $ledgerMdPath -Encoding UTF8

$outstandingRows = @($classRows | Where-Object { $_.status -ne "recorded" })
$collectionItems = @()
foreach ($row in $outstandingRows) {
    $spec = Get-CollectionSpec $row.class
    $collectionItems += [pscustomobject][ordered]@{
        class = $row.class
        current_status = $row.status
        reason = Get-CollectionReason $row.status
        evidence_count = $row.evidence_count
        selected_environment_json = $row.selected_environment_json
        require_class_match = $spec.require_class_match
        command = $spec.command
        operator_action = $spec.operator_action
        note = $spec.note
    }
}

$collectionPlan = [ordered]@{
    schema = "wispterm-d3d11-environment-collection-plan/v1"
    generated_at = $generatedAt
    input_root = $InputRoot
    ledger_json = $ledgerJsonPath
    ledger_markdown = $ledgerMdPath
    outstanding_count = $collectionItems.Count
    policy = [ordered]@{
        record_only = $true
        does_not_create_evidence = $true
        does_not_accept_missing_classes = $true
        default_unchanged = $true
    }
    items = @($collectionItems)
}
$collectionPlan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $collectionPlanJsonPath -Encoding UTF8

$planLines = [System.Collections.Generic.List[string]]::new()
$planLines.Add("# WispTerm D3D11 Environment Collection Plan") | Out-Null
$planLines.Add("") | Out-Null
$planLines.Add("Generated at: $generatedAt") | Out-Null
$planLines.Add("") | Out-Null
$planLines.Add("Input root: $InputRoot") | Out-Null
$planLines.Add("") | Out-Null
$planLines.Add("This plan is derived from the current matrix ledger. It does not create evidence, accept missing classes, block environments, or change the Windows default renderer.") | Out-Null
$planLines.Add("") | Out-Null
$planLines.Add("Build the D3D11 executable before running any collector command:") | Out-Null
$planLines.Add("") | Out-Null
$planLines.Add('```powershell') | Out-Null
$planLines.Add("zig build -Dgpu-backend=d3d11") | Out-Null
$planLines.Add('```') | Out-Null
$planLines.Add("") | Out-Null
if ($collectionItems.Count -eq 0) {
    $planLines.Add("All matrix classes are recorded in the current ledger.") | Out-Null
} else {
    $planLines.Add("## Outstanding Classes") | Out-Null
    $planLines.Add("") | Out-Null
    $planLines.Add("| Class | Current status | Reason | Evidence | Require match | Collector command | Operator action | Note |") | Out-Null
    $planLines.Add("|---|---|---|---:|---|---|---|---|") | Out-Null
    foreach ($item in $collectionItems) {
        Add-MarkdownRow $planLines @(
            $item.class,
            $item.current_status,
            $item.reason,
            $item.evidence_count,
            $item.require_class_match,
            $item.command,
            $item.operator_action,
            $item.note
        )
    }
}
$planLines | Set-Content -LiteralPath $collectionPlanMdPath -Encoding UTF8

$summary = [ordered]@{
    evidence_count = $entries.Count
    missing_count = $missing.Count
    outstanding_count = $collectionItems.Count
    ledger_json = $ledgerJsonPath
    ledger_markdown = $ledgerMdPath
    collection_plan_json = $collectionPlanJsonPath
    collection_plan_markdown = $collectionPlanMdPath
}
$summary | ConvertTo-Json -Depth 4

if ($FailOnMissing -and $missing.Count -gt 0) {
    throw "missing matrix evidence classes: $((@($missing | ForEach-Object { $_.class })) -join ', ')"
}
