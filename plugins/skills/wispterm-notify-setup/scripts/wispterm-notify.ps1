param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $EventArgs
)

# Agent-agnostic WispTerm notifier for Windows PowerShell/PowerShell Core.
# Reads a Claude Code hook event from stdin or a Codex event JSON from the last
# argv, then writes OSC 777 + BEL directly to the attached ConPTY console.

$payload = ""
if ($EventArgs -and $EventArgs.Count -gt 0) {
    $payload = $EventArgs[$EventArgs.Count - 1]
}
if ([string]::IsNullOrWhiteSpace($payload)) {
    try {
        if ([Console]::IsInputRedirected) {
            $payload = [Console]::In.ReadToEnd()
        }
    } catch {
        $payload = ""
    }
}
if ([string]::IsNullOrWhiteSpace($payload)) {
    exit 0
}

function Get-JsonProperty {
    param(
        [object] $Object,
        [string] $Name
    )
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
    return [string] $prop.Value
}

$title = "Claude Code"
$body = "Notification"
$event = $null
try {
    $event = $payload | ConvertFrom-Json -ErrorAction Stop
} catch {
    $event = $null
}

$hookEvent = Get-JsonProperty $event "hook_event_name"
if ($hookEvent -eq "Stop") {
    $title = "Claude Code"
    $body = "完成，轮到你了"
} elseif ($hookEvent -eq "Notification") {
    $maybeTitle = Get-JsonProperty $event "title"
    $maybeBody = Get-JsonProperty $event "message"
    if ([string]::IsNullOrEmpty($maybeBody)) {
        $maybeBody = Get-JsonProperty $event "notification_type"
    }
    if (-not [string]::IsNullOrEmpty($maybeTitle)) { $title = $maybeTitle }
    if (-not [string]::IsNullOrEmpty($maybeBody)) { $body = $maybeBody }
} else {
    $codexType = Get-JsonProperty $event "type"
    if (-not [string]::IsNullOrEmpty($codexType)) {
        $title = "Codex"
        $codexBody = Get-JsonProperty $event "last-assistant-message"
        if ([string]::IsNullOrEmpty($codexBody)) { $codexBody = $codexType }
        if ([string]::IsNullOrEmpty($codexBody)) { $codexBody = "Turn complete" }
        $body = $codexBody
    }
}

function Sanitize-Field {
    param(
        [string] $Value,
        [int] $MaxLength
    )
    if ($null -eq $Value) { $Value = "" }
    $Value = $Value.Replace([string][char]27, "")
    $Value = $Value.Replace([string][char]7, "")
    $Value = $Value.Replace("`r", "")
    $Value = $Value.Replace("`n", "")
    $Value = $Value.Replace(";", "")
    if ($Value.Length -gt $MaxLength) {
        return $Value.Substring(0, $MaxLength)
    }
    return $Value
}

$title = Sanitize-Field $title 256
$body = Sanitize-Field $body 1024

$esc = [char]27
$bel = [char]7
$marker = [char]0x200B
$message = "$esc]777;notify;$title;$body$marker$bel$bel"
$bytes = [Text.Encoding]::UTF8.GetBytes($message)

try {
    $stream = [IO.File]::OpenWrite("CONOUT$")
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
} catch {
    try {
        $stdout = [Console]::OpenStandardOutput()
        $stdout.Write($bytes, 0, $bytes.Length)
    } catch {
        # Never block or fail the agent because notification delivery failed.
    }
}

exit 0
