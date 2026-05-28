---
name: tbtools
description: Use when the user asks about TBtools, TBtools-II, TBtools RPC API, TBtools CLI, or bioinformatics operations available through TBtools such as sequence manipulation, BLAST, GFF/GTF/GXF processing, expression tables, heatmaps, trees, MCScanX, DIAMOND, HMMER, MUSCLE, and IQ-TREE.
---

# TBtools

## Overview

TBtools-II is a Java-based bioinformatics toolkit that runs on Windows and
macOS. Prefer TBtools' own bundled Java/RPC/CLI tools. Do not introduce Python,
R, Conda, or other dependencies unless the user explicitly asks.

Honor `TBTOOLS_HOME` or `TBTOOLS_JAR` if set; fall back to the platform default.

## Setup

### Windows (PowerShell)

```powershell
$TbtoolsHome = if ($env:TBTOOLS_HOME) { $env:TBTOOLS_HOME } else { "C:\Program Files\TBtools" }
$TbtoolsJar = if ($env:TBTOOLS_JAR) { $env:TBTOOLS_JAR } else { Join-Path $TbtoolsHome "TBtools_JRE1.6.jar" }
$env:Path = "$(Join-Path $TbtoolsHome 'bin');$env:Path"

Test-Path $TbtoolsJar
java -version
```

### macOS / Linux (bash)

```bash
TBTOOLS_HOME="${TBTOOLS_HOME:-/Applications/TBtools-II}"
TBTOOLS_JAR="${TBTOOLS_JAR:-$(find "$TBTOOLS_HOME" -name 'TBtools*.jar' -maxdepth 4 2>/dev/null | head -1)}"
export PATH="$TBTOOLS_HOME/bin:$PATH"

[ -f "$TBTOOLS_JAR" ] && echo "jar: $TBTOOLS_JAR" || echo "TBtools jar not found — set TBTOOLS_JAR"
java -version
```

Use `bin/` (`bin\` on Windows) tools directly when the task is a standard external tool workflow:

```bash
blastn -query query.fa -db db_prefix -out results.tsv -outfmt 6
muscle -in input.fa -out aligned.fa
iqtree -s aligned.fa -m MFP -bb 1000 -nt AUTO
diamond blastp -d proteins.dmnd -q query.fa -o matches.tsv
```

## RPC Server

### Windows (PowerShell)

```powershell
.\scripts\start_rpc_server.ps1 -Background
```

Direct form:

```powershell
java -cp $TbtoolsJar biocjava.rpc.RpcServer
```

### macOS / Linux (bash)

```bash
java -cp "$TBTOOLS_JAR" biocjava.rpc.RpcServer &
```

Default URLs:

| Purpose | URL |
| --- | --- |
| Health check | `http://127.0.0.1:8765/health` |
| JSON-RPC | `http://127.0.0.1:8765/rpc` |

`rpcPort` is configurable in TBtools config. `rpcBindAddress` is normalized to loopback only (`127.0.0.1` or `::1`); do not expose the RPC server on `0.0.0.0`.

## RPC Helper

### Windows (PowerShell)

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

### macOS / Linux (bash + curl)

```bash
tbtools_rpc() {
    local method="$1"
    local params="${2:-{}}"
    local uri="${TBTOOLS_RPC_URI:-http://127.0.0.1:8765/rpc}"
    curl -s --max-time 600 -X POST "$uri" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":\"1\"}"
}
```

Discovery:

```bash
# Windows
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8765/health
Invoke-TBtoolsRpc -Method system.ping
$methods = (Invoke-TBtoolsRpc -Method system.listMethods).methods
$methods | Where-Object { $_ -like "*Fasta*" }
Invoke-TBtoolsRpc -Method system.describeMethod -Params @{ method = "FastaStat.process" }
Invoke-TBtoolsRpc -Method system.toolsJson

# macOS / Linux
curl -s http://127.0.0.1:8765/health
tbtools_rpc system.ping
tbtools_rpc system.listMethods | python3 -c "import sys,json; [print(m) for m in json.load(sys.stdin)['result']['methods']]"
tbtools_rpc system.describeMethod '{"method":"FastaStat.process"}'
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

FASTA statistics (Windows PowerShell):

```powershell
Invoke-TBtoolsRpc -Method FastaStat.process -Params @{
    inputPath = "D:/data/genome.fa"
    outputPath = "D:/data/out/genome_stat.xls"
    options = @{ getLengthOnly = $false }
}
```

FASTA statistics (macOS / Linux bash):

```bash
tbtools_rpc FastaStat.process \
  '{"inputPath":"/data/genome.fa","outputPath":"/data/out/genome_stat.xls","options":{"getLengthOnly":false}}'
```

Extract FASTA records with a prewritten ID list (Windows PowerShell):

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

Validate then run a tree pipeline (Windows PowerShell):

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

Validate then run a tree pipeline (macOS / Linux bash):

```bash
tbtools_rpc OneStepBuildATree.validateParams \
  '{"inputPath":"/data/sequences.fa","outputPath":"/data/out/tree","options":{"ultraFastBS":true,"bbTime":5000,"model":"Auto","threads":2}}'
tbtools_rpc OneStepBuildATree.process \
  '{"inputPath":"/data/sequences.fa","outputPath":"/data/out/tree","options":{"ultraFastBS":true,"bbTime":5000,"model":"Auto","threads":2}}'
```

## Operating Rules

- Detect the platform first: use PowerShell helpers on Windows, bash + curl on macOS/Linux.
- Use TBtools bundled `bin/` tools before suggesting external installs.
- Keep stderr/error details visible for external tools and RPC errors.
- Do not assume a method exists from memory; discover it through `system.listMethods`.
- Do not assume `system.listMethods` returns a raw array; the canonical result is an object with `methods`.
- Do not use Python helpers for normal TBtools work in this environment.
- Use forward-slash paths (`/data/...`) in RPC calls even on Windows — TBtools accepts them.
