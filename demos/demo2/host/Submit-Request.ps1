#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Arm', 'Disable', 'Restore', 'Read', 'Status', 'Reset')][string]$Action,
    [Parameter(Mandatory)][ValidateSet('Live', 'Twin')][string]$Target,
    [Parameter(Mandatory)][guid]$RunId,
    [string]$QueueDirectory = '/var/spool/demo2/requests',
    [string]$ResponseDirectory = '/var/spool/demo2/responses',
    [ValidateRange(1, 300)][int]$WaitSeconds = 120
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($RunId -eq [guid]::Empty) { throw 'RunId must not be empty.' }
$heartbeatPath = Join-Path $ResponseDirectory 'heartbeat.json'
$heartbeat = Get-Content -LiteralPath $heartbeatPath -Raw | ConvertFrom-Json
if (([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($heartbeat.utc)).TotalSeconds -gt 30) {
    throw 'Worker heartbeat is stale. No request was submitted; use the manual recovery path if necessary.'
}
$id = [guid]::NewGuid().ToString('N')
$temporary = Join-Path $QueueDirectory "$id.pending"
$path = Join-Path $QueueDirectory "$id.json"
$request = @{ requestId = $id; action = $Action; target = $Target; runId = $RunId.ToString() } | ConvertTo-Json -Compress
$stream = [System.IO.FileStream]::new($temporary, 'CreateNew', 'Write', 'None')
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($request)
    $stream.Write($bytes)
    $stream.Flush($true)
} finally { $stream.Dispose() }
[System.IO.File]::Move($temporary, $path)
$end = [datetimeoffset]::UtcNow.AddSeconds($WaitSeconds)
$responsePath = Join-Path $ResponseDirectory "$id.json"
while ([datetimeoffset]::UtcNow -lt $end) {
    if (Test-Path -LiteralPath $responsePath) {
        $text = Get-Content -LiteralPath $responsePath -Raw
        $reply = $text | ConvertFrom-Json
        Write-Output $text
        if (-not $reply.ok) { exit 1 }
        exit 0
    }
    Start-Sleep -Milliseconds 250
}
throw "Request $id timed out. Its outcome is unknown and it may still be processed. Do not repeat Disable; inspect Status and Restore with run $RunId. Independent recovery remains armed."
