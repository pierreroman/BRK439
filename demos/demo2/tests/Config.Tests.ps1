BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Common.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Offline configuration boundary' {
    BeforeEach {
        $config = New-TestConfiguration
        $path = Join-Path $TestDrive 'config.json'
    }
    It 'accepts a fully explicit synthetic runtime configuration' {
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        (Import-DemoConfig $path).purpose | Should -Be 'demo2-only'
    }
    It 'refuses the deliberately incomplete shipped example' {
        { Import-DemoConfig (Join-Path $PSScriptRoot '../config.example.json') } | Should -Throw
    }
    It 'refuses a production or arbitrary resource group' {
        $config.resourceGroup = 'production'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*dedicated*'
    }
    It 'refuses an unpinned key version at runtime but allows foundation staging' {
        $config.targets.Live.keyVersion = ''
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*pin*'
        (Import-DemoConfig $path -Phase Foundation).targets.Live.keyVersion | Should -Be ''
    }
    It 'requires different live and twin keys' {
        $config.targets.Twin.keyName = $config.targets.Live.keyName
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*different*'
    }
    It 'refuses a denied region in the allowed set' {
        $config.allowedLocations += $config.deniedLocation
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*deniedLocation*'
    }
    It 'refuses overlapping subnets' {
        $config.network.endpointSubnetCidr = $config.network.computeSubnetCidr
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*overlap*'
    }
    It 'refuses a subnet outside the VNet' {
        $config.network.endpointSubnetCidr = '10.81.1.0/24'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*contained*'
    }
    It 'refuses an option-like SSH destination' {
        $config.sshHost = '-oProxyCommand=bad'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*SSH*'
    }
    It 'requires live SLZ assignment references rather than inventing them' {
        $config.policyMode = 'existing-slz'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*assignment IDs*'
    }
    It 'bounds the fixed recovery timeout' {
        $config.targets.Live.recoveryTimeoutSeconds = 0
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*timeout*'
    }
    It 'rejects unknown configuration fields rather than silently ignoring them' {
        $config.unrecognizedSetting = 'ignored would be unsafe'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw
    }
    It 'rejects a nonnumeric recovery timeout through the schema' {
        $config.targets.Live.recoveryTimeoutSeconds = '180'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw
    }
    It 'rejects an oversized HSM name before deployment' {
        $config.hsmName = 'hsm-demo2-123456789012345'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*24 characters*'
    }
    It 'rejects a Bastion subnet overlapping the compute subnet' {
        $config.network.bastionSubnetCidr = '10.80.0.0/26'
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        { Import-DemoConfig $path } | Should -Throw '*overlap*'
    }
}
