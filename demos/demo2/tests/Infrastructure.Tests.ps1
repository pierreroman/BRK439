BeforeAll {
    $script:resources = @()
    $script:compiledFiles = @()
    foreach ($source in Get-ChildItem (Join-Path $PSScriptRoot '../infra') -Recurse -Filter '*.bicep' -File) {
        $output = Join-Path $TestDrive "$($source.BaseName)-$([guid]::NewGuid().ToString('N')).json"
        & az bicep build --file $source.FullName --outfile $output
        if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $($source.Name)" }
        Write-Information "BUILD PASS: $($source.Name)" -InformationAction Continue
        $template = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -AsHashtable
        $script:compiledFiles += $source.Name
        if ($source.Name -eq 'storage-account.bicep') { $script:storageTemplate = $template }
        if ($source.Name -eq 'monitoring.bicep') { $script:monitoringTemplate = $template }
        if ($source.Name -ne 'policy-example.bicep') { $script:resources += @($template.resources) }
    }
}

Describe 'Compiled infrastructure safety properties (not Azure deployment)' {
    It 'compiles the staged infrastructure rather than merely matching source strings' {
        $script:compiledFiles | Should -Contain 'main.bicep'
        $script:compiledFiles.Count | Should -BeGreaterThan 2
    }
    It 'configures private identity-only storage and compiles an explicit pinned CMK contract' {
        $accounts = @($script:resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts')
        $accounts.Count | Should -BeGreaterThan 0
        foreach ($account in $accounts) {
            $account.properties.allowSharedKeyAccess | Should -BeFalse
            $account.properties.allowBlobPublicAccess | Should -BeFalse
            $account.properties.publicNetworkAccess | Should -Be 'Disabled'
            $account.properties.minimumTlsVersion | Should -Be 'TLS1_2'
            $account.properties.supportsHttpsTrafficOnly | Should -BeTrue
            $account.properties.networkAcls.defaultAction | Should -Be 'Deny'
            $account.identity.type | Should -Be 'UserAssigned'
            $script:storageTemplate.parameters.keySource.defaultValue | Should -Be 'Microsoft.Keyvault'
            $account.properties.encryption | Should -Match "'keyversion', parameters\('keyVersion'\)"
            $account.properties.encryption | Should -Match "'userAssignedIdentity', parameters\('identityId'\)"
        }
    }
    It 'enables HSM purge protection and an explicit trusted-service exception' {
        $hsms = @($script:resources | Where-Object type -eq 'Microsoft.KeyVault/managedHSMs')
        $hsms.Count | Should -BeGreaterThan 0
        foreach ($hsm in $hsms) {
            $hsm.properties.enablePurgeProtection | Should -BeTrue
            $hsm.properties.publicNetworkAccess | Should -Be 'Disabled'
            $hsm.properties.networkAcls.defaultAction | Should -Be 'Deny'
            $hsm.properties.networkAcls.bypass | Should -Be 'AzureServices'
        }
    }
    It 'requires a confidential VM without password authentication' {
        $vms = @($script:resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines')
        $vms.Count | Should -BeGreaterThan 0
        foreach ($vm in $vms) {
            $vm.properties.securityProfile.securityType | Should -Be 'ConfidentialVM'
            $vm.properties.securityProfile.uefiSettings.secureBootEnabled | Should -BeTrue
            $vm.properties.securityProfile.uefiSettings.vTpmEnabled | Should -BeTrue
            $vm.properties.osProfile.linuxConfiguration.disablePasswordAuthentication | Should -BeTrue
        }
    }
    It 'creates real Deny policies instead of audit-only substitutes' {
        $definitions = @($script:resources | Where-Object type -eq 'Microsoft.Authorization/policyDefinitions')
        $definitions.Count | Should -BeGreaterOrEqual 2
        foreach ($definition in $definitions) { $definition.properties.policyRule.then.effect | Should -Be 'Deny' }
    }
    It 'retains a dedicated private-access-disabled custody disk independent of demo CMKs' {
        $disks = @($script:resources | Where-Object type -eq 'Microsoft.Compute/disks')
        $disks.Count | Should -BeGreaterThan 0
        foreach ($disk in $disks) {
            $disk.sku.name | Should -Be 'StandardSSD_LRS'
            $disk.properties.creationData.createOption | Should -Be 'Empty'
            $disk.properties.diskSizeGB | Should -Be 32
            $disk.properties.encryption.type | Should -Be 'EncryptionAtRestWithPlatformKey'
            $disk.properties.networkAccessPolicy | Should -Be 'DenyAll'
            $disk.properties.publicNetworkAccess | Should -Be 'Disabled'
        }
        foreach ($vm in @($script:resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines')) {
            $vm.properties.storageProfile.dataDisks.Count | Should -Be 1
            $vm.properties.storageProfile.dataDisks[0].lun | Should -Be 0
            $vm.properties.storageProfile.dataDisks[0].createOption | Should -Be 'Attach'
            $vm.properties.storageProfile.dataDisks[0].deleteOption | Should -Be 'Detach'
            $vm.properties.storageProfile.dataDisks[0].managedDisk.id | Should -Match 'custody'
        }
    }
    It 'routes independent recovery telemetry and alerts outside the revocable storage accounts' {
        @($script:resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules').Count | Should -BeGreaterThan 0
        @($script:resources | Where-Object type -eq 'Microsoft.Insights/scheduledQueryRules').Count | Should -BeGreaterThan 0
        $script:monitoringTemplate.variables.queries.name | Should -Contain 'heartbeat-missing'
        $script:monitoringTemplate.variables.queries.name | Should -Contain 'recovery-overdue'
        @($script:resources | Where-Object type -eq 'Microsoft.Insights/actionGroups').Count | Should -BeGreaterThan 0
    }
    It 'uses a supported five-minute alert cadence while preserving the one-day overdue query horizon' {
        $alerts = @($script:monitoringTemplate.resources | Where-Object type -eq 'Microsoft.Insights/scheduledQueryRules')
        $alerts.Count | Should -BeGreaterThan 0
        foreach ($alert in $alerts) {
            $alert.properties.evaluationFrequency | Should -Be 'PT5M'
        }
        ($script:monitoringTemplate.variables.queries | Where-Object name -eq 'recovery-overdue').window | Should -Be 'P1D'
    }
}
