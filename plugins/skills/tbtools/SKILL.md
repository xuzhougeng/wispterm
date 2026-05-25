---
name: tbtools
description: Use when the user asks about TBtools, TBtools-II, TBtools RPC API, TBtools CLI, or bioinformatics operations available through TBtools such as sequence manipulation, BLAST, GFF/GTF/GXF processing, expression tables, heatmaps, trees, MCScanX, DIAMOND, HMMER, MUSCLE, and IQ-TREE.
---

# TBtools

## Overview

TBtools-II is a Java-based bioinformatics toolkit. In this environment, assume the user is working from Windows PowerShell and prefer TBtools' own bundled Java/RPC/CLI tools. Do not introduce Python, R, Conda, or other dependencies unless the user explicitly asks.

Default install path is `C:\Program Files\TBtools`, but first honor `TBTOOLS_HOME` or `TBTOOLS_JAR` if present.

## PowerShell Setup

```powershell
$TbtoolsHome = if ($env:TBTOOLS_HOME) { $env:TBTOOLS_HOME } else { "C:\Program Files\TBtools" }
$TbtoolsJar = if ($env:TBTOOLS_JAR) { $env:TBTOOLS_JAR } else { Join-Path $TbtoolsHome "TBtools_JRE1.6.jar" }
$env:Path = "$(Join-Path $TbtoolsHome 'bin');$env:Path"

Test-Path $TbtoolsJar
java -version
```

Use `bin\` tools directly when the task is a standard external tool workflow:

```powershell
blastn -query query.fa -db db_prefix -out results.tsv -outfmt 6
muscle -in input.fa -out aligned.fa
iqtree -s aligned.fa -m MFP -bb 1000 -nt AUTO
diamond blastp -d proteins.dmnd -q query.fa -o matches.tsv
```

## RPC Server

Start the headless RPC server from PowerShell:

```powershell
.\scripts\start_rpc_server.ps1 -Background
```

Direct form:

```powershell
java -cp $TbtoolsJar biocjava.rpc.RpcServer
```

Default URLs:

| Purpose | URL |
| --- | --- |
| Health check | `http://127.0.0.1:8765/health` |
| JSON-RPC | `http://127.0.0.1:8765/rpc` |

`rpcPort` is configurable in TBtools config. `rpcBindAddress` is normalized to loopback only (`127.0.0.1` or `::1`); do not expose the RPC server on `0.0.0.0`.

## PowerShell RPC Helper

Use this helper in the current PowerShell session. It uses only built-in PowerShell HTTP and JSON support.

```powershell
function Invoke-TBtoolsRpc {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [hashtable]$Params = @{},
        [string]$Uri = "http://127.0.0.1:8765/rpc",
        [int]$TimeoutSec = 600
    )

    $body = @{
        jsonrpc = "2.0"
        method = $Method
        params = $Params
        id = [guid]::NewGuid().ToString()
    } | ConvertTo-Json -Depth 50

    $response = Invoke-RestMethod -Method Post -Uri $Uri -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec
    if ($null -ne $response.error) {
        $reason = if ($response.error.data -and $response.error.data.reason) { " ($($response.error.data.reason))" } else { "" }
        throw "TBtools RPC error $($response.error.code): $($response.error.message)$reason"
    }
    return $response.result
}
```

Discovery:

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8765/health
Invoke-TBtoolsRpc -Method system.ping
$methods = (Invoke-TBtoolsRpc -Method system.listMethods).methods
$methods | Where-Object { $_ -like "*Fasta*" }
Invoke-TBtoolsRpc -Method system.describeMethod -Params @{ method = "FastaStat.process" }
Invoke-TBtoolsRpc -Method system.toolsJson
```

## RPC Workflow

1. Create deterministic workspace folders and pass absolute host-local file paths. RPC bodies carry paths, not file content.
2. Call `system.listMethods` and `system.describeMethod` for candidate methods. Use `system.toolsJson` when many method schemas are needed.
3. Prefer a matching `*.validateParams` or `*.validateInput` before `*.process` when available.
4. Treat validation failures carefully: validate methods may return `result.ok = false` / `validated = false` with structured errors instead of a JSON-RPC `error`.
5. For long BLAST, tree, heatmap, NCBI, or large file jobs, raise client timeout and reduce concurrency.
6. If JSON-RPC error `-32603` has `error.data.reason = rpc pool busy`, back off and retry with lower concurrency.

## RPC Protocol Notes

| Topic | Contract |
| --- | --- |
| Request | HTTP `POST /rpc`, JSON-RPC 2.0 object with `method`, `params`, `id` |
| Batch | JSON array of request objects; response array is in order and omits notifications |
| Empty batch | HTTP 200 with body `[]` |
| Health | `GET /health` returns HTTP 200 body `OK` |
| Success | `result` object, usually at least `ok: true` |
| Errors | HTTP 200 with `error.code`, `error.message`, optional `error.data` |

Common error codes: `-32700` parse error, `-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal error, `-32000` timeout.

## Common RPC Methods

| Area | Methods |
| --- | --- |
| Sequence files | `FastaStat.process`, `FastaSeqManipulator.process`, `AmazingFastaExtract.process`, `FastaExtract.process`, `FastxExtract.process`, `FastxIndex.process`, `FastaIDTools.*` |
| FASTA conversion | `FastaToTable.process`, `TableToFasta.process`, `CdsToProtein.process`, `FastaMerge.process`, `FastaSplitByCount.process`, `FastaSplitAsOneSeq.process` |
| Annotation | `GXFFix.process`, `GffCdsPhase.process`, `GxfSeqExtract.process`, `GxfFilter.process`, `GffFeatureExtract.process`, `GtfFeatureExtract.process`, `GxfStat.process` |
| Tables | `TableTools.transpose`, `TableTools.mergeByKeyMulti`, `TableTools.selectRows`, `TableTools.selectColumnsByList`, `TableTools.groupAggregate`, `TableRowManipulator.process` |
| Expression | `ExpressionFpkmToTpm.process`, `ExpressionRpkm.process`, `ExpressionTpm.process`, `ExpressionTau.process`, `ExpressionCorrMatrix.process`, `GeneExpFilter.process`, `GenePairCorr.process` |
| Alignment and trees | `BlastCompareTwoSeqSet.process`, `BlastXmlToTable.process`, `ReciprocalBlast.process`, `OneStepBuildATree.process`, `TrimMsaSimple.process`, `TrimMsaGblocks.process`, `BlatAlign.process` |
| Visualization and misc | `AmazingHeatMap.process`, `MemeSuiteXmlToTab.process`, `PlantCareClassify.process`, `SendEmail.process`, `TodoList.*` |

## Examples

FASTA statistics:

```powershell
Invoke-TBtoolsRpc -Method FastaStat.process -Params @{
    inputPath = "D:/data/genome.fa"
    outputPath = "D:/data/out/genome_stat.xls"
    options = @{ getLengthOnly = $false }
}
```

Extract FASTA records with a prewritten ID list:

```powershell
Invoke-TBtoolsRpc -Method AmazingFastaExtract.process -Params @{
    inputPath = "D:/data/genome.fa"
    idListPath = "D:/data/ids.txt"
    outputPath = "D:/data/out/extracted.fa"
    options = @{
        usePattern = $false
        caseInsensitive = $true
        dontTreatSpaceAsColSep = $false
        wholeWordMatch = $false
    }
}
```

Validate then run a tree pipeline:

```powershell
$params = @{
    inputPath = "D:/data/sequences.fa"
    outputPath = "D:/data/out/tree"
    options = @{ ultraFastBS = $true; bbTime = 5000; model = "Auto"; threads = 2 }
}
$check = Invoke-TBtoolsRpc -Method OneStepBuildATree.validateParams -Params $params
if ($check.ok -eq $false -or $check.validated -eq $false) { $check.errors; throw "TBtools validation failed" }
Invoke-TBtoolsRpc -Method OneStepBuildATree.process -Params $params -TimeoutSec 7200
```

## Operating Rules

- Use PowerShell examples by default.
- Use TBtools bundled `bin\` tools before suggesting external installs.
- Keep stderr/error details visible for external tools and RPC errors.
- Do not assume a method exists from memory; discover it through `system.listMethods`.
- Do not assume `system.listMethods` returns a raw array; the canonical result is an object with `methods`.
- Do not use Python helpers for normal TBtools work in this environment.
