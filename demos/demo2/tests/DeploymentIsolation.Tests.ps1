BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
}
BeforeAll {
    $guard=Get-Command az -CommandType Function -ErrorAction Ignore
    $script:originalAzureGuard=if ($guard) { $guard.ScriptBlock } else { $null }
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
    $compiled=Join-Path $TestDrive 'isolation-main.json'
    & (Join-Path $env:USERPROFILE '.azure\bin\bicep.exe') build (Join-Path $PSScriptRoot '..\infra\main.bicep') --outfile $compiled --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Local Bicep compilation failed.' }
    $script:compiled=Get-Content $compiled -Raw | ConvertFrom-Json -AsHashtable
    function Get-TestPolicyDeploymentName {
        param([string]$Suffix)
        $policy=@($script:compiled.resources | Where-Object name -Match 'sandbox-policy')
        if ($policy.Count -ne 1) { throw 'Expected exactly one subscription policy module.' }
        $expression=$policy[0].name
        if ($expression -match "^\[format\('([^']+)', parameters\('config'\)\.nameSuffix\)\]$") {
            return $Matches[1] -f $Suffix
        }
        if ($expression -match '^demo2-[a-z-]+$') { return $expression }
        throw 'Unexpected policy deployment name expression.'
    }
}

AfterAll {
    if ($script:originalAzureGuard) { Set-Item function:global:az $script:originalAzureGuard }
    else { Remove-Item function:az -ErrorAction Ignore }
}

Describe 'Subscription deployment location history (offline ARM fixture)' {
    BeforeEach {
        $script:history=@{'demo2-sandbox-policy'=@{location='westus2';owner='earlier-install'}}
        function Submit-TestDeployment {
            param([string]$Name,[string]$Location)
            if ($script:history.ContainsKey($Name) -and $script:history[$Name].location -ne $Location) {
                throw "InvalidDeploymentLocation: $Name already exists in $($script:history[$Name].location), not $Location"
            }
            if (-not $script:history.ContainsKey($Name)) { $script:history[$Name]=@{location=$Location;owner='new-install'} }
        }
    }

    It 'reproduces the reported uppercase fixed-name collision without Azure' {
        { Submit-TestDeployment 'DEMO2-SANDBOX-POLICY' 'westus' } | Should -Throw '*InvalidDeploymentLocation*westus2*'
        $script:history['demo2-sandbox-policy'].owner | Should -Be 'earlier-install'
    }
    It 'uses compiled install-specific names across regions and stable retry names without touching earlier history' {
        $earlier=$script:history['demo2-sandbox-policy'] | ConvertTo-Json -Compress
        $first=Get-TestPolicyDeploymentName 'alpha12345'
        $second=Get-TestPolicyDeploymentName 'bravo12345'
        $first | Should -Not -Be $second
        $first.Length | Should -BeLessOrEqual 64
        $second.Length | Should -BeLessOrEqual 64
        Submit-TestDeployment $first 'westus'
        Submit-TestDeployment $second 'westus2'
        Submit-TestDeployment (Get-TestPolicyDeploymentName 'alpha12345') 'westus'
        $script:history.Count | Should -Be 3
        ($script:history['demo2-sandbox-policy'] | ConvertTo-Json -Compress) | Should -Be $earlier
    }
}

Describe 'Policy resource scope and exact denial IDs remain isolated (offline)' {
        It 'keeps subscription definitions suffix-specific and assignments inside the dedicated group' {
            $module=@($script:compiled.resources | Where-Object name -Match 'sandbox-policy')[0]
            $policy=$module.properties.template
            $policy.variables.prefix | Should -Be "[format('demo2-{0}', parameters('config').nameSuffix)]"
            $definitions=@($policy.resources | Where-Object type -eq 'Microsoft.Authorization/policyDefinitions')
            $definitions.Count | Should -Be 2
            foreach ($definition in $definitions) { $definition.name | Should -Match "variables\('prefix'\)" }
            $assignments=@($policy.resources | Where-Object type -eq 'Microsoft.Resources/deployments')
            $assignments.Count | Should -Be 1
            $assignments[0].resourceGroup | Should -Be "[parameters('config').resourceGroup]"
            foreach ($name in @('demo2-foundation','demo2-storage')) {
                $groupModule=@($script:compiled.resources | Where-Object name -eq $name)
                $groupModule.Count | Should -Be 1
                $groupModule[0].resourceGroup | Should -Be "[parameters('config').resourceGroup]"
            }
        }
        It 'retains exact install-specific expected Deny IDs for <Example>' -ForEach @(
            @{Example='denied-region';Assignment='locations';BuiltIn=$true},
            @{Example='platform-key';Assignment='cmk';BuiltIn=$false}
        ) {
            foreach ($suffix in @('alpha12345','bravo12345')) {
                $config=New-TestConfiguration
                $config.nameSuffix=$suffix; $config.resourceGroup="rg-demo2-$suffix"
                $path=Join-Path $TestDrive "$suffix.json"
                $config | ConvertTo-Json -Depth 30 | Set-Content $path
                $result=& (Join-Path $PSScriptRoot '..\scripts\Test-PolicyExamples.ps1') -ConfigPath $path -Example $Example
                $scope="/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)"
                $result.ExpectedAssignment | Should -Be "$scope/providers/Microsoft.Authorization/policyAssignments/demo2-$suffix-$Assignment"
                if ($BuiltIn) { $result.ExpectedDefinition | Should -Be '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c' }
                else { $result.ExpectedDefinition | Should -Be "/subscriptions/$($config.subscriptionId)/providers/Microsoft.Authorization/policyDefinitions/demo2-$suffix-storage-cmk" }
            }
        }
    }

    Describe 'Stable standalone deployment/probe names (native CLI mocked)' {
        BeforeEach {
            $config=New-TestConfiguration
            $path=Join-Path $TestDrive 'stable-config.json'
            $config | ConvertTo-Json -Depth 30 | Set-Content $path
            $script:cliCalls=[Collections.Generic.List[object]]::new()
            $global:demo2IsolationCliFixture=@{config=$config;calls=$script:cliCalls}
            function global:az {
                $fixture=$global:demo2IsolationCliFixture
                $fixture.calls.Add([object]@($args))
                $global:LASTEXITCODE=0
                if ($args[0] -eq 'account' -and $args[1] -eq 'show') { return (@{id=$fixture.config.subscriptionId;tenantId=$fixture.config.tenantId;environmentName='AzureCloud'} | ConvertTo-Json -Compress) }
                if ($args[0] -eq 'deployment' -and $args[1] -in 'sub','group' -and $args[2] -eq 'create') { return '{"properties":{"outputs":{}}}' }
                throw 'OFFLINE GUARD: unexpected mocked CLI command; real CLI cannot be called'
            }
        }
        AfterEach {
            if ($script:originalAzureGuard) { Set-Item function:global:az $script:originalAzureGuard }
            else { Remove-Item function:az -ErrorAction Ignore }
            Remove-Variable demo2IsolationCliFixture -Scope Global
        }
        It 'uses stable bounded group probe/history and candidate names on retry' {
            $script=Join-Path $PSScriptRoot '..\scripts\Test-PolicyExamples.ps1'
            $first=& $script -ConfigPath $path -Example positive -AuthorizeLiveChanges -PolicyReviewConfirmed -Confirm:$false | Where-Object { $_ -isnot [string] }
            $second=& $script -ConfigPath $path -Example positive -AuthorizeLiveChanges -PolicyReviewConfirmed -Confirm:$false | Where-Object { $_ -isnot [string] }
            $first.Candidate | Should -Be $second.Candidate
            $first.Deployment | Should -Be $second.Deployment
            $first.Candidate.Length | Should -BeLessOrEqual 24
            $first.Deployment.Length | Should -BeLessOrEqual 64
            $first.Deployment | Should -Be "demo2-policy-$($config.nameSuffix)-positive"
        }
        It 'uses a stable subscription name with <Description>' -ForEach @(
            @{Description='a portable installation ID';InstallId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';Expected='demo2-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
            @{Description='a standalone configuration suffix';InstallId='';Expected='demo2-unittest-foundation'}
        ) {
            $script=Join-Path $PSScriptRoot '..\scripts\Deploy-Demo.ps1'
            foreach ($attempt in 1,2) {
                $null=& $script -ConfigPath $path -InstallationId $InstallId -AuthorizeDeployment -PreflightReviewed -Confirm:$false
            }
            $calls=@($script:cliCalls | Where-Object { $_[0] -eq 'deployment' })
            $calls.Count | Should -Be 2
            foreach ($call in $calls) { $call[[array]::IndexOf($call,'--name')+1] | Should -Be $Expected }
        }
    }

    Describe 'Failed foundation policy-location reconciliation (read-only ARM mocks)' {
        InModuleScope Demo.Setup {
            BeforeAll { . (Join-Path $script:Kit 'tests\TestData.ps1') }
            BeforeEach {
                $config=New-TestConfiguration
                $config.location='westus'; $config.allowedLocations=@('westus'); $config.deniedLocation='westus2'
                $script:journal=@{schemaVersion=1;installationId=[guid]::NewGuid().ToString('N');config=$config
                    configFingerprint=(Get-DemoConfigFingerprint $config);sourceFingerprint='542448B679ED37A2F1A86FDD237FA2841516621A38D83A25654CE9631D9955CF'
                    status='Preparing';receipts=@{Custody=@{verifiedUtc='synthetic'}};resources=@{};pendingAgent=$null}
                $path=Join-Path $TestDrive 'retained-journal.json'
                Save-DemoJournal $script:journal $path
                $script:groupExists=$true
                $script:groupOwner=$script:journal.installationId
                $script:outerAbsent=$false
                $script:legacyAbsent=$false
                $script:definitionExists=$false
                $script:failureCode=$null
                $script:groupDeployments=@(@{properties=@{provisioningState='Succeeded'}})
                $script:legacyLocation='westus2'
                $script:outer=@{location='westus';properties=@{provisioningState='Failed'
                    parameters=@{installationId=@{value=$script:journal.installationId};stage=@{value='foundation'}
                        bootstrapEnabled=@{value=$true};config=@{value=($config | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable)}}
                    error=@{code='DeploymentFailed';details=@(@{code='InvalidDeploymentLocation';message="Invalid deployment location 'westus'. The deployment 'DEMO2-SANDBOX-POLICY' already exists in location 'westus2'."})}}}
                Mock Get-DemoSourceFingerprint {
                    if ($PolicyIsolationBase) { return 'B1931C627719F5ABFBE310DF448C5B6B93C003E73621141F5B9E2EB65DF20923' }
                    'synthetic-current'
                }
                Mock Assert-DemoAzureContext {}
                Mock Write-Host {}
                Mock az { throw 'OFFLINE: unexpected native Azure CLI' }
                Mock Invoke-AzJson {
                    if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'exists') { return $script:groupExists }
                    if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'show') { return @{tags=@{purpose='demo2-only';installationId=$script:groupOwner}} }
                    if ($Arguments[0] -eq 'deployment' -and $Arguments[1] -eq 'group' -and $Arguments[2] -eq 'list') { return $script:groupDeployments }
                    if ($Arguments[0] -ne 'rest' -or $Arguments[2] -ne 'get') { throw 'OFFLINE: mutation or unexpected operation' }
                    $uri=$Arguments[[array]::IndexOf($Arguments,'--url')+1]
                    $id=([uri]$uri).AbsolutePath
                    if ($script:failureCode) { throw ('Azure CLI failed: ERROR: {"code":"' + $script:failureCode + '","details":[{"code":"ResourceNotFound"}]}') }
                    if ($uri -match '/policyDefinitions/') {
                        if ($script:definitionExists) { return @{id=$id} }
                        throw 'Azure CLI failed: ERROR: {"code":"PolicyDefinitionNotFound"}'
                    }
                    if ($uri -match '/demo2-sandbox-policy\?') {
                        if ($script:legacyAbsent) { throw 'Azure CLI failed: ERROR: {"code":"DeploymentNotFound"}' }
                        return @{id=$id;location=$script:legacyLocation}
                    }
                    if ($script:outerAbsent) { throw 'Azure CLI failed: ERROR: {"code":"DeploymentNotFound"}' }
                    $script:outer.id=$id
                    return $script:outer
                }
            }
            It 'migrates only after matching failed history/target, owned group, terminal children and unused policy names' {
                $before=$script:journal.configFingerprint
                Update-DemoLocalPromptSource $script:journal $path
                $updated=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
                $updated.sourceFingerprint | Should -Be 'synthetic-current'
                $updated.configFingerprint | Should -Be $before
                $updated.receipts.Custody.verifiedUtc | Should -Be 'synthetic'
                $updated.receipts.PolicyIsolation.deploymentName | Should -Be "demo2-$($script:journal.installationId)"
                $updated.receipts.PolicyIsolation.ownedGroupExists | Should -BeTrue
                Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'create' -or $Arguments -contains 'delete' -or $Arguments -contains 'put' }
            }
            It 'also handles collision at what-if before any group/deployment was created' {
                $script:outerAbsent=$true; $script:groupExists=$false
                Update-DemoLocalPromptSource $script:journal $path
                $updated=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
                $updated.receipts.PolicyIsolation.ownedGroupExists | Should -BeFalse
                Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[1] -eq 'group' }
            }
            It 'compares ARM configuration structurally without treating reordered object properties as target drift' {
                $reordered=[ordered]@{}
                $keys=@($config.network.get_Keys())
                [array]::Reverse($keys)
                foreach ($key in $keys) { $reordered[$key]=$config.network[$key] }
                $script:outer.properties.parameters.config.value.network=$reordered
                Update-DemoLocalPromptSource $script:journal $path
                (Get-Content $path -Raw | ConvertFrom-Json -AsHashtable).sourceFingerprint | Should -Be 'synthetic-current'
            }
            It 'preserves source/custody and stops for <Problem>' -ForEach @(
                @{Problem='wrong group owner';Kind='owner'},
                @{Problem='missing group with retained failed history';Kind='missing-group'},
                @{Problem='missing correlated outer history with retained resources';Kind='missing'},
                @{Problem='active outer operation';Kind='active'},
                @{Problem='wrong immutable target';Kind='target'},
                @{Problem='another nested deployment collision';Kind='other-collision'},
                @{Problem='a deployment whose name only starts with the legacy name';Kind='prefix-collision'},
                @{Problem='unknown child operation';Kind='child'},
                @{Problem='existing policy definitions of unproved ownership';Kind='policy'},
                @{Problem='missing legacy collision record';Kind='legacy'},
                @{Problem='legacy record now in the same region';Kind='region'},
                @{Problem='authorization failure, not a missing record';Kind='forbidden'}
            ) {
                switch ($Kind) {
                    owner { $script:groupOwner='another-install' }
                    missing-group { $script:groupExists=$false }
                    missing { $script:outerAbsent=$true }
                    active { $script:outer.properties.provisioningState='Running' }
                    target { $script:outer.properties.parameters.config.value.location='eastus' }
                    other-collision { $script:outer.properties.error.details[0].message='Another nested deployment exists elsewhere' }
                    prefix-collision { $script:outer.properties.error.details[0].message="Deployment 'demo2-sandbox-policy-another' already exists in westus2" }
                    child { $script:groupDeployments=@(@{properties=@{provisioningState='Running'}}) }
                    policy { $script:definitionExists=$true }
                    legacy { $script:legacyAbsent=$true }
                    region { $script:legacyLocation='westus' }
                    forbidden { $script:failureCode='AuthorizationFailed' }
                }
                $before=(Get-FileHash $path).Hash
                { Update-DemoLocalPromptSource $script:journal $path } | Should -Throw
                (Get-FileHash $path).Hash | Should -Be $before
                Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'create' -or $Arguments -contains 'delete' -or $Arguments -contains 'put' }
            }
            It 'accepts embedded ARM error JSON only when the exact legacy policy deployment caused the location failure' {
                $script:outer.properties.error=@{code='DeploymentFailed';message=($script:outer.properties.error | ConvertTo-Json -Depth 20 -Compress)}
                (Test-DemoPolicyIsolationRecovery $script:journal).ownedGroupExists | Should -BeTrue
            }
            It 'refuses a success-shaped empty/misaddressed ARM metadata result' {
                Mock Invoke-AzJson { @{id='/different/resource'} }
                { Get-DemoArmRecord 'https://management.azure.com/subscriptions/test' @('ResourceNotFound') } | Should -Throw '*exact requested resource*'
            }
            It 'checks existing subscription policy names before a fresh install can adopt them' {
                $script:definitionExists=$true
                { Assert-DemoUnusedPolicyNames $config } | Should -Throw '*Ownership is not proven*'
                Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'create' -or $Arguments -contains 'put' }
            }
        }
    }
