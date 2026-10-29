#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$InstallationId,
    [Parameter(Mandatory)][guid]$OperationId,
    [Parameter(Mandatory)][ValidateSet('Inspect','Activate','DomainChunk','Keys','Content','Worker','Reduce','Status')][string]$Action,
    [ValidateRange(0,10000)][int]$Chunk = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& /bin/sh -c 'umask 077; test "$(id -u)" = 0'
if ($LASTEXITCODE -ne 0) { throw 'Setup stages require the root managed-command execution identity.' }
$directory = "/var/lib/demo2-setup/$InstallationId"
$kit = "$directory/kit"
$metadata = Get-Content "$directory/setup.json" -Raw | ConvertFrom-Json -AsHashtable
if ($metadata.installationId -ne $InstallationId) { throw 'Guest installation identity mismatch.' }
Import-Module "$kit/scripts/Demo.Common.psm1"
$configPath = "$directory/config.json"
$config = Import-DemoConfig $configPath -Phase Foundation
function Save-GuestConfig {
    $temporary = "$configPath.tmp"
    [IO.File]::WriteAllText($temporary,($config | ConvertTo-Json -Depth 30))
    & chmod 0600 $temporary
    if ($LASTEXITCODE -ne 0) { throw 'Guest configuration protection failed.' }
    [IO.File]::Move($temporary,$configPath,$true)
}
function Login-Bootstrap {
    $null = Invoke-AzJson @('login','--identity','--client-id',$metadata.bootstrapClientId)
    Assert-DemoAzureContext $config
}
function Get-DomainEnvelope {
    $path = "/mnt/dispo-keys/$InstallationId/security-domain.cms"
    if (-not (Test-Path -LiteralPath $path)) { throw 'Encrypted security domain missing; reconcile activation before proceeding.' }
    return ,([IO.File]::ReadAllBytes($path))
}
function Get-RoleProperties {
    param([hashtable]$Role)
    if ($Role.ContainsKey('properties')) { return $Role.properties }
    return $Role
}
$result = @{}
switch ($Action) {
    Inspect {
        $hostKey = (Get-Content /etc/ssh/ssh_host_ed25519_key.pub -Raw).Trim()
        $result = @{ hostKey=$hostKey; sourceReady=$true }
    }
    Activate {
        Login-Bootstrap
        $custody = "/mnt/dispo-keys/$InstallationId"
        & install -d -m 0700 $custody
        if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare protected custody directory.' }
        $raw = "$custody/security-domain.json"
        $envelope = "$custody/security-domain.cms"
        if (-not (Test-Path -LiteralPath $envelope)) {
            if (-not (Test-Path -LiteralPath $raw)) {
                $hsm = Invoke-AzJson @('keyvault','show','--hsm-name',$config.hsmName)
                if ($hsm.properties.securityDomainProperties.activationStatus -ne 'NotActivated') {
                    throw 'HSM already activated but no local domain artifact: explicit custody reconciliation is required; no fresh activation attempted.'
                }
                $certificates = @(1..4 | ForEach-Object { "$directory/wrapping-{0:d2}.cer" -f $_ })
                $arguments = @('keyvault','security-domain','download','--hsm-name',$config.hsmName,'--sd-wrapping-keys') +
                    $certificates + @('--sd-quorum','3','--security-domain-file',$raw,'--only-show-errors')
                $null = & az @arguments 2>&1
                if ($LASTEXITCODE -ne 0) { throw 'Activation did not complete successfully. Preserve protected files and reconcile HSM state; do not generate new wrapping keys.' }
                & chmod 0600 $raw
                if ($LASTEXITCODE -ne 0) { throw 'Domain protection failed.' }
            }
            $recipient = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText("$directory/recipient.cer"))
            try {
                Add-Type -AssemblyName System.Security.Cryptography.Pkcs
                $cms = [Security.Cryptography.Pkcs.EnvelopedCms]::new(
                    [Security.Cryptography.Pkcs.ContentInfo]::new([IO.File]::ReadAllBytes($raw)))
                $cms.Encrypt([Security.Cryptography.Pkcs.CmsRecipient]::new($recipient))
                [IO.File]::WriteAllBytes("$envelope.tmp",$cms.Encode())
                & chmod 0600 "$envelope.tmp"
                if ($LASTEXITCODE -ne 0) { throw 'Envelope protection failed.' }
                [IO.File]::Move("$envelope.tmp",$envelope,$true)
            } finally { $recipient.Dispose() }
        }
        $bytes = Get-DomainEnvelope
        $result = @{ bytes=$bytes.Length; chunks=[int][math]::Ceiling($bytes.Length/1200.0); digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
    }
    DomainChunk {
        $bytes = Get-DomainEnvelope
        $offset = $Chunk * 1200
        if ($offset -ge $bytes.Length) { throw 'Envelope chunk outside bounds.' }
        $count = [math]::Min(1200,$bytes.Length-$offset)
        $result = @{ index=$Chunk; bytes=$bytes.Length; data=[Convert]::ToBase64String($bytes,$offset,$count) }
    }
    Keys {
        Login-Bootstrap
        if (-not (Test-Path "$directory/domain-backup-verified.json")) { throw 'Local domain backup receipt missing.' }
        $roleName = "Demo2-$($config.nameSuffix)-BootstrapCreateRead"
        $roles = @(Invoke-AzJson @('keyvault','role','definition','list','--hsm-name',$config.hsmName))
        $matching = @($roles | Where-Object { (Get-RoleProperties $_).roleName -eq $roleName })
        if ($matching.Count -gt 1) { throw 'Ambiguous bootstrap role.' }
        if ($matching.Count -eq 0) {
            $definition = @{roleName=$roleName; description='Temporary dedicated demo key creation/read'; actions=@(); notActions=@(); dataActions=@('Microsoft.KeyVault/managedHsm/keys/read/action','Microsoft.KeyVault/managedHsm/keys/create'); notDataActions=@()}
            $path = "$directory/bootstrap-role.json"
            $definition | ConvertTo-Json -Depth 6 | Set-Content $path
            $matching = @(Invoke-AzJson @('keyvault','role','definition','create','--hsm-name',$config.hsmName,'--role-definition',"@$path"))
        }
        $properties = Get-RoleProperties $matching[0]
        $expected = @('Microsoft.KeyVault/managedHsm/keys/read/action','Microsoft.KeyVault/managedHsm/keys/create')
        $permission = @($properties.permissions)
        if ($permission.Count -ne 1 -or @($permission[0].actions).Count -or @($permission[0].notActions).Count -or
            @($permission[0].notDataActions).Count -or
            (@($permission[0].dataActions | Sort-Object) -join ',') -cne (@($expected | Sort-Object) -join ',')) { throw 'Existing bootstrap role differs from the exact approved permissions.' }
        $roleId = if ($matching[0].ContainsKey('name')) { $matching[0].name } else { ($matching[0].id -split '/')[-1] }
        foreach ($target in 'Live','Twin') {
            $scope = "/keys/$($config.targets[$target].keyName)"
            $assignments = @(Invoke-AzJson @('keyvault','role','assignment','list','--hsm-name',$config.hsmName,'--scope',$scope))
            if (@($assignments | Where-Object {
                $p = Get-RoleProperties $_
                $p.principalId -eq $metadata.bootstrapPrincipalId -and $p.roleDefinitionId -match ([regex]::Escape($roleId) + '$')
            }).Count -eq 0) {
                $null = Invoke-AzJson @('keyvault','role','assignment','create','--hsm-name',$config.hsmName,'--scope',$scope,'--role',$roleName,'--assignee-object-id',$metadata.bootstrapPrincipalId)
            }
        }
        $null = & "$kit/scripts/Initialize-Hsm.ps1" -ConfigPath $configPath -AuthorizeLiveChanges -ActivationConfirmed -ResolvedConfigPath $configPath -Confirm:$false
        $config = Import-DemoConfig $configPath -Phase Runtime
        Save-GuestConfig
        $result = @{ targets=$config.targets }
    }
    Content {
        Login-Bootstrap
        $null = & "$kit/scripts/Initialize-Content.ps1" -ConfigPath $configPath -AuthorizeLiveChanges -Confirm:$false
        $result = @{ uploaded=$true }
    }
    Worker {
        $marker = "$directory/worker.json"
        if (-not (Test-Path $marker)) {
            & systemctl is-active --quiet demo2-watchdog.service
            if ($LASTEXITCODE -eq 0) {
                $installed = Import-DemoConfig '/etc/demo2/config.json' -Phase Runtime
                if (($installed | ConvertTo-Json -Depth 30 -Compress) -cne ($config | ConvertTo-Json -Depth 30 -Compress)) { throw 'Active worker configuration differs; refuse adoption/reinstallation.' }
                foreach ($name in 'Demo.Worker.psm1','Start-Watchdog.ps1','Submit-Request.ps1') {
                    if ((Get-FileHash "$kit/host/$name").Hash -ne (Get-FileHash "/opt/demo2/host/$name").Hash) { throw 'Active worker source differs; reconcile without overwriting its recovery state.' }
                }
            } else {
                $null = & "$kit/scripts/Install-Watchdog.ps1" -ConfigPath $configPath -AdminSshUser demoadmin -OperatorPublicKeyPath "$directory/operator.pub" -AuthorizeHostChanges -LocalGuest -Confirm:$false
            }
            @{ installed=$true } | ConvertTo-Json | Set-Content $marker
        }
        & systemctl is-active --quiet demo2-watchdog.service
        if ($LASTEXITCODE -ne 0) { throw 'Installed watchdog is not active; inspect recovery state before any reinstall.' }
        $result = @{ worker=$true }
    }
    Reduce {
        if (Test-Path "$directory/reduced.json") {
            $result = @{ localGrantsRemoved=$true }
            break
        }
        Login-Bootstrap
        $null = Get-DomainEnvelope
        if (-not (Test-Path "$directory/domain-backup-verified.json")) { throw 'Backup receipt missing.' }
        if (Test-Path "$directory/reduce-intent.json") {
            try {
                $null = Invoke-AzJson @('keyvault','role','assignment','list','--hsm-name',$config.hsmName,'--scope','/')
            } catch {
                if ($_.Exception.Message -notmatch '\bForbidden\b|\b403\b') { throw }
                $raw = "/mnt/dispo-keys/$InstallationId/security-domain.json"
                if (Test-Path -LiteralPath $raw) { Remove-Item -LiteralPath $raw -Force -ErrorAction Stop }
                @{ removed=$true } | ConvertTo-Json | Set-Content "$directory/reduced.json"
                $result = @{ localGrantsRemoved=$true }
                break
            }
        }
        $root = @()
        foreach ($scope in @("/keys/$($config.targets.Live.keyName)","/keys/$($config.targets.Twin.keyName)",'/keys','/')) {
            $assignments = @(Invoke-AzJson @('keyvault','role','assignment','list','--hsm-name',$config.hsmName,'--scope',$scope))
            $owned = @($assignments | Where-Object { (Get-RoleProperties $_).principalId -eq $metadata.bootstrapPrincipalId })
            foreach ($assignment in $owned) {
                $p = Get-RoleProperties $assignment
                if ($p.scope -eq '/') { $root += $assignment; continue }
                $null = Invoke-AzJson @('keyvault','role','assignment','delete','--hsm-name',$config.hsmName,'--ids',$assignment.id)
            }
            if ($scope -ne '/') {
                $remaining = @(Invoke-AzJson @('keyvault','role','assignment','list','--hsm-name',$config.hsmName,'--scope',$scope) |
                    Where-Object { $p=Get-RoleProperties $_; $p.principalId -eq $metadata.bootstrapPrincipalId -and $p.scope -eq $scope })
                if ($remaining.Count) { throw 'Bootstrap key grant removal not yet verified; resume after propagation.' }
            }
        }
        $root = @($root | Sort-Object id -Unique)
        if ($root.Count -ne 1) { throw 'Expected exactly one temporary bootstrap root administrator; reconcile unknown grants.' }
        # Persist intent before removing our own last role. A lost response must not recreate it.
        $root[0] | ConvertTo-Json -Depth 10 | Set-Content "$directory/reduce-intent.json"
        $null = Invoke-AzJson @('keyvault','role','assignment','delete','--hsm-name',$config.hsmName,'--ids',$root[0].id)
        try {
            $null = Invoke-AzJson @('keyvault','role','assignment','list','--hsm-name',$config.hsmName,'--scope','/')
            throw 'Bootstrap administrator access remains; wait for propagation and reconcile.'
        } catch {
            if ($_.Exception.Message -notmatch '\bForbidden\b|\b403\b') { throw }
        }
        $raw = "/mnt/dispo-keys/$InstallationId/security-domain.json"
        if (Test-Path -LiteralPath $raw) { Remove-Item -LiteralPath $raw -Force -ErrorAction Stop }
        @{ removed=$true } | ConvertTo-Json | Set-Content "$directory/reduced.json"
        $result = @{ localGrantsRemoved=$true }
    }
    Status {
        Import-Module "$kit/host/Demo.Worker.psm1" -Force
        $config = Import-DemoConfig $configPath -Phase Runtime
        $heartbeat = Get-Content /var/spool/demo2/responses/heartbeat.json -Raw | ConvertFrom-Json
        if (([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($heartbeat.utc)).TotalSeconds -gt 30) { throw 'Watchdog heartbeat is stale.' }
        $reads = @{}
        foreach ($target in 'Live','Twin') {
            Assert-StorageKeyBinding -Config $config -Target $target
            $read = Read-DemoBlob -Config $config -Target $target
            if ($read.status -ne 200) { throw "$target baseline failed: $($read.status)/$($read.errorCode)" }
            $reads[$target] = @{ status=$read.status; requestId=$read.requestId }
        }
        $result = @{ baseline=$reads; heartbeat=$heartbeat.utc; demoReady=$false; state='ConfiguredNeedsRehearsal' }
    }
}
@{ installationId=$InstallationId; operationId=$OperationId.ToString('D'); action=$Action; ok=$true; result=$result } | ConvertTo-Json -Depth 12 -Compress
