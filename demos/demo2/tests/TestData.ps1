function New-TestConfiguration {
    $config = Get-Content (Join-Path $PSScriptRoot '../config.example.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($name in 'tenantId', 'subscriptionId', 'manualRecoveryObjectId', 'controllerIdentityClientId', 'controllerPrincipalId', 'liveStorageIdentityPrincipalId', 'twinStorageIdentityPrincipalId') {
        $config[$name] = [guid]::NewGuid().ToString()
    }
    $config.resourceGroup = 'rg-demo2-unittest'
    $config.hsmName = 'hsm-demo2-unittest'
    $config.nameSuffix = 'unittest'
    $config.location = 'testallowed'
    $config.deniedLocation = 'testdenied'
    $config.allowedLocations = @('testallowed')
    $config.vmSize = 'Standard_TEST'
    $config.allowedConfidentialVmSkus = @('Standard_TEST')
    $config.initialAdminObjectIds = @([guid]::NewGuid().ToString())
    $config.imageReference = @{ publisher = 'TEST'; offer = 'TEST'; sku = 'TEST'; version = 'TEST' }
    $config.network.vnetCidr = '10.80.0.0/16'
    $config.network.computeSubnetCidr = '10.80.0.0/24'
    $config.network.endpointSubnetCidr = '10.80.1.0/24'
    $config.network.bastionSubnetCidr = '10.80.2.0/26'
    $config.sshPublicKey = 'ssh-ed25519 VEhJU0lTTk9UQVJFQUxLRVk= synthetic-test-only'
    $config.budgetAmount = 100
    $config.alertEmail = 'test@example.invalid'
    $config.targets.Live.accountName = 'demo2testlive'
    $config.targets.Twin.accountName = 'demo2testtwin'
    $config.targets.Live.keyVersion = '11111111111111111111111111111111'
    $config.targets.Twin.keyVersion = '22222222222222222222222222222222'
    return $config
}
