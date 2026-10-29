BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Common.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../host/Demo.Worker.psm1') -Force
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Common.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../host/Demo.Worker.psm1') -Force
}

Describe 'Atomic durable state' {
    It 'persists a complete replacement without leftover temporary files' {
        $path = Join-Path $TestDrive 'state.json'
        Write-DurableJson $path @{ phase = 'Armed'; value = 1 }
        Write-DurableJson $path @{ phase = 'Disabled'; value = 2 }
        (Get-Content $path -Raw | ConvertFrom-Json).value | Should -Be 2
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'Independent recovery state machine (mocked Azure, not live evidence)' {
    InModuleScope Demo.Worker {
        BeforeAll {
            $script:cfg = @{
                hsmName = 'hsm-demo2-test'
                targets = @{
                    Live = @{ keyName = 'demo2-live'; keyVersion = ('1' * 32); recoveryTimeoutSeconds = 180 }
                    Twin = @{ keyName = 'demo2-twin'; keyVersion = ('2' * 32); recoveryTimeoutSeconds = 1800 }
                }
            }
        }
        BeforeEach {
            $script:now = [datetimeoffset]'2026-01-01T12:00:00Z'
            $script:runId = [guid]::NewGuid().ToString()
            $script:req = @{ action = 'Arm'; target = 'Live'; runId = $script:runId }
            $script:lastState = $null
            Mock Get-KeyAttributes { @{ enabled = $true } }
            Mock Set-KeyEnabled {}
            Mock Assert-StorageKeyBinding {}
            Mock Read-DemoBlob { @{ status = 200; errorCode = ''; requestId = 'test-only'; content = 'synthetic' } }
            Mock Write-DemoEvent {}
            Mock Write-DurableJson { param($Path, $Value) $script:lastState = $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }
        }
        It 'arms only with a fresh heartbeat and persists a fixed deadline' {
            $result = Invoke-WorkerRequest $script:cfg $script:req $null 'state' $script:now $script:now
            $result.state.phase | Should -Be 'Armed'
            ([datetimeoffset]::Parse($script:lastState.deadlineUtc) - $script:now).TotalSeconds | Should -Be 180
            Should -Invoke Set-KeyEnabled -Times 1 -ParameterFilter { $Enabled -eq $true }
            Should -Invoke Set-KeyEnabled -Times 0 -ParameterFilter { $Enabled -eq $false }
        }
        It 'rejects stale heartbeat before any key mutation' {
            { Invoke-WorkerRequest $script:cfg $script:req $null 'state' $script:now ($script:now.AddSeconds(-21)) } | Should -Throw '*heartbeat*'
            Should -Invoke Set-KeyEnabled -Times 0
        }
        It 'rejects an initially disabled key' {
            Mock Get-KeyAttributes { @{ enabled = $false } }
            { Invoke-WorkerRequest $script:cfg $script:req $null 'state' $script:now $script:now } | Should -Throw '*already-disabled*'
            Should -Invoke Set-KeyEnabled -Times 0
        }
        It 'rejects a failed baseline without manufacturing a status' {
            Mock Read-DemoBlob { @{ status = 403; errorCode = 'AuthorizationPermissionMismatch'; requestId = 'real-shaped-test' } }
            { Invoke-WorkerRequest $script:cfg $script:req $null 'state' $script:now $script:now } | Should -Throw '*AuthorizationPermissionMismatch*'
            Should -Invoke Set-KeyEnabled -Times 0
        }
        It 'does not acknowledge arming if persistence fails' {
            Mock Write-DurableJson { throw 'disk unavailable' }
            { Invoke-WorkerRequest $script:cfg $script:req $null 'state' $script:now $script:now } | Should -Throw '*disk unavailable*'
            Should -Invoke Set-KeyEnabled -Times 0 -ParameterFilter { $Enabled -eq $false }
        }
        It 'never disables a key without an armed run' {
            $script:req.action = 'Disable'
            { Invoke-WorkerRequest $script:cfg $script:req $null 'state' $script:now $script:now } | Should -Throw
            Should -Invoke Set-KeyEnabled -Times 0
        }
        It 'rejects wrong key versions even when run ID matches' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.keyUri += 'bad'
            $script:req.action = 'Disable'
            { Invoke-WorkerRequest $script:cfg $script:req $state 'state' $script:now $script:now } | Should -Throw '*version*'
        }
        It 'allows one disable and never extends the original deadline on replay' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $deadline = $state.deadlineUtc
            $script:req.action = 'Disable'
            $result = Invoke-WorkerRequest $script:cfg $script:req $state 'state' $script:now $script:now
            $result.state.phase | Should -Be 'Disabled'
            $result.state.deadlineUtc | Should -Be $deadline
            { Invoke-WorkerRequest $script:cfg $script:req $result.state 'state' $script:now $script:now } | Should -Throw '*once*'
            Should -Invoke Set-KeyEnabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        }
        It 'refuses a disable at the recovery deadline' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $script:req.action = 'Disable'
            { Invoke-WorkerRequest $script:cfg $script:req $state 'state' ($script:now.AddSeconds(180)) ($script:now.AddSeconds(180)) } | Should -Throw '*unexpired*'
            Should -Invoke Set-KeyEnabled -Times 0
        }
        It 'persists recovery intent on an unknown disable outcome' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $script:req.action = 'Disable'
            Mock Set-KeyEnabled { throw 'transport timeout; outcome uncertain' }
            { Invoke-WorkerRequest $script:cfg $script:req $state 'state' $script:now $script:now } | Should -Throw '*uncertain*'
            $script:lastState.phase | Should -Be 'Recovering'
            $script:lastState.uncertainMutation | Should -BeTrue
        }
        It 'recovers at expiry without any laptop or button request' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.phase = 'Disabled'
            $result = Invoke-RecoveryTick $script:cfg $state 'state' ($script:now.AddSeconds(181))
            $result.phase | Should -Be 'Recovered'
            $result.readRestored | Should -BeTrue
            Should -Invoke Set-KeyEnabled -Times 1 -ParameterFilter { $Enabled -eq $true }
        }
        It 'continues reconciling after recovery to defeat a late disable' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.phase = 'Recovering'
            $state = Invoke-RecoveryTick $script:cfg $state 'state' $script:now
            $state = Invoke-RecoveryTick $script:cfg $state 'state' ($script:now.AddSeconds(10))
            Should -Invoke Set-KeyEnabled -Times 2 -ParameterFilter { $Enabled -eq $true }
        }
        It 'records enabled key separately from storage restoration' {
            Mock Read-DemoBlob { @{ status = 403; errorCode = 'KeyVaultAccessForbidden'; requestId = 'test-only' } }
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.phase = 'Recovering'
            $state = Invoke-RecoveryTick $script:cfg $state 'state' $script:now
            $state.keyEnabled | Should -BeTrue
            $state.readRestored | Should -BeFalse
            $state.phase | Should -Be 'Recovering'
            Should -Invoke Write-DemoEvent -ParameterFilter { $EventName -eq 'RecoveryOverdue' } -Times 1
        }
        It 'retains intent and surfaces identity/network recovery failures' {
            Mock Set-KeyEnabled { throw 'IMDS unavailable' }
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.phase = 'Recovering'
            $state = Invoke-RecoveryTick $script:cfg $state 'state' $script:now
            $state.phase | Should -Be 'Recovering'
            $state.lastError | Should -Be 'IMDS unavailable'
        }
        It 'starts recovery after a backward clock jump instead of extending the outage' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state = Invoke-RecoveryTick $script:cfg $state 'state' ($script:now.AddSeconds(-1))
            Should -Invoke Set-KeyEnabled -Times 1 -ParameterFilter { $Enabled -eq $true }
        }
        It 'recovers armed state on process restart or host reboot' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            (Initialize-RecoveryState $script:cfg $state 'Live').phase | Should -Be 'Recovering'
        }
        It 'refuses corrupt or displaced persisted state' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.keyUri = 'https://unapproved.invalid/keys/production/version'
            { Initialize-RecoveryState $script:cfg $state 'Live' } | Should -Throw '*manual recovery*'
        }
        It 'does not restore the twin when restoring Live' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.phase = 'Recovering'
            $null = Invoke-RecoveryTick $script:cfg $state 'state' $script:now
            Should -Invoke Set-KeyEnabled -Times 0 -ParameterFilter { $Target -eq 'Twin' }
        }
        It 'rejects an automatic Reset after an uncertain mutation' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.phase = 'Recovered'
            $state.uncertainMutation = $true
            $state.recoveredSinceUtc = $script:now.AddSeconds(-120).ToString('o')
            $script:req.action = 'Reset'
            { Invoke-WorkerRequest $script:cfg $script:req $state 'state' $script:now $script:now } | Should -Throw '*uncertain*'
        }
        It 'rejects re-arming a closed run ID' {
            $state = New-RecoveryState $script:cfg 'Live' $script:runId $script:now
            $state.phase = 'Closed'
            { Invoke-WorkerRequest $script:cfg $script:req $state 'state' $script:now $script:now } | Should -Throw '*replay*'
        }
    }
}
