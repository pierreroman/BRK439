Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DemoGuid {
    param([string]$Value, [string]$Name)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Name must be an explicit nonempty GUID."
    }
}

function Import-DemoConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Foundation', 'Runtime')][string]$Phase = 'Runtime'
    )
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($config.schemaVersion -ne 1 -or $config.purpose -cne 'demo2-only') {
        throw 'Only schemaVersion 1 and purpose demo2-only are accepted.'
    }
    foreach ($name in 'tenantId', 'subscriptionId', 'manualRecoveryObjectId') {
        Assert-DemoGuid -Value $config[$name] -Name $name
    }
    foreach ($name in 'location', 'deniedLocation') {
        if ($config[$name] -notmatch '^[a-z][a-z0-9]+$') { throw "$name must be a real explicit Azure location name." }
    }
    if ($config.resourceGroup -notmatch '^rg-demo2-[a-z0-9-]{1,60}$' -or
        $config.hsmName -notmatch '^hsm-demo2-[a-z0-9-]{1,14}$' -or
        $config.nameSuffix -notmatch '^[a-z0-9]{3,10}$') {
        throw 'Use a dedicated rg-demo2-* group, hsm-demo2-* HSM (maximum 24 characters), and 3-10 character nameSuffix.'
    }
    if ($config.allowedLocations.Count -eq 0 -or $config.location -notin $config.allowedLocations -or
        $config.deniedLocation -in $config.allowedLocations) {
        throw 'Primary location must be allowed and deniedLocation must not be allowed.'
    }
    if ($config.policyMode -notin @('sandbox', 'existing-slz')) { throw 'Choose sandbox or existing-slz explicitly.' }
    if ($config.policyMode -eq 'existing-slz' -and $config.existingPolicyAssignmentIds.Count -eq 0) {
        throw 'Existing SLZ mode requires effective policy assignment IDs; it never creates substitute assignments.'
    }
    if ($config.vmSize -notmatch '^Standard_[A-Za-z0-9_]+$' -or
        $config.vmSize -notin $config.allowedConfidentialVmSkus) {
        throw 'Select an available confidential VM SKU from the explicit allowed list.'
    }
    foreach ($name in 'publisher', 'offer', 'sku', 'version') {
        if ([string]::IsNullOrWhiteSpace($config.imageReference[$name])) { throw "imageReference.$name is required." }
    }
    if ($config.initialAdminObjectIds.Count -eq 0) { throw 'Initial HSM administrator object IDs are required.' }
    foreach ($id in $config.initialAdminObjectIds) { Assert-DemoGuid $id 'initialAdminObjectIds' }
    if ($config.budgetAmount -le 0 -or $config.logRetentionDays -lt 30 -or $config.logRetentionDays -gt 730) {
        throw 'Set a positive budgetAmount and logRetentionDays between 30 and 730 before deployment.'
    }
    if ($config.alertEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'An explicit recovery alert recipient is required.' }
    if ($config.network.accessMode -notin @('bastion', 'existing-private-connection')) { throw 'Invalid accessMode.' }
    $networks = @()
    $cidrNames = @('vnetCidr', 'computeSubnetCidr', 'endpointSubnetCidr')
    if ($config.network.accessMode -eq 'bastion') { $cidrNames += 'bastionSubnetCidr' }
    foreach ($name in $cidrNames) {
        $cidr = $config.network[$name]
        if ($cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d|[12]\d|3[0-2])$') { throw "network.$name must be an explicit IPv4 CIDR." }
        $ip, $bits = $cidr.Split('/')
        $address = [System.Net.IPAddress]::Parse($ip)
        if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Only IPv4 demo CIDRs are supported.' }
        $bytes = $address.GetAddressBytes()
        $number = ([uint64]$bytes[0] -shl 24) + ([uint64]$bytes[1] -shl 16) + ([uint64]$bytes[2] -shl 8) + $bytes[3]
        $size = [uint64][math]::Pow(2, (32 - [int]$bits))
        if ($name -eq 'bastionSubnetCidr' -and [int]$bits -gt 26) { throw 'Bastion requires a /26 or larger subnet.' }
        if ($number % $size -ne 0) { throw "network.$name must use its network address." }
        $networks += @{ start = $number; end = $number + $size - 1; name = $name }
    }
    foreach ($subnet in $networks[1..($networks.Count - 1)]) {
        if ($subnet.start -lt $networks[0].start -or $subnet.end -gt $networks[0].end) { throw 'Subnets must be contained in vnetCidr.' }
    }
    for ($i = 1; $i -lt $networks.Count; $i++) {
        for ($j = $i + 1; $j -lt $networks.Count; $j++) {
            if ($networks[$i].start -le $networks[$j].end -and $networks[$j].start -le $networks[$i].end) { throw 'Demo subnets must not overlap.' }
        }
    }
    if ($config.sshUser -notmatch '^[a-z_][a-z0-9_-]{0,30}$' -or
        $config.sshHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$' -or
        $config.sshPort -lt 1 -or $config.sshPort -gt 65535) { throw 'Invalid SSH user, host or port.' }
    if ($config.sshPublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+(?: .*)?$') {
        throw 'Supply a reviewed SSH public key, never a private key.'
    }
    if ($config.container -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]$' -or
        $config.container.Contains('--') -or $config.blob -notmatch '^[a-zA-Z0-9._-]{1,100}\.txt$') {
        throw 'Use a valid private container and a simple synthetic .txt blob name.'
    }
    if ($config.watchdogIntervalSeconds -lt 1 -or $config.watchdogIntervalSeconds -gt 10) { throw 'Watchdog interval must be 1-10 seconds.' }
    foreach ($target in 'Live', 'Twin') {
        $item = $config.targets[$target]
        if ($item.accountName -notmatch '^demo2[a-z0-9]{1,19}$' -or
            $item.keyName -notmatch '^demo2-[a-z0-9-]{1,100}$' -or
            $item.recoveryTimeoutSeconds -lt 30 -or $item.recoveryTimeoutSeconds -gt 3600) {
            throw "$target requires a dedicated demo2 storage/key name and fixed timeout of 30-3600 seconds."
        }
        if ($Phase -eq 'Runtime' -and $item.keyVersion -notmatch '^[a-fA-F0-9]{32}$') { throw "$target must pin an actual key version." }
    }
    if ($config.targets.Live.accountName -eq $config.targets.Twin.accountName -or
        $config.targets.Live.keyName -eq $config.targets.Twin.keyName) { throw 'Live and Twin must use different accounts and key names.' }
    if ($Phase -eq 'Runtime') {
        foreach ($name in 'controllerIdentityClientId', 'controllerPrincipalId', 'liveStorageIdentityPrincipalId', 'twinStorageIdentityPrincipalId') {
            Assert-DemoGuid $config[$name] $name
        }
    }
    if ($config.enableSkr) { throw 'SKR is an optional separately reviewed extension; this base kit must use enableSkr=false.' }
    $schemaPath = Join-Path $PSScriptRoot '../config.schema.json'
    if (-not (Test-Json -Json ($config | ConvertTo-Json -Depth 20) -SchemaFile $schemaPath -ErrorAction Stop)) {
        throw 'Configuration does not match the Demo 2 schema.'
    }
    return $config
}

function Invoke-AzJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $lines = & az @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (exit $LASTEXITCODE): $($lines -join [Environment]::NewLine)" }
    $text = $lines -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($text)) { return ($text | ConvertFrom-Json -AsHashtable) }
}

function Assert-DemoAzureContext {
    param([Parameter(Mandatory)][hashtable]$Config)
    $context = Invoke-AzJson -Arguments @('account', 'show')
    if ($context.id -ne $Config.subscriptionId -or $context.tenantId -ne $Config.tenantId -or
        $context.environmentName -ne 'AzureCloud') { throw 'Azure CLI context must match the explicit tenant, subscription and Azure public cloud.' }
}

function Get-DemoKeyUri {
    param([Parameter(Mandatory)][hashtable]$Config, [ValidateSet('Live', 'Twin')][string]$Target)
    $item = $Config.targets[$Target]
    return "https://$($Config.hsmName).managedhsm.azure.net/keys/$($item.keyName)/$($item.keyVersion)"
}

function Test-IntendedPolicyDenial {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$AssignmentId,
        [Parameter(Mandatory)][string]$DefinitionId,
        [bool]$WithinDeniedError = $false
    )
    if ($Node -is [string]) {
        if ($Node.TrimStart().StartsWith('{') -or $Node.TrimStart().StartsWith('[')) {
            try { $parsed = ConvertFrom-Json -InputObject $Node -AsHashtable -ErrorAction Stop }
            catch { return $false }
            return (Test-IntendedPolicyDenial $parsed $AssignmentId $DefinitionId $WithinDeniedError)
        }
        return $false
    }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('code') -and $Node['code'] -eq 'RequestDisallowedByPolicy') { $WithinDeniedError = $true }
        if ($WithinDeniedError -and $Node['policyAssignmentId'] -eq $AssignmentId -and
            $Node['policyDefinitionId'] -eq $DefinitionId -and
            $Node['evaluationDetails'] -is [System.Collections.IDictionary] -and
            @($Node['evaluationDetails']['evaluatedExpressions']).Count -gt 0) { return $true }
        foreach ($value in $Node.Values) {
            if ($null -ne $value -and (Test-IntendedPolicyDenial $value $AssignmentId $DefinitionId $WithinDeniedError)) { return $true }
        }
    } elseif ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) {
            if ($null -ne $item -and (Test-IntendedPolicyDenial $item $AssignmentId $DefinitionId $WithinDeniedError)) { return $true }
        }
    }
    return $false
}

Export-ModuleMember -Function Import-DemoConfig, Invoke-AzJson, Assert-DemoAzureContext, Get-DemoKeyUri, Assert-DemoGuid, Test-IntendedPolicyDenial
