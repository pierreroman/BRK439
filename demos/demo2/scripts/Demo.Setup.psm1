Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Demo.Custody.psm1')
$script:Kit = Split-Path $PSScriptRoot -Parent

function Save-DemoJournal {
    param([hashtable]$Journal,[string]$Path)
    $temporary = "$Path.tmp"
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 40))
    $stream = [IO.File]::Open($temporary,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($temporary,$Path,$true)
}

function Assert-DemoJournal {
    param([hashtable]$Journal)
    if ($Journal.schemaVersion -ne 1 -or $Journal.installationId -notmatch '^[a-f0-9]{32}$' -or
        $Journal.config.resourceGroup -ne "rg-demo2-$($Journal.config.nameSuffix)" -or
        -not ($Journal.receipts -is [Collections.IDictionary])) { throw 'Invalid install journal; do not reconstruct it by guessing resource ownership.' }
    $fingerprint = Get-DemoConfigFingerprint $Journal.config
    if ($fingerprint -ne $Journal.configFingerprint) { throw 'Configuration drift detected. Reconcile this installation rather than starting new resources.' }
}

function Get-DemoConfigFingerprint {
    param([hashtable]$Config)
    $immutable = @($Config.tenantId,$Config.subscriptionId,$Config.resourceGroup,$Config.nameSuffix,$Config.location,
        $Config.hsmName,$Config.vmSize,($Config.imageReference | ConvertTo-Json -Compress),
        ($Config.network | ConvertTo-Json -Compress),$Config.manualRecoveryObjectId,$Config.sshPublicKey,
        $Config.alertEmail,$Config.budgetAmount,$Config.hsmRetentionDays,$Config.policyMode,$Config.deniedLocation)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($immutable -join '|'))))
}

function Get-DemoSourceFingerprint {
    $paths = @('Start-Demo.ps1','config.schema.json','content','host','scripts','infra')
    $manifest = foreach ($path in $paths) {
        Get-ChildItem (Join-Path $script:Kit $path) -Recurse -File | Where-Object Extension -in '.json','.txt','.ps1','.psm1','.sh','.bicep' |
            ForEach-Object { $_.FullName.Substring($script:Kit.Length) + ':' + (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((($manifest | Sort-Object) -join "`n"))))
}

function Confirm-DemoCheckpoint {
    param([string]$Message,[string]$Phrase)
    Write-Host $Message
    if ((Read-Host "Type exactly '$Phrase' to continue") -cne $Phrase) { throw 'Checkpoint not accepted. Existing resources and custody files are preserved.' }
}

function Assert-DemoInstallPrivacy {
    param([string]$Path)
    $repo=[IO.Path]::GetFullPath((Join-Path $script:Kit '..\..')).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.StartsWith("$repo\",[StringComparison]::OrdinalIgnoreCase)) {
        $allowed=Join-Path $repo '.private\demo2\installs'
        if (-not $full.StartsWith("$allowed\",[StringComparison]::OrdinalIgnoreCase)) { throw 'In-repo installation state must stay under .private\demo2\installs.' }
        $tracked=@(& git -C $repo ls-files -- .private/demo2)
        if ($LASTEXITCODE -ne 0 -or $tracked.Count) { throw 'Private installation root contains tracked paths.' }
        $relative=$full.Substring($repo.Length+1).Replace('\','/')+'/install.json'
        & git -C $repo check-ignore --no-index -q -- $relative
        if ($LASTEXITCODE -ne 0) { throw 'Installation state is not Git-ignored.' }
    } else {
        for ($parent=Get-Item -LiteralPath $full; $null -ne $parent; $parent=$parent.Parent) {
            if (Test-Path -LiteralPath (Join-Path $parent.FullName '.git')) { throw 'Do not store installation secrets in another Git checkout.' }
        }
    }
}

function Select-DemoValue {
    param([string]$Label,[object[]]$Values,[string]$Property)
    if ($Values.Count -eq 0) { throw "No eligible options for $Label." }
    for ($i=0; $i -lt $Values.Count; $i++) { Write-Host "$($i+1): $($Values[$i][$Property])" }
    $choice = 0
    if (-not [int]::TryParse((Read-Host $Label),[ref]$choice) -or $choice -lt 1 -or $choice -gt $Values.Count) { throw 'Select a listed option.' }
    $Values[$choice-1]
}

function New-DemoFieldConfig {
    Get-Command az,ssh,ssh-keygen -ErrorAction Stop | Out-Null
    $accounts = @(Invoke-AzJson @('account','list'))
    if ($accounts.Count -eq 0) {
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { throw 'Sign-in failed; use the displayed trusted Microsoft device-login instructions.' }
        $accounts = @(Invoke-AzJson @('account','list'))
    }
    $selected = Select-DemoValue 'Choose subscription (verify tenant below)' $accounts 'name'
    Write-Host "Selected subscription $($selected.id); tenant $($selected.tenantId)."
    Confirm-DemoCheckpoint 'Only a new isolated demo deployment will use this target.' 'CONFIRM TARGET'
    & az account set --subscription $selected.id
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the confirmed subscription.' }
    $locations = @(Invoke-AzJson @('account','list-locations'))
    $location = Select-DemoValue 'Choose deployment region' $locations 'name'
    $skus = @(Invoke-AzJson @('vm','list-skus','--location',$location.name,'--resource-type','virtualMachines','--all'))
    $eligible = @($skus | Where-Object {
        $_.restrictions.Count -eq 0 -and
        @($_.capabilities | Where-Object { $_.name -eq 'ConfidentialComputingType' -and $_.value -notin @('','None') }).Count -gt 0
    })
    $sku = Select-DemoValue 'Choose an unrestricted confidential SKU (quota and image checked next)' $eligible 'name'
    $images = @(Invoke-AzJson @('vm','image','list','--location',$location.name,'--publisher','Canonical',
        '--offer','0001-com-ubuntu-confidential-vm-jammy','--sku','22_04-lts-cvm','--all'))
    if (-not $images.Count) { throw 'Supported confidential Ubuntu 22.04 image is unavailable in this region.' }
    $image = $images | Sort-Object version | Select-Object -Last 1
    $user = Invoke-AzJson @('ad','signed-in-user','show')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0,10)
    $config = Get-Content (Join-Path $script:Kit 'config.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $config.tenantId=$selected.tenantId; $config.subscriptionId=$selected.id
    $config.nameSuffix=$suffix; $config.resourceGroup="rg-demo2-$suffix"; $config.hsmName="hsm-demo2-$suffix"
    $config.location=$location.name; $config.allowedLocations=@($location.name)
    $config.deniedLocation=(Select-DemoValue 'Choose the deliberately disallowed test region' @($locations | Where-Object name -ne $location.name) 'name').name
    $config.vmSize=$sku.name; $config.allowedConfidentialVmSkus=@($sku.name)
    $config.imageReference=@{publisher=$image.publisher;offer=$image.offer;sku=$image.sku;version=$image.version}
    $config.manualRecoveryObjectId=$user.id; $config.initialAdminObjectIds=@($user.id)
    $config.alertEmail=Read-Host 'Recovery alert email'
    $config.budgetAmount=[decimal](Read-Host 'Monthly notification budget in subscription billing currency (not a cap)')
    $vnet = Read-Host 'New nonoverlapping /24 VNet, for example 10.91.0.0/24'
    if ($vnet -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.0/24$') { throw 'Field quick setup requires an explicit network-aligned /24.' }
    $prefix=$Matches[1]
    $config.network.vnetCidr=$vnet; $config.network.computeSubnetCidr="$prefix.0/26"
    $config.network.endpointSubnetCidr="$prefix.64/27"; $config.network.bastionSubnetCidr="$prefix.128/26"
    $config.targets.Live.accountName="demo2${suffix}live"; $config.targets.Twin.accountName="demo2${suffix}twin"
    $config.targets.Live.keyName="demo2-$suffix-live"; $config.targets.Twin.keyName="demo2-$suffix-twin"
    return $config
}

function Test-DemoFieldPreflight {
    param([hashtable]$Config,[string]$ConfigPath)
    Assert-DemoAzureContext $Config
    & (Join-Path $PSScriptRoot 'Test-AzurePrerequisites.ps1') -ConfigPath $ConfigPath -AuthorizeAzureReads | Format-List | Out-Host
    Confirm-DemoCheckpoint 'Review effective policies and exemptions above. Quick setup creates RG-scoped sandbox approximations, NOT an SLZ. Confirm this tenant permits private data paths, trusted Storage HSM access, Bastion, NAT/package/Entra/ARM egress and authenticated public Monitor ingestion/query; no policies will be weakened.' 'APPROVE PRIVATE CONNECTIVITY AND EGRESS'
    $permissions=Invoke-AzJson @('rest','--method','get','--url',"https://management.azure.com/subscriptions/$($Config.subscriptionId)/providers/Microsoft.Authorization/permissions?api-version=2022-04-01")
    foreach ($action in @('Microsoft.Resources/subscriptions/resourceGroups/write','Microsoft.Resources/deployments/write',
        'Microsoft.Authorization/policyDefinitions/write','Microsoft.Authorization/policyAssignments/write','Microsoft.Authorization/roleAssignments/write',
        'Microsoft.KeyVault/managedHSMs/write','Microsoft.Compute/virtualMachines/write','Microsoft.Network/virtualNetworks/write',
        'Microsoft.Storage/storageAccounts/write','Microsoft.ManagedIdentity/userAssignedIdentities/write','Microsoft.Consumption/budgets/write',
        'Microsoft.Insights/scheduledQueryRules/write','Microsoft.OperationalInsights/workspaces/write')) {
        $allowed=@($permissions.value | Where-Object {
            $grant=$_
            @($grant.actions | Where-Object { $action -like $_ }).Count -gt 0 -and
            @($grant.notActions | Where-Object { $action -like $_ }).Count -eq 0
        }).Count -gt 0
        if (-not $allowed) { throw "Required effective subscription permission not demonstrated: $action. Activate the appropriate scoped role/PIM access and retry." }
    }
    $sku = @(Invoke-AzJson @('vm','list-skus','--location',$Config.location,'--size',$Config.vmSize,'--all') |
        Where-Object { $_.name -eq $Config.vmSize -and $_.resourceType -eq 'virtualMachines' })
    if ($sku.Count -ne 1) { throw 'SKU discovery is ambiguous.' }
    $cores = [int](@($sku[0].capabilities | Where-Object name -eq 'vCPUs')[0].value)
    $usage = @(Invoke-AzJson @('vm','list-usage','--location',$Config.location))
    foreach ($family in @($sku[0].family,'cores')) {
        $limit = @($usage | Where-Object { $_.name.value -eq $family })
        if ($limit.Count -ne 1 -or ($limit[0].limit - $limit[0].currentValue) -lt $cores) { throw "Insufficient or unknown quota for $family. No quota request was submitted." }
    }
    foreach ($provider in @('Microsoft.KeyVault','Microsoft.Network','Microsoft.Compute','Microsoft.Storage','Microsoft.ManagedIdentity','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Consumption')) {
        $registration=Invoke-AzJson @('provider','show','--namespace',$provider)
        if ($registration.registrationState -ne 'Registered') { throw "$provider is not registered. Ask a platform administrator; no registration was attempted." }
        if ($provider -eq 'Microsoft.KeyVault') {
            $type=@($registration.resourceTypes | Where-Object resourceType -eq 'managedHSMs')
            if ($type.Count -ne 1 -or @($type[0].locations | Where-Object { ($_ -replace '\s','').ToLowerInvariant() -eq $Config.location }).Count -eq 0) { throw 'Managed HSM regional catalog support is unverified.' }
        }
    }
    $hsmName=Invoke-AzJson @('keyvault','check-name','--name',$Config.hsmName,'--resource-type','hsm')
    if (-not $hsmName.nameAvailable) { throw 'HSM name unavailable; never recover/adopt another or soft-deleted HSM.' }
    foreach ($target in 'Live','Twin') {
        $available=Invoke-AzJson @('storage','account','check-name','--name',$Config.targets[$target].accountName)
        if (-not $available.nameAvailable) { throw "$target account name unavailable." }
    }
    $vnets=@(Invoke-AzJson @('network','vnet','list'))
    $octets=($Config.network.vnetCidr -split '/')[0].Split('.')
    $candidate=[uint64]$octets[0]*16777216+[uint64]$octets[1]*65536+[uint64]$octets[2]*256
    foreach ($existing in $vnets) {
        foreach ($cidr in $existing.addressSpace.addressPrefixes) {
            $ip,$bits=$cidr.Split('/')
            if ($ip.Contains(':')) { continue }
            $b=([ipaddress]$ip).GetAddressBytes()
            $start=[uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+$b[3]
            $end=$start+[uint64][math]::Pow(2,32-[int]$bits)-1
            if ($candidate -le $end -and ($candidate+255) -ge $start) { throw "VNet overlaps discovered network $($existing.name); choose another range." }
        }
    }
    Write-Host 'Catalog/quota checks passed; this does not reserve allocatable HSM/VM capacity.'
}

function Assert-DemoInstallOwner {
    param([hashtable]$Journal)
    $exists=Invoke-AzJson @('group','exists','--name',$Journal.config.resourceGroup,'--subscription',$Journal.config.subscriptionId)
    if ($exists) {
        $group=Invoke-AzJson @('group','show','--name',$Journal.config.resourceGroup,'--subscription',$Journal.config.subscriptionId)
        if ($group.tags.installationId -ne $Journal.installationId -or $group.tags.purpose -ne 'demo2-only') { throw 'Resource group is not owned by this exact installation; refusing adoption.' }
    } elseif ($Journal.receipts.ContainsKey('Foundation')) { throw 'Previously provisioned group is missing; explicit reconciliation required, not recreation.' }
    return [bool]$exists
}

function Invoke-DemoAgentScript {
    param([hashtable]$Journal,[string]$JournalPath,[string]$Script)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Script)))
    $vmId=$Journal.resources.vmId
    $uri="https://management.azure.com$vmId/runCommands/demo2-field-setup?api-version=2024-07-01"
    if ($Journal.pendingAgent) {
        if ($Journal.pendingAgent.digest -ne $hash) { throw 'An earlier agent operation is unresolved. Repeat the same setup stage; do not overwrite an in-flight command.' }
        $operation=$Journal.pendingAgent.operationId
    } else {
        $operation=[guid]::NewGuid().ToString('D')
        $Journal.pendingAgent=@{operationId=$operation;digest=$hash;startedUtc=[datetimeoffset]::UtcNow.ToString('o')}
        Save-DemoJournal $Journal $JournalPath
        $body=@{location=$Journal.config.location;tags=@{installationId=$Journal.installationId;operationId=$operation}
            properties=@{source=@{script=$Script.Replace('__OPERATION_ID__',$operation)};asyncExecution=$true;timeoutInSeconds=1800;treatFailureAsDeploymentFailure=$true}}
        $file=Join-Path (Split-Path $JournalPath) 'agent-request.local.json'
        try {
            $body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file
            $null=Invoke-AzJson @('rest','--method','put','--url',$uri,'--body',"@$file")
        } finally { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
    }
    $deadline=[datetimeoffset]::UtcNow.AddMinutes(35)
    do {
        $command=Invoke-AzJson @('rest','--method','get','--url',($uri+'&$expand=instanceView'))
        if ($command.tags.operationId -ne $operation) { throw 'Guest command ownership/correlation mismatch.' }
        $view=$command.properties.instanceView
        if ($view -and $view.executionState -in 'Succeeded','Failed','Canceled','TimedOut') { break }
        if ([datetimeoffset]::UtcNow -gt $deadline) { throw 'Agent observation expired; pending operation retained for reconciliation, not resubmitted.' }
        Start-Sleep -Seconds 5
    } while ($true)
    if ($view.executionState -ne 'Succeeded' -or $view.exitCode -ne 0) {
        $Journal.pendingAgent=$null
        Save-DemoJournal $Journal $JournalPath
        throw "Guest operation failed: $($view.executionState), exit $($view.exitCode). Inspect protected guest logs, not keys. No success receipt written."
    }
    $lines=([string]$view.output).Trim() -split '\r?\n'
    try { $result=$lines[-1] | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Guest final result missing/malformed/truncated; pending operation retained.' }
    if ($result.operationId -ne $operation -or $result.ok -ne $true) { throw 'Guest result correlation/acceptance failed.' }
    if (-not $Journal.ContainsKey('agentTimings')) { $Journal.agentTimings=@() }
    $finished=[datetimeoffset]::UtcNow
    $started=$Journal.pendingAgent['startedUtc']
    $Journal.agentTimings += @{operationId=$operation;sourceDigest=$hash;startedUtc=$started;completedUtc=$finished.ToString('o')
        observedSeconds=$(if ($started) { ($finished-[datetimeoffset]::Parse($started)).TotalSeconds } else { $null })}
    $Journal.pendingAgent=$null
    Save-DemoJournal $Journal $JournalPath
    return $result
}

function Send-DemoPublicFile {
    param([hashtable]$Journal,[string]$JournalPath,[string]$RemotePath,[byte[]]$Bytes)
    if ($RemotePath -notmatch '^/var/lib/demo2-setup/[a-f0-9]{32}/[a-zA-Z0-9/._-]+$' -or $RemotePath.Contains('..')) { throw 'Invalid public artifact destination.' }
    $encoded=[Convert]::ToBase64String($Bytes)
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    if (-not $Journal.ContainsKey('publicUploads')) { $Journal.publicUploads=@{} }
    if ($Journal.publicUploads.ContainsKey($RemotePath) -and $Journal.publicUploads[$RemotePath] -eq $digest) { return }
    # This channel carries reviewed source, config identifiers and public certificates only.
    $parent=$RemotePath.Substring(0,$RemotePath.LastIndexOf('/'))
    $script="set -eu`numask 077`ninstall -d -m 0700 '$parent'`nprintf '%s' '$encoded' | base64 -d > '$RemotePath.tmp'`nprintf '%s  %s\n' '$digest' '$RemotePath.tmp' | sha256sum --check --status`nchmod 0600 '$RemotePath.tmp'`nmv '$RemotePath.tmp' '$RemotePath'`nprintf '%s\n' '{`"operationId`":`"__OPERATION_ID__`",`"ok`":true}'"
    $null=Invoke-DemoAgentScript $Journal $JournalPath $script
    $Journal.publicUploads[$RemotePath]=$digest
    Save-DemoJournal $Journal $JournalPath
}

function Invoke-DemoGuestStage {
    param([hashtable]$Journal,[string]$JournalPath,[string]$Action,[int]$Chunk=0)
    $remote="/var/lib/demo2-setup/$($Journal.installationId)"
    $script="umask 077`n/usr/bin/pwsh -NoProfile -NonInteractive -File $remote/kit/host/Invoke-SetupStage.ps1 -InstallationId $($Journal.installationId) -OperationId __OPERATION_ID__ -Action $Action -Chunk $Chunk"
    $response=Invoke-DemoAgentScript $Journal $JournalPath $script
    if ($response.installationId -ne $Journal.installationId -or $response.action -ne $Action) { throw 'Guest stage correlation failed.' }
    return $response.result
}

function Receive-DemoEnvelope {
    param([hashtable]$Info,[scriptblock]$ReadChunk)
    if ($Info.bytes -lt 1 -or $Info.bytes -gt 1000000 -or $Info.chunks -ne [int][math]::Ceiling($Info.bytes/1200.0) -or $Info.digest -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid encrypted envelope metadata.' }
    $memory=[IO.MemoryStream]::new()
    try {
        for ($i=0; $i -lt $Info.chunks; $i++) {
            $part=& $ReadChunk $i
            if ($part.index -ne $i -or $part.bytes -ne $Info.bytes) { throw 'Encrypted envelope chunk replay/reorder/length mismatch.' }
            $bytes=[Convert]::FromBase64String($part.data)
            if ($bytes.Length -ne [math]::Min(1200,$Info.bytes-$memory.Length)) { throw 'Encrypted envelope chunk truncated.' }
            $memory.Write($bytes)
        }
        $result=$memory.ToArray()
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($result)) -ne $Info.digest) { throw 'Encrypted envelope digest mismatch.' }
        return ,$result
    } finally { $memory.Dispose() }
}

function Invoke-DemoSetup {
    [CmdletBinding()]
    param([string]$Mode='Setup',[string]$InstallPath,[switch]$AuthorizeLiveChanges)
    if ($Mode -eq 'Plan') {
        return [pscustomobject]@{Mode='OfflinePlan';Architecture='Managed HSM + confidential Linux VM + private Live/Twin storage';Next='Setup prompts for a new target, fresh encrypted custody, reviewed quote and explicit consent. No Azure operations performed.'}
    }
    if (-not $IsWindows) { throw 'Field entry point currently supports Windows PowerShell 7.4+; use pwsh, not Windows PowerShell 5.' }
    if (-not $InstallPath) {
        if ($Mode -ne 'Setup') { throw 'Specify -InstallPath for an existing installation; no implicit current environment.' }
        $id=[guid]::NewGuid().ToString('N')
        $repo=[IO.Path]::GetFullPath((Join-Path $script:Kit '..\..'))
        $ignore=Join-Path $repo '.gitignore'
        if (-not (Test-Path $ignore) -or (Get-Content $ignore) -notcontains '/.private/demo2/') {
            Confirm-DemoCheckpoint 'Protect new installation data by adding /.private/demo2/ to the root .gitignore.' 'ADD PRIVATE IGNORE'
            Add-Content -LiteralPath $ignore -Value "`n/.private/demo2/"
        }
        $InstallPath=Join-Path $repo ".private\demo2\installs\$id"
        $tracked=@(& git -C $repo ls-files -- .private/demo2)
        if ($LASTEXITCODE -ne 0 -or $tracked.Count) { throw 'Private root has tracked files or is not in a normal Git checkout.' }
        & git -C $repo check-ignore --no-index -q -- ".private/demo2/installs/$id/install.json"
        if ($LASTEXITCODE -ne 0) { throw 'Install state is not ignored.' }
        New-DemoPrivateDirectory $InstallPath
    }
    Assert-DemoPrivatePath $InstallPath
    Assert-DemoInstallPrivacy $InstallPath
    $InstallPath=[IO.Path]::GetFullPath($InstallPath)
    $journalPath=Join-Path $InstallPath 'install.json'
    Write-Host "Installation path: $InstallPath"
    $lock=$null
    try {
        $lock=[IO.File]::Open((Join-Path $InstallPath '.setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if (Test-Path $journalPath) {
            $journal=Get-Content $journalPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-DemoJournal $journal
        } else {
            if ($Mode -ne 'Setup') { throw 'Installation journal not found.' }
            if ((Get-ChildItem -LiteralPath $InstallPath -Force | Where-Object Name -ne '.setup.lock').Count) { throw 'Unjournaled private files exist; reconcile custody rather than regenerating.' }
            $config=New-DemoFieldConfig
            foreach ($name in 'admin','operator') {
                & ssh-keygen -q -t ed25519 -N '' -f (Join-Path $InstallPath $name) -C "demo2-$($config.nameSuffix)-$name"
                if ($LASTEXITCODE -ne 0) { throw 'Fresh SSH generation failed.' }
                Protect-DemoPrivateFile (Join-Path $InstallPath $name)
                Protect-DemoPrivateFile (Join-Path $InstallPath "$name.pub")
            }
            $config.sshPublicKey=(Get-Content (Join-Path $InstallPath 'admin.pub') -Raw).Trim()
            $config.sshIdentityFile=Join-Path $InstallPath 'operator'; $config.sshUser='demooperator'
            $journal=@{schemaVersion=1;installationId=([guid]::NewGuid().ToString('N'));config=$config;configFingerprint=(Get-DemoConfigFingerprint $config)
                sourceFingerprint=(Get-DemoSourceFingerprint);receipts=@{};resources=@{};pendingAgent=$null;status='Preparing';createdUtc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        if ($Mode -eq 'RetirementPlan') {
            return [pscustomobject]@{Installation=$journal.installationId;Scope=$journal.config.resourceGroup;Mode='ReadOnlyGuidance';Steps=@('Authorize live inspection and restore both pinned keys; verify fresh reads and Closed runs.','Verify custody AND any required full-HSM backup; retain offline copies.','Inventory and review dedicated resources, retained disk, policy definitions and costs.','Separately authorize any resource deletion. HSM retains full billing during protected retention; no automatic purge/cleanup.')}
        }
        if ($Mode -eq 'Status' -and -not $AuthorizeLiveChanges) {
            return [pscustomobject]@{Mode='LocalJournalOnly';Status=$journal.status;Stages=@($journal.receipts.Keys);DemoReady=$false;Next="Use Setup -InstallPath '$InstallPath' to reconcile Azure/guest state. Journal is not live readiness."}
        }
        if ($journal.sourceFingerprint -ne (Get-DemoSourceFingerprint)) { throw 'Source changed since this installation began. Review/migrate the existing install; no automatic in-place guest upgrade.' }
        $config=$journal.config
        $configPath=Join-Path $InstallPath 'config.local.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
        $null=Import-DemoConfig $configPath -Phase Foundation
        Assert-DemoAzureContext $config
        if ($Mode -in 'Run','Rehearse') {
            if ($journal.status -ne 'ConfiguredNeedsRehearsal') { throw 'Setup has not finished all configuration/privilege-reduction stages.' }
            Invoke-DemoFieldRun -Journal $journal -InstallPath $InstallPath -Mode $Mode -AuthorizeLiveChanges:$AuthorizeLiveChanges
            return
        }
        if ($Mode -ne 'Setup') { throw 'Live Status is performed by Setup reconciliation; plain Status never mutates Azure.' }
        if (-not $journal.receipts.ContainsKey('Custody')) {
            Confirm-DemoCheckpoint 'Synthetic demo only: one operator controls all four wrapping shares (3-of-4), not production multi-person custody. Keep the passphrase separate; a real offline recovery copy is mandatory.' 'ACCEPT DEMO CUSTODY'
            if (Test-Path -LiteralPath (Join-Path $InstallPath 'custody.json')) {
                $password=Read-Host 'Existing custody passphrase to validate/resume (no keys regenerated)' -AsSecureString
                Test-DemoCustodyBackup $InstallPath $password
            } else {
                $backup=Read-Host 'Separate offline/protected backup directory (not inside this installation)'
                $password=Read-Host 'New custody backup passphrase (at least 16 characters)' -AsSecureString
                New-DemoCustody $InstallPath $backup $password $journal.installationId
            }
            $password=$null
            Confirm-DemoCheckpoint 'Backup decryption/key matching passed. Confirm you have placed the backup in your independently retained offline/protected custody.' 'BACKUP RETAINED'
            $journal.receipts.Custody=@{verifiedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        $exists=Assert-DemoInstallOwner $journal
        if (-not $journal.receipts.ContainsKey('Foundation')) {
            $password=Read-Host 'Custody backup passphrase: revalidate retained keys before billed provisioning' -AsSecureString
            Test-DemoCustodyBackup $InstallPath $password
            $password=$null
            if (-not $exists) { Test-DemoFieldPreflight $config $configPath }
            if (-not $journal.receipts.ContainsKey('Cost')) {
                $hourly=[decimal](Read-Host 'Reviewed Managed HSM hourly rate (must be positive)')
                $monthly=[decimal](Read-Host 'Reviewed total monthly estimate: HSM, Bastion, CVM, disk, NAT/IPs, Private Link/DNS, monitoring')
                $source=Read-Host 'Quote currency and reference/source'
                if ($hourly -le 0 -or $monthly -le 0 -or [string]::IsNullOrWhiteSpace($source)) { throw 'A real reviewed quote is required; no zero/unknown price fallback.' }
                Confirm-DemoCheckpoint "Estimated monthly $monthly ($source). HSM bills continuously, even unactivated; protected $($config.hsmRetentionDays)-day deleted retention alone costs at least $($hourly*24*$config.hsmRetentionDays). Other resources keep billing; budgets are not caps." 'ACCEPT COST'
                $journal.receipts.Cost=@{hourly=$hourly;monthly=$monthly;reference=$source}
                Save-DemoJournal $journal $journalPath
            }
            $template=Join-Path $script:Kit 'infra\main.bicep'
            $preview=@('deployment','sub','what-if','--no-pretty-print','--validation-level','Provider','--subscription',$config.subscriptionId,'--location',$config.location,'--template-file',$template,
                '--parameters',"config=@$configPath",'stage=foundation',"installationId=$($journal.installationId)",'bootstrapEnabled=true')
            $whatIf=Invoke-AzJson $preview
            if ($whatIf.status -ne 'Succeeded') { throw 'Foundation provider what-if did not succeed; no provisioning attempted.' }
            $whatIf | ConvertTo-Json -Depth 40 | Write-Host
            Confirm-DemoCheckpoint 'Review the complete preview. This provisions billed HSM+CVM/Bastion, scoped policies, private endpoints, a new blank disk that setup will format, temporary bootstrap grants and approved signed Microsoft package downloads. No existing environment may be replaced.' 'I UNDERSTAND THE RISKS; DEPLOY THIS INSTALLATION'
            $deployment=Invoke-AzJson @('deployment','sub','create','--name',"demo2-$($journal.installationId)",'--subscription',$config.subscriptionId,'--location',$config.location,
                '--template-file',$template,'--parameters',"config=@$configPath",'stage=foundation',"installationId=$($journal.installationId)",'bootstrapEnabled=true')
            if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Foundation deployment failed; retain resources and resume after inspecting its actual errors.' }
            $journal.resources=$deployment.properties.outputs.foundationResources.value
            foreach ($name in 'controllerIdentityClientId','controllerPrincipalId','liveStorageIdentityPrincipalId','twinStorageIdentityPrincipalId') { $config[$name]=$journal.resources[$name] }
            $journal.receipts.Foundation=@{deployment=$deployment.id;utc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        foreach ($name in 'controllerIdentityClientId','controllerPrincipalId','liveStorageIdentityPrincipalId','twinStorageIdentityPrincipalId') { $config[$name]=$journal.resources[$name] }
        [void](Assert-DemoInstallOwner $journal)
        $remote="/var/lib/demo2-setup/$($journal.installationId)"
        if (-not $journal.receipts.ContainsKey('PublicPayload')) {
            $files = foreach ($relative in @('config.schema.json','content\sovereignty-demo.txt',
                'host\Prepare-FieldHost.sh','host\Invoke-SetupStage.ps1','host\Demo.Worker.psm1',
                'host\Start-Watchdog.ps1','host\Submit-Request.ps1','scripts\Demo.Common.psm1',
                'scripts\Initialize-Hsm.ps1','scripts\Initialize-Content.ps1','scripts\Install-Watchdog.ps1')) {
                Get-Item -LiteralPath (Join-Path $script:Kit $relative)
            }
            foreach ($file in $files) {
                $relative=$file.FullName.Substring($script:Kit.Length+1).Replace('\','/')
                $text=[IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n")
                Send-DemoPublicFile $journal $journalPath "$remote/kit/$relative" ([Text.Encoding]::UTF8.GetBytes($text))
            }
            foreach ($name in @('operator.pub','wrapping-01.cer','wrapping-02.cer','wrapping-03.cer','wrapping-04.cer','recipient.cer')) {
                Send-DemoPublicFile $journal $journalPath "$remote/$name" ([IO.File]::ReadAllBytes((Join-Path $InstallPath $name)))
            }
            $metadata=@{installationId=$journal.installationId;bootstrapClientId=$journal.resources.bootstrapClientId;bootstrapPrincipalId=$journal.resources.bootstrapPrincipalId}
            Send-DemoPublicFile $journal $journalPath "$remote/setup.json" ([Text.Encoding]::UTF8.GetBytes(($metadata|ConvertTo-Json)))
            $journal.receipts.PublicPayload=@{digest=$journal.sourceFingerprint}; Save-DemoJournal $journal $journalPath
        }
        $guestConfig=$config.Clone()
        $guestConfig.sshIdentityFile=''
        Send-DemoPublicFile $journal $journalPath "$remote/config.json" ([Text.Encoding]::UTF8.GetBytes(($guestConfig|ConvertTo-Json -Depth 30)))
        if (-not $journal.receipts.ContainsKey('Guest')) {
            $script="/bin/bash $remote/kit/host/Prepare-FieldHost.sh $($journal.installationId) $($config.subscriptionId) demo2-$($config.nameSuffix)-access $($journal.resources.custodyDiskId)`n" +
                'test $? -eq 0 || exit $?'+ "`n" + 'printf ''%s\n'' ''{"operationId":"__OPERATION_ID__","ok":true}'''
            $null=Invoke-DemoAgentScript $journal $journalPath $script
            $journal.receipts.Guest=Invoke-DemoGuestStage $journal $journalPath Inspect
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('DomainBackup')) {
            if (-not $journal.receipts.ContainsKey('DomainActivated')) {
                Confirm-DemoCheckpoint "Activate only $($config.hsmName), installation $($journal.installationId), with your four public wrapping certificates and quorum 3. Private keys remain local. Verify your encrypted custody backup is retained." 'ACTIVATE THIS DEMO HSM'
                $journal.receipts.DomainActivated=Invoke-DemoGuestStage $journal $journalPath Activate
                Save-DemoJournal $journal $journalPath
            }
            $info=$journal.receipts.DomainActivated
            if (-not $journal.ContainsKey('domainChunks')) { $journal.domainChunks=@{} }
            $bytes=Receive-DemoEnvelope $info {
                param($index)
                $key="$index"
                if (-not $journal.domainChunks.ContainsKey($key)) {
                    $journal.domainChunks[$key]=Invoke-DemoGuestStage $journal $journalPath DomainChunk $index
                    Save-DemoJournal $journal $journalPath
                }
                return $journal.domainChunks[$key]
            }
            $envelope=Join-Path $InstallPath 'security-domain.cms'
            [IO.File]::WriteAllBytes($envelope,$bytes)
            $password=Read-Host 'Custody backup passphrase for domain restore/readability check' -AsSecureString
            Test-DemoCustodyBackup $InstallPath $password
            Test-DemoDomainEnvelope $InstallPath $password $envelope
            $password=$null
            $custody=Get-Content (Join-Path $InstallPath 'custody.json') -Raw | ConvertFrom-Json -AsHashtable
            $backup=Join-Path (Split-Path $custody.backupFile) "$($journal.installationId)-security-domain.cms"
            [IO.File]::WriteAllBytes($backup,$bytes); Assert-DemoPrivatePath $backup
            if ((Get-FileHash $backup).Hash -ne (Get-FileHash $envelope).Hash) { throw 'Encrypted domain backup copy mismatch.' }
            Confirm-DemoCheckpoint 'Domain envelope decrypt/readability passed and separate encrypted copy matches. Confirm independent custody of BOTH PFX and domain envelope; keep passphrase separate.' 'DOMAIN BACKUP RETAINED'
            $journal.receipts.DomainBackup=@{digest=$info.digest;path=$backup;hsmName=$config.hsmName}
            Save-DemoJournal $journal $journalPath
        }
        Send-DemoPublicFile $journal $journalPath "$remote/domain-backup-verified.json" ([Text.Encoding]::UTF8.GetBytes(($journal.receipts.DomainBackup|ConvertTo-Json)))
        if (-not $journal.receipts.ContainsKey('Keys')) {
            $keys=Invoke-DemoGuestStage $journal $journalPath Keys
            $config.targets=$keys.targets
            $journal.receipts.Keys=$keys
            Save-DemoJournal $journal $journalPath
        }
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
        if (-not $journal.receipts.ContainsKey('Storage')) {
            $template=Join-Path $script:Kit 'infra\main.bicep'
            $arguments=@('--subscription',$config.subscriptionId,'--location',$config.location,'--template-file',$template,
                '--parameters',"config=@$configPath",'stage=storage',"installationId=$($journal.installationId)")
            $preview=Invoke-AzJson (@('deployment','sub','what-if','--no-pretty-print','--validation-level','Provider')+$arguments)
            if ($preview.status -ne 'Succeeded') { throw 'Storage provider what-if did not succeed; no storage creation attempted.' }
            $preview | ConvertTo-Json -Depth 40 | Write-Host
            Confirm-DemoCheckpoint 'Review storage preview: two private CMK accounts in this installation only. No HSM/key replacement or changes to other resources.' 'CREATE DEMO STORAGE'
            $deployment=Invoke-AzJson (@('deployment','sub','create','--name',"demo2-storage-$($journal.installationId)")+$arguments)
            if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Storage deployment failed; no readiness implied.' }
            $journal.receipts.Storage=@{deployment=$deployment.id}
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('Content')) {
            foreach ($target in 'Live','Twin') {
                $scope="/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($config.targets[$target].accountName)"
                if (-not $journal.receipts.ContainsKey("UploadRole$target")) {
                    $roleName=[guid]::new([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($journal.installationId)-upload-$target"))[0..15]).ToString()
                    $role=Invoke-AzJson @('role','assignment','create','--name',$roleName,'--assignee-object-id',$journal.resources.bootstrapPrincipalId,'--assignee-principal-type','ServicePrincipal',
                        '--role','Storage Blob Data Contributor','--scope',$scope)
                    $journal.receipts["UploadRole$target"]=@{id=$role.id}
                }
                Save-DemoJournal $journal $journalPath
            }
            $journal.receipts.Content=Invoke-DemoGuestStage $journal $journalPath Content
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('Worker')) {
            $journal.receipts.Worker=Invoke-DemoGuestStage $journal $journalPath Worker
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('Reduced')) {
            $null=Invoke-DemoGuestStage $journal $journalPath Reduce
            foreach ($target in 'Live','Twin') {
                $null=Invoke-AzJson @('role','assignment','delete','--ids',$journal.receipts["UploadRole$target"].id)
            }
            $null=Invoke-AzJson @('vm','identity','remove','--ids',$journal.resources.vmId,'--identities',$journal.resources.bootstrapIdentityId)
            $null=Invoke-AzJson @('role','assignment','delete','--ids',$journal.resources.bootstrapReaderAssignmentId)
            $vm=Invoke-AzJson @('vm','show','--ids',$journal.resources.vmId)
            if ($vm.identity.userAssignedIdentities.ContainsKey($journal.resources.bootstrapIdentityId)) { throw 'Bootstrap identity is still attached.' }
            $left=@(Invoke-AzJson @('role','assignment','list','--scope',"/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)",'--all') |
                Where-Object principalId -eq $journal.resources.bootstrapPrincipalId)
            if ($left.Count) { throw 'Temporary bootstrap ARM grants remain; resume reduction before readiness.' }
            $journal.receipts.Reduced=@{verifiedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        $journal.receipts.Baseline=Invoke-DemoGuestStage $journal $journalPath Status
        $journal.status='ConfiguredNeedsRehearsal'
        Save-DemoJournal $journal $journalPath
        Write-Output "Configured, NOT demo-ready: $InstallPath. Next: -Mode Rehearse -InstallPath '$InstallPath' -AuthorizeLiveChanges after approving live tests. Independent failure/alert/twin tests remain mandatory."
    } catch {
        Write-Error "Setup/lifecycle stopped: $($_.Exception.Message) Resume path: $InstallPath. Resources and custody are preserved; no automatic deletion." -ErrorAction Continue
        throw
    } finally { if ($lock) { $lock.Dispose() } }
}

function Invoke-DemoFieldRun {
    param([hashtable]$Journal,[string]$InstallPath,[string]$Mode,[switch]$AuthorizeLiveChanges)
    $config=$Journal.config
    $port=[int]$config.sshPort
    if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count) { throw 'Tunnel port already occupied; no unknown helper will be reused or stopped.' }
    $known=Join-Path $InstallPath 'known_hosts'
    $hostKey=$Journal.receipts.Guest.hostKey
    if ($hostKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Missing authenticated per-install host key; never disable host verification.' }
    "[127.0.0.1]:$port $hostKey" | Set-Content $known -Encoding ascii
    $info=[Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.Arguments="/d /s /c `"az network bastion tunnel --name demo2-$($config.nameSuffix)-bastion --resource-group $($config.resourceGroup) --subscription $($config.subscriptionId) --target-resource-id $($Journal.resources.vmId) --resource-port 22 --port $port`""
    $process=[Diagnostics.Process]::Start($info)
    $previousKnownHosts=$env:DEMO2_KNOWN_HOSTS
    try {
        $deadline=[datetimeoffset]::UtcNow.AddSeconds(120)
        do {
            Start-Sleep -Seconds 2
            if ($process.HasExited) { throw 'Bastion helper exited; operator route is blocked.' }
            $ready=@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0
        } until ($ready -or [datetimeoffset]::UtcNow -gt $deadline)
        if (-not $ready) { throw 'Bastion listener not ready.' }
        $env:DEMO2_KNOWN_HOSTS=$known
        $path=Join-Path $InstallPath 'config.local.json'
        $baseline=& (Join-Path $PSScriptRoot 'Invoke-DemoControl.ps1') -ConfigPath $path -Action Read -Target Live -RunId ([guid]::NewGuid())
        if ($baseline.read.status -ne 200) { throw 'Fresh Live read failed through the pinned restricted operator path; stage is not ready.' }
        if ($Mode -eq 'Rehearse') {
            if (-not $AuthorizeLiveChanges) { throw 'Rehearsal requires -AuthorizeLiveChanges plus explicit live risk acknowledgment.' }
            Confirm-DemoCheckpoint 'Rehearsal attempts real policy denials and disables/restores only this installation pinned demo key after independent recovery is armed. It can cause an outage; propagation is not guaranteed.' 'I UNDERSTAND THE RISKS; REHEARSE'
            Confirm-DemoCheckpoint 'Review inherited policies/exemptions and the named intended sandbox controls before negative probes. Positive control may create an additional billable private account; no automatic cleanup.' 'POLICY REVIEW COMPLETE'
            foreach ($example in 'positive','denied-region','platform-key') { & (Join-Path $PSScriptRoot 'Test-PolicyExamples.ps1') -ConfigPath $path -Example $example -AuthorizeLiveChanges -PolicyReviewConfirmed -Confirm:$false }
            & (Join-Path $PSScriptRoot 'Invoke-LiveRehearsal.ps1') -ConfigPath $path -EvidenceDirectory (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "BRK439\demo2-evidence\$($Journal.installationId)") -AuthorizeLiveChanges
            Write-Output 'Normal rehearsal completed only. Independent crash/reboot, manual recovery, alert delivery and finite Twin preparation remain separate gates; no universal DemoReady flag is set.'
        } else {
            & (Join-Path $PSScriptRoot 'Show-ControlPanel.ps1') -ConfigPath $path -AuthorizeLiveChanges:$AuthorizeLiveChanges
        }
    } finally {
        if ($null -ne $previousKnownHosts) { $env:DEMO2_KNOWN_HOSTS=$previousKnownHosts }
        else { Remove-Item Env:\DEMO2_KNOWN_HOSTS -ErrorAction SilentlyContinue }
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

Export-ModuleMember -Function Invoke-DemoSetup, Save-DemoJournal, Assert-DemoJournal, Get-DemoConfigFingerprint, Receive-DemoEnvelope
