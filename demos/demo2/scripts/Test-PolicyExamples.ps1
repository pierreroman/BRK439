[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('denied-region', 'platform-key', 'positive')][string]$Example = 'positive',
    [switch]$AuthorizeLiveChanges,
    [switch]$PolicyReviewConfirmed,
    [string]$ExpectedPolicyAssignmentId,
    [string]$ExpectedPolicyDefinitionId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Runtime
$scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)"
if ($Example -ne 'positive') {
    if ($config.policyMode -eq 'sandbox') {
        $assignmentName = if ($Example -eq 'denied-region') { 'locations' } else { 'cmk' }
        $ExpectedPolicyAssignmentId = "$scope/providers/Microsoft.Authorization/policyAssignments/demo2-$($config.nameSuffix)-$assignmentName"
        $ExpectedPolicyDefinitionId = if ($Example -eq 'denied-region') {
            '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
        } else {
            "/subscriptions/$($config.subscriptionId)/providers/Microsoft.Authorization/policyDefinitions/demo2-$($config.nameSuffix)-storage-cmk"
        }
    } elseif ($ExpectedPolicyAssignmentId -notin $config.existingPolicyAssignmentIds -or
        $ExpectedPolicyDefinitionId -notmatch '^/(providers/Microsoft.Authorization/policyDefinitions|subscriptions/[^/]+/providers/Microsoft.Authorization/policyDefinitions|providers/Microsoft.Management/managementGroups/[^/]+/providers/Microsoft.Authorization/policyDefinitions)/[^/]+$') {
        throw 'SLZ negative examples require an explicitly listed intended assignment and its exact definition ID. No SLZ policy is modified.'
    }
}
if (-not $AuthorizeLiveChanges) {
    [pscustomobject]@{
        Mode = 'OfflinePlan'; Example = $Example
        ExpectedAssignment = $ExpectedPolicyAssignmentId; ExpectedDefinition = $ExpectedPolicyDefinitionId
        Proof = 'NOT RUN. Real operation error JSON must contain RequestDisallowedByPolicy, the intended assignment/definition and evaluated expressions. Run positive separately.'
    }
    return
}
if (-not $PolicyReviewConfirmed) { throw 'Review inherited policy/exemption/enforcement evidence and cross-region CMK prerequisites before passing -PolicyReviewConfirmed.' }
Assert-DemoAzureContext -Config $config
$candidate = 'demo2' + ([guid]::NewGuid().ToString('N').Substring(0, 16))
$deployment = "demo2-policy-$Example-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
if (-not $PSCmdlet.ShouldProcess("$scope/$candidate", "Create billable $Example policy probe; no automatic cleanup")) { return }
$template = Join-Path $PSScriptRoot '..\infra\policy-example.bicep'
$arguments = @(
    'deployment', 'group', 'create', '--subscription', $config.subscriptionId,
    '--resource-group', $config.resourceGroup, '--name', $deployment,
    '--template-file', $template, '--parameters', ('config=@' + (Resolve-Path -LiteralPath $ConfigPath).ProviderPath),
    "example=$Example", "candidateName=$candidate", '--only-show-errors', '--output', 'json'
)
$previousNativePreference = $PSNativeCommandUseErrorActionPreference
try {
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & az @arguments 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
}
Write-Output ($output -join [Environment]::NewLine)
if ($Example -eq 'positive') {
    if ($exitCode -ne 0) { throw "Compliant positive control failed with CLI exit $exitCode; this is not a successful denial." }
    [pscustomobject]@{ Example = $Example; Result = 'ActualDeploymentSucceeded'; Candidate = $candidate; Deployment = $deployment; Cleanup = 'Explicit separate operator action only.' }
    return
}
if ($exitCode -eq 0) { throw "Negative deployment unexpectedly succeeded: $candidate. No policy denial was proved; retain and investigate." }
$evidence = @{ deployment = $deployment; cliExitCode = $exitCode; operations = @(); childOperations = @(); cliError = $null; unavailableOperationQueries = @() }
$text = $output -join [Environment]::NewLine
$start = $text.IndexOf('{')
$end = $text.LastIndexOf('}')
if ($start -ge 0 -and $end -ge $start) {
    try { $evidence.cliError = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json -AsHashtable }
    catch { Write-Warning "CLI failure text did not contain one parseable JSON error: $($_.Exception.Message)" }
}
foreach ($query in @(@{ name = $deployment; field = 'operations' }, @{ name = "candidate-$candidate"; field = 'childOperations' })) {
    try {
        $evidence[$query.field] = Invoke-AzJson -Arguments @('deployment', 'operation', 'group', 'list', '--resource-group', $config.resourceGroup, '--name', $query.name)
    } catch {
        # A policy denial during preflight may prevent deployment history from existing.
        Write-Warning "Operation evidence unavailable for $($query.name): $($_.Exception.Message)"
        $evidence.unavailableOperationQueries += @{ deployment = $query.name; error = $_.Exception.Message }
    }
}
Write-Output ($evidence | ConvertTo-Json -Depth 100)
if (-not (Test-IntendedPolicyDenial -Node $evidence -AssignmentId $ExpectedPolicyAssignmentId -DefinitionId $ExpectedPolicyDefinitionId)) {
    throw 'Deployment failed, but operation JSON does not prove the intended policy denial with evaluated conditions. Template, identity, authorization, quota, CMK and connectivity failures do not count.'
}
[pscustomobject]@{ Example = $Example; Result = 'IntendedPolicyDenialProved'; Assignment = $ExpectedPolicyAssignmentId; Definition = $ExpectedPolicyDefinitionId; Deployment = $deployment }
