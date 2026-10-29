#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ConfigPath = '/etc/demo2/config.json',
    [string]$StateDirectory = '/var/lib/demo2',
    [string]$QueueDirectory = '/var/spool/demo2/requests',
    [string]$ResponseDirectory = '/var/spool/demo2/responses',
    [switch]$AuthorizeLiveChanges
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $AuthorizeLiveChanges) { throw 'The service must be explicitly installed for live rehearsal before key operations are permitted.' }
Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Demo.Worker.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Runtime
foreach ($directory in @($StateDirectory, $QueueDirectory, $ResponseDirectory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Required protected directory is missing: $directory" }
}
$lock = [System.IO.FileStream]::new((Join-Path $StateDirectory 'worker.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $states = @{}
    foreach ($target in 'Live', 'Twin') {
        $path = Join-Path $StateDirectory "$target.json"
        $states[$target] = $null
        if (Test-Path -LiteralPath $path) {
            $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            $state = Initialize-RecoveryState $config $state $target
            Write-DurableJson $path $state
            $states[$target] = $state
        }
    }
    Write-DemoEvent 'WorkerStarted' @{}
    while ($true) {
        $now = [datetimeoffset]::UtcNow
        foreach ($target in 'Live', 'Twin') {
            $states[$target] = Invoke-RecoveryTick $config $states[$target] (Join-Path $StateDirectory "$target.json") $now
        }
        $heartbeat = [datetimeoffset]::UtcNow
        Write-DurableJson (Join-Path $ResponseDirectory 'heartbeat.json') @{ utc = $heartbeat.ToString('o') }
        Write-DemoEvent 'Heartbeat' @{ livePhase = $(if ($states.Live) { $states.Live.phase } else { 'Idle' }); twinPhase = $(if ($states.Twin) { $states.Twin.phase } else { 'Idle' }) }
        foreach ($response in Get-ChildItem -LiteralPath $ResponseDirectory -File -Filter '*.json') {
            if ($response.Name -match '^[a-f0-9]{32}\.json$' -and -not $response.LinkType -and
                $response.LastWriteTimeUtc -lt [datetime]::UtcNow.AddMinutes(-5)) {
                Remove-Item -LiteralPath $response.FullName
            }
        }
        $requests = @(Get-ChildItem -LiteralPath $QueueDirectory -File -Filter '*.json' | Sort-Object Name)
        if ($requests.Count -gt 0) {
            $file = $requests[0]
            $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            if ($id -notmatch '^[a-f0-9]{32}$' -or $file.LinkType) { throw 'Unexpected or linked queue file; operator intervention is required.' }
            $reply = @{ ok = $false; action = ''; target = ''; runId = ''; state = $null; read = $null; heartbeatUtc = $heartbeat.ToString('o'); error = '' }
            try {
                if ($file.Length -gt 2048) { throw 'Controller request exceeds the bounded request size.' }
                $request = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
                if ($request.Keys.Count -ne 4 -or $request.requestId -cne $id -or
                    $request.target -notin @('Live', 'Twin') -or
                    $request.action -notin @('Arm', 'Disable', 'Restore', 'Read', 'Status', 'Reset')) { throw 'Invalid fixed-command request.' }
                foreach ($name in 'action', 'target', 'runId') { $reply[$name] = $request[$name] }
                if ($request.action -in @('Arm', 'Disable')) {
                    $clock = & timedatectl show --property=NTPSynchronized --value
                    if ($LASTEXITCODE -ne 0 -or $clock.Trim() -ne 'yes') { throw 'NTP clock synchronization must be healthy before arming/disabling.' }
                }
                $result = Invoke-WorkerRequest $config $request $states[$request.target] (Join-Path $StateDirectory "$($request.target).json") ([datetimeoffset]::UtcNow) $heartbeat
                $states[$request.target] = $result.state
                $reply.ok = $true
                $reply.state = $result.state
                $reply.read = $result.read
            } catch {
                $reply.error = $_.Exception.Message
                Write-DemoEvent 'RequestFailed' @{ requestId = $id; error = $reply.error }
                # A mutation may have been persisted before the request failed.
                if ($reply.target -in @('Live', 'Twin')) {
                    $path = Join-Path $StateDirectory "$($reply.target).json"
                    if (Test-Path -LiteralPath $path) { $states[$reply.target] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable }
                    $reply.state = $states[$reply.target]
                }
            }
            $responsePath = Join-Path $ResponseDirectory "$id.json"
            Write-DurableJson $responsePath $reply
            Remove-Item -LiteralPath $file.FullName
        }
        Start-Sleep -Seconds $config.watchdogIntervalSeconds
    }
} finally { $lock.Dispose() }
