# Portable Demo 2 - field cheat sheet

## Deploy

```powershell
Set-Location D:\git\BRK439
az login --use-device-code
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Setup

# Complete target, network, encrypted backup, quote, preview and consent prompts.
# Save the installation path printed by Setup.
$Install = Read-Host 'Paste the installation path printed by Setup'
$Config = Join-Path $Install 'config.local.json'
```

```powershell
# Resume an interrupted installation; do not start a new one.
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Setup -InstallPath $Install
```

## Off-stage prep

```powershell
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Rehearse -InstallPath $Install -AuthorizeLiveChanges
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Run -InstallPath $Install -AuthorizeLiveChanges
```

1. Azure portal > selected subscription > demo resource group > verify the tenant, subscription, region and dedicated resources.
2. Azure portal > Policy > scope to the demo resource group > verify allowed-location, CMK and confidential-VM assignments enforce **Deny**; label quick setup **sandbox**, not SLZ.
3. Azure portal > each demo storage account > Encryption > verify its distinct Managed HSM key and pinned version.
4. Azure portal > demo VM > verify confidential security type; Azure Monitor > Alerts > verify heartbeat/recovery monitoring and actual notification delivery.
5. Complete the separately approved crash/reboot, manual-recovery and alert exercises in [the rehearsal checklist](rehearsal-checklist.md); stop if any required gate fails.
6. Control window > **Live** > **Status** > **Restore** if an open run exists > **Refresh Document** > require fresh HTTP 200.
7. After an existing run reports continuous confirmed recovery for at least 60 seconds > **Reset** > verify `Closed`. Stop and investigate any uncertain mutation.
8. Control window > **Twin** > **Refresh Document** > require HTTP 200 > **Arm new run** > verify `Armed`, heartbeat and fixed deadline > **BIG RED BUTTON**.
9. **Twin** > **Refresh Document** > require a genuine CMK-related HTTP 403; recheck heartbeat and enough time before its fixed recovery deadline. Do not extend the deadline.
10. Select **Live** > **Refresh Document** > require HTTP 200; leave the control window open.
11. Record and play back a genuine fallback run; keep only verified recordings available.
12. If entitled, open Azure portal > **Sovereign Control Panel** > prepare the posture/gaps view; label it **PREVIEW**.

## Demo steps

In a second PowerShell terminal:

```powershell
Set-Location D:\git\BRK439
$Install = Read-Host 'Paste the SAME installation path'
$Config = Join-Path $Install 'config.local.json'

.\demos\demo2\scripts\Test-PolicyExamples.ps1 -ConfigPath $Config `
    -Example denied-region -AuthorizeLiveChanges -PolicyReviewConfirmed

.\demos\demo2\scripts\Test-PolicyExamples.ps1 -ConfigPath $Config `
    -Example platform-key -AuthorizeLiveChanges -PolicyReviewConfirmed
```

1. Show both actual `RequestDisallowedByPolicy` results and the intended policy IDs/evaluated conditions; stop on unrelated errors.
2. Control window > **Live** > **Refresh Document** > show fresh HTTP 200 and the document.
3. **Arm new run** > verify `Armed`, run ID, heartbeat and fixed recovery deadline.
4. **BIG RED BUTTON** > **Refresh Document** > show the actual result and request ID; do not claim revocation while reads still return 200.
5. If Live has not denied access > select **Twin** only while its genuine denial, heartbeat and unexpired deadline remain verified > keep **PRE-REVOKED FALLBACK ACCOUNT** visible > **Refresh Document**. Otherwise use the verified recording or skip the moment.
6. Select **Live** > **Status** > **Restore** > **Refresh Document** until a fresh HTTP 200 confirms access returned.
7. If authorized > Azure portal > **Sovereign Control Panel** > show posture/gaps > say **"preview"** > leave after 30 seconds.

## Clean out

1. Control window > for **Live**, then **Twin** > **Status** > **Restore** if an open run exists > **Refresh Document** > require fresh HTTP 200.
2. For each open run, wait for at least 60 seconds of continuous confirmed recovery > **Reset** > verify `Closed`; stop on uncertain mutations or failed recovery.
3. Close the control window only after verification; do not stop/deallocate the recovery VM while a run remains unresolved.

```powershell
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode RetirementPlan -InstallPath $Install

$Settings = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
az account show --query '{tenant:tenantId,subscription:id}' --output json
az group show --subscription $Settings.subscriptionId --name $Settings.resourceGroup `
    --query '{name:name,location:location,tags:tags}' --output json
```

4. Retain the encrypted custody PFX, encrypted domain backup, passphrase separately, and any required full-HSM backup; do not delete `.private` or recovery files.
5. Obtain separate retirement approval; Azure portal > selected subscription > **Resource groups** > exact verified demo group > **Delete resource group** > review resources > type that group's name > confirm.
6. Azure portal > **Key vaults / Managed HSMs** > **Manage deleted HSMs** > verify the deleted demo HSM and retention end. Budget continued full HSM billing throughout protected retention; do not attempt to bypass purge protection.
7. Azure portal > **Policy** > **Definitions** > remove only the unused custom definitions `demo2-<nameSuffix>-storage-cmk` and `demo2-<nameSuffix>-confidential-vm`, after confirming no assignments reference them. Do not remove built-in or SLZ policies.
8. Azure portal > selected subscription > **Cost Management** > verify remaining resources and charges after retention; do not treat resource-group deletion as immediate HSM cost termination.
