BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Common.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Exact policy evidence, not generic deployment failure' {
    BeforeEach {
        $assignment = '/subscriptions/test/resourceGroups/demo/providers/Microsoft.Authorization/policyAssignments/cmk'
        $definition = '/subscriptions/test/providers/Microsoft.Authorization/policyDefinitions/cmk'
        $detail = @{
            policyAssignmentId = $assignment
            policyDefinitionId = $definition
            evaluationDetails = @{ evaluatedExpressions = @(@{ expression = 'encryption.keySource'; result = 'False' }) }
        }
    }
    It 'accepts the exact intended Deny with evaluated conditions' {
        $errorNode = @{ code = 'RequestDisallowedByPolicy'; additionalInfo = @(@{ info = $detail }) }
        Test-IntendedPolicyDenial $errorNode $assignment $definition | Should -BeTrue
    }
    It 'does not accept a matching assignment outside a policy-denial error' {
        Test-IntendedPolicyDenial $detail $assignment $definition | Should -BeFalse
    }
    It 'does not accept a different policy as the intended denial' {
        $errorNode = @{ code = 'RequestDisallowedByPolicy'; details = @($detail) }
        Test-IntendedPolicyDenial $errorNode "$assignment-other" $definition | Should -BeFalse
    }
    It 'requires real evaluated expressions rather than only IDs' {
        $detail.evaluationDetails.evaluatedExpressions = @()
        Test-IntendedPolicyDenial @{ code = 'RequestDisallowedByPolicy'; info = $detail } $assignment $definition | Should -BeFalse
    }
    It 'handles nested operation error JSON without accepting an authorization failure' {
        $nested = @{ statusMessage = (@{ error = @{ code = 'RequestDisallowedByPolicy'; details = @($detail) } } | ConvertTo-Json -Depth 10) }
        Test-IntendedPolicyDenial $nested $assignment $definition | Should -BeTrue
        Test-IntendedPolicyDenial @{ code = 'AuthorizationFailed'; info = $detail } $assignment $definition | Should -BeFalse
    }
    It 'does not confuse unparseable diagnostic text with evidence' {
        Test-IntendedPolicyDenial '{not-json}' $assignment $definition | Should -BeFalse
    }
}

Describe 'Offline operation defaults contact no Azure endpoint' {
    BeforeEach {
        $config = New-TestConfiguration
        $path = Join-Path $TestDrive 'offline.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content $path
        Mock az { throw 'Offline scripts must not invoke az.' }
    }
    It 'plans infrastructure without deploying or reading Azure' {
        $result = & (Join-Path $PSScriptRoot '../scripts/Deploy-Demo.ps1') -ConfigPath $path
        $result.Mode | Should -Contain 'OfflinePlan'
        Should -Invoke az -Times 0
    }
    It 'plans HSM bootstrap without activating or creating keys' {
        $result = & (Join-Path $PSScriptRoot '../scripts/Initialize-Hsm.ps1') -ConfigPath $path
        $result.Mode | Should -Be 'OfflinePlan'
        Should -Invoke az -Times 0
    }
    It 'plans denial cases without making negative deployments' {
        $result = & (Join-Path $PSScriptRoot '../scripts/Test-PolicyExamples.ps1') -ConfigPath $path -Example platform-key
        $result.Mode | Should -Be 'OfflinePlan'
        Should -Invoke az -Times 0
    }
}
