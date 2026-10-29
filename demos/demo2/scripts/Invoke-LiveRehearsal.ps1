#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateSet('Live', 'Twin')][string]$Target = 'Live',
    [switch]$AuthorizeLiveChanges
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $AuthorizeLiveChanges) { throw 'This opt-in rehearsal changes a dedicated key. Explicit live authorization is required.' }
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
[void](Import-DemoConfig $ConfigPath -Phase Runtime)
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$evidence = [System.IO.Path]::GetFullPath($EvidenceDirectory)
if ($evidence.StartsWith($repo + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $evidence -eq $repo) { throw 'Rehearsal evidence must be stored outside the repository.' }
[void][System.IO.Directory]::CreateDirectory($evidence)
$run = [guid]::NewGuid()
$file = Join-Path $evidence "$Target-$run.jsonl"
$control = Join-Path $PSScriptRoot 'Invoke-DemoControl.ps1'
function Invoke-RehearsalControl {
    param([string]$Action)
    $response = & $control -ConfigPath $ConfigPath -Action $Action -Target $Target -RunId $run -AuthorizeLiveChanges
    $record = @{ utc = [datetimeoffset]::UtcNow.ToString('o'); action = $Action; target = $Target; runId = $run.ToString(); state = $response.state; read = $response.read }
    if ($record.read) {
        $record.read = $record.read | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        [void]$record.read.Remove('content')
    }
    $record | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $file -Encoding utf8
    return $response
}
$armed = $false
try {
    $baseline = Invoke-RehearsalControl Read
    if ($baseline.read.status -ne 200) { throw 'Baseline read did not succeed; no disable was requested.' }
    $arm = Invoke-RehearsalControl Arm
    $armed = $true
    if ($arm.state.phase -ne 'Armed') { throw 'No persisted arm acknowledgment; refusing Disable.' }
    $null = Invoke-RehearsalControl Disable
    $denied = $false
    $deadline = [datetimeoffset]::Parse($arm.state.deadlineUtc)
    while ([datetimeoffset]::UtcNow -lt $deadline) {
        $read = (Invoke-RehearsalControl Read).read
        if ($read.status -eq 403 -and $read.errorCode -in @('KeyVaultAccessForbidden', 'KeyVaultKeyDisabled', 'KeyVaultAuthenticationFailure', 'KeyVaultEncryptionFailure')) {
            $denied = $true
            break
        }
        if ($read.status -ne 200) { throw "Unexpected read error $($read.status)/$($read.errorCode); inspect actual evidence before attributing it to CMK." }
        Start-Sleep -Seconds 2
    }
    $null = Invoke-RehearsalControl Restore
    $limit = [datetimeoffset]::UtcNow.AddSeconds(180)
    $restored = $false
    while ([datetimeoffset]::UtcNow -lt $limit) {
        $status = Invoke-RehearsalControl Status
        $read = (Invoke-RehearsalControl Read).read
        if ($status.state.keyEnabled -and $read.status -eq 200) { $restored = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $restored) { throw 'Restoration not observed within the rehearsal observation limit. Independent recovery remains active; use manual recovery and inspect alerts.' }
    if (-not $denied) { throw 'Key and reads restored, but effective CMK denial was not observed before the fixed deadline. Live moment is NOT ready; use the validated twin/recording.' }
    Write-Output "Observed baseline, effective denial and restored fresh read. Evidence: $file. Independently rehearse laptop failure; this successful normal run does not prove crash recovery."
} catch {
    $failure = $_
    if ($armed) {
        try { $null = Invoke-RehearsalControl Restore }
        catch { Write-Error "Restore request also failed: $($_.Exception.Message). The independent watchdog, not this catch block, owns timed recovery." -ErrorAction Continue }
    }
    throw $failure
}
