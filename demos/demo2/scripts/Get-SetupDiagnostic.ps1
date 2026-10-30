[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstallPath,[switch]$ReadManagedCommand)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Setup.psm1')
& (Get-Module Demo.Setup) {
    param($Directory,$LiveRead)
    Assert-DemoPrivatePath $Directory
    $lock=[IO.File]::Open((Join-Path $Directory '.setup.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $path=Join-Path $Directory 'install.json'
        Assert-DemoPrivatePath $path
        $journal=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        Assert-DemoJournal $journal
        $intent=$journal['pendingAgent']
        $summary=[ordered]@{mode='LocalProgressOnly';status=$journal.status;completedStages=@($journal.receipts.get_Keys() | Sort-Object);pendingOperationId=$null;command=$null}
        if ($intent) {
            if ($intent -isnot [hashtable] -or [string]$intent['operationId'] -notmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
                [string]$intent['digest'] -notmatch '^[a-fA-F0-9]{64}$') { throw 'Unknown pending intent; preserve it for explicit reconciliation.' }
            $summary.pendingOperationId=$intent.operationId
        }
        if ($LiveRead) {
            if (-not $intent) { throw 'No retained pending command to inspect. No Azure call performed.' }
            $summary.mode='ReadOnlyAzureMetadata'
            $stage='DiagnosticTargetContext'
            try {
                Assert-DemoAzureContext $journal.config
                $stage='DiagnosticPendingCommandGet'
                $uri="https://management.azure.com$($journal.resources.vmId)/runCommands/demo2-field-setup?api-version=2024-07-01&`$expand=instanceView"
                $command=Get-DemoArmRecord $uri @('ResourceNotFound')
                if ($null -eq $command) { $summary.command=@{state='NotFound';intentPreserved=$true} }
                else {
                    $view=$command.properties['instanceView']
                    $summary.command=@{id=$command.id;location='Unknown';expectedOperationId=$intent.operationId;actualOperationId=$null;ownershipAndPayloadMatch=$false
                        provisioningState='Unknown';executionState=$null;exitCode=$null;finalReceiptVerified=$false}
                    if ([string]$command['location'] -cmatch '^[a-z0-9]{1,30}$') { $summary.command.location=$command['location'] }
                    if ($command.properties['provisioningState'] -in 'Accepted','Creating','Updating','Succeeded','Failed','Canceled','Deleting') { $summary.command.provisioningState=$command.properties['provisioningState'] }
                    if ($command['tags'] -is [Collections.IDictionary] -and [string]$command.tags['operationId'] -match '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') { $summary.command.actualOperationId=$command.tags['operationId'] }
                    if ($view -is [Collections.IDictionary]) {
                        if ($view['executionState'] -in 'Pending','Running','Succeeded','Failed','Canceled','TimedOut','Unknown') { $summary.command.executionState=$view['executionState'] }
                        if ([string]$view['exitCode'] -match '^-?[0-9]{1,10}$') { $summary.command.exitCode=[long]$view['exitCode'] }
                    }
                    try {
                        Assert-DemoManagedCommand $journal $command $intent.operationId $intent.digest
                        $summary.command.ownershipAndPayloadMatch=$true
                        $summary.command.guestDiagnostic=Get-DemoGuestFailureSummary $command
                        $summary.command.finalReceiptVerified=$null -ne (Read-DemoManagedResult $command $intent.operationId)
                    } catch { $summary | ConvertTo-Json -Depth 5 | Write-Output; throw }
                }
            } catch {
                $failure=$_
                if ($failure.Exception.Data.Contains('AzureCliExitCode') -or $failure.Exception.Data.Contains('GuestFailure')) {
                    $diagnostic=Save-DemoSetupDiagnostic $failure $Directory $stage
                    Write-Host "Protected sanitized diagnostic: $diagnostic"
                }
                Write-Error "Read-only diagnostic stopped at $stage`: $($failure.Exception.Message)" -ErrorAction Continue
                throw
            }
        }
        $summary | ConvertTo-Json -Depth 5
    } finally { $lock.Dispose() }
} $InstallPath ([bool]$ReadManagedCommand)
