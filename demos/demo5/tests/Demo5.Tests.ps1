BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'scripts\Demo5.psm1') -Force
    function New-DenialFixture {
        return @{
            subscriptionId = '00000000-0000-0000-0000-000000000001'
            eventDataId = 'TEST-event-1'; correlationId = 'TEST-correlation-1'
            eventTimestamp = '2026-10-30T15:00:00Z'; caller = 'TEST-CALLER-NOT-A-REAL-IDENTITY'
            resourceProviderName = @{ value = 'Microsoft.CustomerLockbox' }
            operationName = @{ value = 'Microsoft.CustomerLockbox/requests/deny/action'; localizedValue = 'Deny Lockbox Request' }
            status = @{ value = 'Succeeded' }; properties = @{ fixture = 'TEST ONLY - no real denial occurred' }
        }
    }
    function New-BundleFixture {
        return @{
            schema = 1; provenance = 'Azure Activity Log capture'
            requestId = 'TEST-REQUEST-NOT-REAL'; capturedAtUtc = '2026-10-30T15:00:00Z'
            subscriptionId = '00000000-0000-0000-0000-000000000001'
            eventDataId = 'TEST-event-1'; correlationId = 'TEST-correlation-1'
            selectedEvent = (New-DenialFixture)
        }
    }
}

Describe 'Explicit audit windows' {
    It 'accepts a recent short UTC window' {
        $end = [DateTime]::UtcNow
        $startText = $end.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endText = $end.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $window = Get-D5Window $startText $endText
        $window.start | Should -Be $startText
        $window.end | Should -Be $endText
    }
    It 'rejects local/ambiguous times, reversed, excessive, old and future windows' {
        { Get-D5Window '2026-10-30 15:00' '2026-10-30T16:00:00Z' } | Should -Throw '*explicit UTC*'
        $end = [DateTime]::UtcNow
        { Get-D5Window $end.ToString('yyyy-MM-ddTHH:mm:ssZ') $end.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ') } | Should -Throw '*positive*'
        { Get-D5Window $end.AddHours(-25).ToString('yyyy-MM-ddTHH:mm:ssZ') $end.ToString('yyyy-MM-ddTHH:mm:ssZ') } | Should -Throw '*24 hours*'
        { Get-D5Window '2000-01-01T00:00:00Z' '2000-01-01T01:00:00Z' } | Should -Throw '*archive*'
        { Get-D5Window $end.ToString('yyyy-MM-ddTHH:mm:ssZ') $end.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ') } | Should -Throw '*future*'
    }
}

Describe 'Correct tenant and subscription' {
    BeforeEach {
        Mock Invoke-D5Az -ModuleName Demo5 {
            return @{ id = 'sub'; tenantId = 'tenant'; state = 'Enabled'; environmentName = 'AzureCloud' }
        }
    }
    It 'accepts the explicitly selected enabled public Azure context' {
        (Assert-D5Context sub tenant).id | Should -Be 'sub'
    }
    It 'refuses a mismatched tenant or subscription' {
        { Assert-D5Context sub wrong } | Should -Throw '*Wrong tenant*'
        { Assert-D5Context wrong tenant } | Should -Throw '*Wrong tenant*'
    }
}

Describe 'Lockbox evidence selection' {
    It 'ignores unrelated operations and handles missing provider fields' {
        $other = @{ operationName = @{ value = 'Microsoft.Compute/virtualMachines/write' } }
        @(Get-D5LockboxEvents @($other, @{}, (New-DenialFixture))).Count | Should -Be 1
        @(Get-D5LockboxEvents @()).Count | Should -Be 0
    }
    It 'requires a unique event, matching correlation and subscription, and a successful denial with caller' {
        $event = New-DenialFixture
        $selected = Select-D5DenialEvent @($event) TEST-event-1 TEST-correlation-1 $event.subscriptionId
        $selected.eventDataId | Should -Be 'TEST-event-1'
        { Select-D5DenialEvent @($event, $event) TEST-event-1 TEST-correlation-1 $event.subscriptionId } | Should -Throw '*uniquely*'
        { Select-D5DenialEvent @($event) absent TEST-correlation-1 $event.subscriptionId } | Should -Throw '*not found*'
        { Select-D5DenialEvent @($event) TEST-event-1 wrong $event.subscriptionId } | Should -Throw '*does not match*'
        { Select-D5DenialEvent @($event) TEST-event-1 TEST-correlation-1 wrong } | Should -Throw '*does not match*'
    }
    It 'rejects approval, generic updates, failed/pending events and missing caller' {
        foreach ($operation in @('approve', 'write')) {
            $event = New-DenialFixture
            $event.operationName = @{ value = "Microsoft.CustomerLockbox/requests/$operation/action"; localizedValue = 'Other operation' }
            { Select-D5DenialEvent @($event) TEST-event-1 TEST-correlation-1 $event.subscriptionId } | Should -Throw '*not a recognized Deny*'
        }
        foreach ($status in @('Failed', 'Started', 'Accepted')) {
            $event = New-DenialFixture
            $event.status.value = $status
            { Select-D5DenialEvent @($event) TEST-event-1 TEST-correlation-1 $event.subscriptionId } | Should -Throw '*not Succeeded*'
        }
        $event = New-DenialFixture
        $event.caller = ''
        { Select-D5DenialEvent @($event) TEST-event-1 TEST-correlation-1 $event.subscriptionId } | Should -Throw '*no caller*'
    }
    It 'permits the documented localized English denial label without guessing other operations' {
        $event = New-DenialFixture
        $event.operationName.value = 'Microsoft.CustomerLockbox/requests/update'
        { Select-D5DenialEvent @($event) TEST-event-1 TEST-correlation-1 $event.subscriptionId } | Should -Not -Throw
    }
}

Describe 'Recorded evidence integrity and preservation' {
    It 'writes raw selected JSON and validates its checksum offline' {
        $directory = Join-Path $TestDrive 'good'
        $null = Write-D5Evidence (New-BundleFixture) $directory
        $bundle = Read-D5Evidence $directory
        $bundle.selectedEvent.properties.fixture | Should -Match 'TEST ONLY'
        $bundle.selectedEvent.eventTimestamp | Should -BeOfType ([string])
        $bundle.selectedEvent.eventTimestamp | Should -BeExactly '2026-10-30T15:00:00Z'
        (Get-Content -LiteralPath (Join-Path $directory 'evidence.sha256') -Raw).Length | Should -Be 64
    }
    It 'never overwrites an existing destination' {
        $directory = Join-Path $TestDrive 'existing'
        $null = Write-D5Evidence (New-BundleFixture) $directory
        $original = Get-FileHash -LiteralPath (Join-Path $directory 'evidence.json')
        { Write-D5Evidence (New-BundleFixture) $directory } | Should -Throw '*already exists*'
        (Get-FileHash -LiteralPath $original.Path).Hash | Should -Be $original.Hash
    }
    It 'rejects changed evidence and missing checksums without a fallback' {
        $directory = Join-Path $TestDrive 'changed'
        $null = Write-D5Evidence (New-BundleFixture) $directory
        Add-Content -LiteralPath (Join-Path $directory 'evidence.json') -Value 'changed'
        { Read-D5Evidence $directory } | Should -Throw '*checksum mismatch*'
        Remove-Item -LiteralPath (Join-Path $directory 'evidence.sha256')
        { Read-D5Evidence $directory } | Should -Throw '*missing*'
    }
    It 'rejects a failed event even if its local checksum is valid' {
        $directory = Join-Path $TestDrive 'not-denied'
        $bundle = New-BundleFixture
        $bundle.selectedEvent.status.value = 'Failed'
        $null = Write-D5Evidence $bundle $directory
        { Read-D5Evidence $directory } | Should -Throw '*not Succeeded*'
    }
}

Describe 'Read-only CLI orchestration with a fake Azure CLI' {
    BeforeAll {
        $previousAz = Get-Command az -CommandType Function -ErrorAction SilentlyContinue
        $previousBody = if ($previousAz) { $previousAz.ScriptBlock } else { $null }
        function global:az {
            $arguments = @($args)
            $global:D5Calls.Add($arguments)
            $global:LASTEXITCODE = 0
            if ($arguments[0..1] -join ' ' -eq 'account show') {
                return (@{
                    id = '00000000-0000-0000-0000-000000000001'
                    tenantId = '00000000-0000-0000-0000-000000000002'
                    state = 'Enabled'; environmentName = 'AzureCloud'; name = 'TEST SUBSCRIPTION'
                } | ConvertTo-Json -Compress)
            }
            if ($arguments[0..2] -join ' ' -eq 'monitor activity-log list') {
                return (ConvertTo-Json -InputObject $global:D5Events -Depth 20 -Compress)
            }
            if ($arguments[0..2] -join ' ' -eq 'ad signed-in-user show') {
                return '"00000000-0000-0000-0000-000000000003"'
            }
            if ($arguments[0..2] -join ' ' -eq 'role assignment list') {
                return '[{"roleDefinitionName":"Azure Customer Lockbox Approver for Subscription","scope":"/subscriptions/00000000-0000-0000-0000-000000000001"}]'
            }
            throw "FAKE CLI rejected unexpected operation: $($arguments -join ' '). Real Azure is not called by tests."
        }
    }
    BeforeEach {
        $global:D5Calls = [Collections.Generic.List[object]]::new()
        $global:D5Events = @((New-DenialFixture))
        $end = [DateTime]::UtcNow
        $arguments = @{
            SubscriptionId = '00000000-0000-0000-0000-000000000001'
            TenantId = '00000000-0000-0000-0000-000000000002'
            StartUtc = $end.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
            EndUtc = $end.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }
    AfterAll {
        if ($previousBody) { Set-Item Function:\global:az $previousBody }
        else { Remove-Item Function:\global:az }
        Remove-Variable D5Calls, D5Events -Scope Global
    }
    It 'lists actual returned events through read-only subscription/window queries' {
        & (Join-Path $root 'Start-Demo.ps1') -Mode ListEvents @arguments
        $global:D5Calls.Count | Should -Be 2
        $global:D5Calls[1] | Should -Contain $arguments.SubscriptionId
        $global:D5Calls[1] | Should -Contain $arguments.StartUtc
    }
    It 'prepares using only context and advisory role queries without enabling or creating anything' {
        & (Join-Path $root 'Start-Demo.ps1') -Mode Prepare -SubscriptionId $arguments.SubscriptionId -TenantId $arguments.TenantId
        $global:D5Calls.Count | Should -Be 3
        $global:D5Calls[1][0..2] -join ' ' | Should -Be 'ad signed-in-user show'
        $global:D5Calls[2][0..2] -join ' ' | Should -Be 'role assignment list'
    }
    It 'prints the portal entry point without launching a browser when requested' {
        & (Join-Path $root 'Start-Demo.ps1') -Mode OpenPortal -SubscriptionId $arguments.SubscriptionId -TenantId $arguments.TenantId -NoBrowser
        $global:D5Calls.Count | Should -Be 1
    }
    It 'refuses an empty result as evidence, and refuses potentially capped results' {
        $global:D5Events = @()
        { & (Join-Path $root 'Start-Demo.ps1') -Mode ListEvents @arguments } | Should -Throw '*No Lockbox*'
        $global:D5Events = @((New-DenialFixture))
        { & (Join-Path $root 'Start-Demo.ps1') -Mode ListEvents @arguments -MaxEvents 1 } | Should -Throw '*event cap*'
    }
    It 'requires explicit operator request correlation before exporting' {
        $directory = Join-Path $TestDrive 'unattested'
        { & (Join-Path $root 'Start-Demo.ps1') -Mode ExportEvidence @arguments -RequestId test -EventDataId TEST-event-1 -CorrelationId TEST-correlation-1 -EvidenceDirectory $directory } | Should -Throw '*ConfirmRequestCorrelation*'
        Test-Path -LiteralPath $directory | Should -BeFalse
    }
    It 'exports a selected event and replays offline without further Azure calls' {
        $directory = Join-Path $TestDrive 'capture'
        & (Join-Path $root 'Start-Demo.ps1') -Mode ExportEvidence @arguments -RequestId TEST-REQUEST -EventDataId TEST-event-1 -CorrelationId TEST-correlation-1 -ConfirmRequestCorrelation -EvidenceDirectory $directory
        $before = $global:D5Calls.Count
        $output = & (Join-Path $root 'Start-Demo.ps1') -Mode ShowEvidence -EvidenceDirectory $directory
        $global:D5Calls.Count | Should -Be $before
        ($output -join "`n") | Should -Match 'TEST ONLY'
        (Read-D5Evidence $directory).requestLink | Should -Match 'not independently correlated'
    }
    It 'never supplies a deny or approve API, tenant-setting mutation or request-create operation' {
        $script = Get-Content -LiteralPath (Join-Path $root 'Start-Demo.ps1') -Raw
        $script | Should -Not -Match "Invoke-D5Az @\('rest'|'--method', 'post'|'--method', 'put'"
        $script | Should -Not -Match 'az role assignment create|az support.*create'
    }
}
