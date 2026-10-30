BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Setup.psm1') -Force
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestData.ps1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Setup.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Custody.psm1') -Force
    function New-TestPassphrase {
        $value = [securestring]::new()
        foreach ($byte in [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) { $value.AppendChar([char](33 + ($byte % 90))) }
        $value.MakeReadOnly()
        return $value
    }
}

Describe 'Portable field journal and bounded encrypted transport (offline)' {
    It 'offers a genuinely offline plan without selecting an environment' {
        $result = & (Join-Path $PSScriptRoot '../Start-Demo.ps1') -Mode Plan
        $result.Mode | Should -Be 'OfflinePlan'
        $result.Architecture | Should -Match 'Managed HSM'
    }
    It 'persists complete JSON atomically and rejects immutable target drift' {
        $config = New-TestConfiguration
        $journal = @{schemaVersion=1;installationId=[guid]::NewGuid().ToString('N');config=$config;receipts=@{};configFingerprint=(Get-DemoConfigFingerprint $config)}
        $path = Join-Path $TestDrive 'journal.json'
        Save-DemoJournal $journal $path
        $restored = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        Assert-DemoJournal $restored
        Test-Path "$path.tmp" | Should -BeFalse
        $restored.config.subscriptionId = [guid]::NewGuid().ToString()
        { Assert-DemoJournal $restored } | Should -Throw '*drift*'
    }
    It 'permits resolved pins without changing the immutable installation target' {
        $config = New-TestConfiguration
        $before = Get-DemoConfigFingerprint $config
        $config.targets.Live.keyVersion = '33333333333333333333333333333333'
        Get-DemoConfigFingerprint $config | Should -Be $before
    }
    It 'rejects resource ownership/journal substitution' {
        $config = New-TestConfiguration
        $journal = @{schemaVersion=1;installationId='not-an-install';config=$config;receipts=@{};configFingerprint=(Get-DemoConfigFingerprint $config)}
        { Assert-DemoJournal $journal } | Should -Throw
    }
    It 'assembles the exact encrypted bytes with the required final partial chunk' {
        $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(2501)
        $info = @{bytes=$bytes.Length;chunks=3;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))}
        $actual = Receive-DemoEnvelope $info {
            param($index)
            @{index=$index;bytes=$bytes.Length;data=[Convert]::ToBase64String($bytes,$index*1200,[math]::Min(1200,$bytes.Length-$index*1200))}
        }
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actual)) | Should -Be $info.digest
    }
    It 'rejects <Kind> rather than accepting a success-shaped envelope' -ForEach @(
        @{Kind='replay'}, @{Kind='truncation'}, @{Kind='tampering'}
    ) {
        $bytes = [byte[]](1..20)
        $info = @{bytes=20;chunks=1;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))}
        {
            Receive-DemoEnvelope $info {
                param($index)
                $data = $bytes.Clone()
                if ($Kind -eq 'tampering') { $data[0] = 99 }
                if ($Kind -eq 'truncation') { $data = [byte[]]$data[0..18] }
                @{index=$(if ($Kind -eq 'replay') { 1 } else { $index });bytes=20;data=[Convert]::ToBase64String($data)}
            }
        } | Should -Throw
    }
    It 'rejects oversized or inconsistent envelope metadata before reading any chunk' {
        { Receive-DemoEnvelope @{bytes=1000001;chunks=1;digest='A'*64} { throw 'must not read' } } | Should -Throw '*metadata*'
    }
    It 'takes an exclusive installation lock instead of admitting simultaneous setup' {
        $path = Join-Path $TestDrive 'exclusive.lock'
        $lock = [IO.File]::Open($path,'OpenOrCreate','ReadWrite','None')
        try { { [IO.File]::Open($path,'OpenOrCreate','ReadWrite','None') } | Should -Throw }
        finally { $lock.Dispose() }
    }
    It 'generates an actual local OpenSSH pair without emitting private material' -Skip:(-not $IsWindows) {
        $directory = Join-Path $TestDrive 'ssh-pair'
        New-DemoPrivateDirectory $directory
        $key = Join-Path $directory 'operator'
        & ssh-keygen -q -t ed25519 -N '' -f $key -C 'synthetic-offline-test'
        $LASTEXITCODE | Should -Be 0
        Protect-DemoPrivateFile $key
        Assert-DemoPrivatePath $key
        $derived = & ssh-keygen -y -f $key
        $LASTEXITCODE | Should -Be 0
        $public = (Get-Content "$key.pub" -Raw).Trim()
        $public.StartsWith(($derived -join '').Trim()) | Should -BeTrue
    }
}

Describe 'Explicit target selection (synthetic subscriptions, no Azure)' {
    InModuleScope Demo.Setup {
        BeforeEach {
            $script:selectionValues=@(
                @{name='Duplicate demo';id='11111111-1111-1111-1111-111111111111';tenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'},
                @{name='Duplicate demo';id='22222222-2222-2222-2222-222222222222';tenantId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}
            )
            $script:selectionResponses=[Collections.Generic.Queue[object]]::new()
            Mock Read-Host { $script:selectionResponses.Dequeue() }
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Invoke-AzJson { throw 'OFFLINE: unexpected Azure call' }
            Mock az { throw 'OFFLINE: external Azure CLI blocked' }
        }
        It 'reprompts after <Description> without defaulting the selection' -ForEach @(
            @{Description='blank input';Attempt=''},
            @{Description='whitespace';Attempt='   '},
            @{Description='a name instead of an index';Attempt='Duplicate demo'},
            @{Description='a zero index';Attempt='0'},
            @{Description='a negative index';Attempt='-1'},
            @{Description='an out-of-range index';Attempt='3'},
            @{Description='a fractional index';Attempt='1.5'},
            @{Description='an overflowing integer';Attempt='999999999999999999999'}
        ) {
            $script:selectionResponses.Enqueue($Attempt)
            $script:selectionResponses.Enqueue(' 2 ')
            $result=Select-DemoValue 'Choose synthetic subscription' $script:selectionValues 'name'
            $result.id | Should -Be $script:selectionValues[1].id
            Should -Invoke Read-Host -Times 2 -Exactly
            Should -Invoke Write-Warning -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -Times 0
            Should -Invoke az -Times 0
        }
        It 'cancels on EOF after an invalid response instead of looping or selecting a default' {
            $script:selectionResponses.Enqueue('')
            $script:selectionResponses.Enqueue($null)
            { Select-DemoValue 'Choose synthetic subscription' $script:selectionValues 'name' } | Should -Throw '*input ended (EOF)*'
            Should -Invoke Read-Host -Times 2 -Exactly
        }
        It 'allows explicit cancellation without selecting a target' {
            $script:selectionResponses.Enqueue('q')
            { Select-DemoValue 'Choose synthetic subscription' $script:selectionValues 'name' } | Should -Throw '*Selection cancelled*'
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'explains unavailable noninteractive input without retrying' {
            Mock Read-Host { throw 'PowerShell is in NonInteractive mode.' }
            { Select-DemoValue 'Choose synthetic subscription' $script:selectionValues 'name' } | Should -Throw '*interactive PowerShell*'
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'distinguishes duplicate subscription names and selects only the chosen GUID without confirmation' {
            Mock Invoke-AzJson { $script:selectionValues }
            Mock az { throw 'OFFLINE_TARGET_SELECTED' }
            $script:selectionResponses.Enqueue('2')
            { New-DemoFieldConfig } | Should -Throw '*OFFLINE_TARGET_SELECTED*'
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                "$Object" -like '1: Duplicate demo*11111111-1111-1111-1111-111111111111*aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa*'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                "$Object" -like '2: Duplicate demo*22222222-2222-2222-2222-222222222222*bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb*'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                "$Object" -like 'Selected subscription*22222222-2222-2222-2222-222222222222*bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb*'
            }
            Should -Invoke Read-Host -Times 1 -Exactly
            Should -Invoke az -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'set' -and $args[3] -eq $script:selectionValues[1].id }
        }
    }
}

Describe 'Selection input in a real local PowerShell host (no Azure)' {
    It 'terminates explicitly for <Description>' -ForEach @(
        @{Description='redirected EOF';NonInteractive=$false;Secure=$false;Expected='*input ended (EOF)*'},
        @{Description='noninteractive mode';NonInteractive=$true;Secure=$false;Expected='*interactive PowerShell*'},
        @{Description='secure redirected EOF';NonInteractive=$false;Secure=$true;Expected='*Secure input unavailable*'},
        @{Description='secure noninteractive mode';NonInteractive=$true;Secure=$true;Expected='*interactive PowerShell*'}
    ) {
        $modulePath=(Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1').Replace("'","''")
        $call=if($Secure) { 'Read-DemoNewPassphrase' } else { "Select-DemoValue 'Synthetic choice' @(@{name='Synthetic option'}) 'name'" }
        $command="Import-Module '$modulePath'; try { & (Get-Module Demo.Setup) { $call }; exit 2 } catch { [Console]::WriteLine(`$_.Exception.Message); exit 7 }"
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=(Get-Process -Id $PID).Path
        foreach($argument in @('-NoLogo','-NoProfile')) { $start.ArgumentList.Add($argument) }
        if($NonInteractive) { $start.ArgumentList.Add('-NonInteractive') }
        $start.ArgumentList.Add('-Command')
        $start.ArgumentList.Add($command)
        $start.RedirectStandardInput=$true
        $start.RedirectStandardOutput=$true
        $start.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($start)
        try {
            $process.StandardInput.Close()
            if(-not $process.WaitForExit(10000)) { throw 'Selection did not terminate after unavailable input.' }
            $output=$process.StandardOutput.ReadToEnd()
            $errorOutput=$process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 7
            $output | Should -BeLike $Expected
            $errorOutput | Should -BeNullOrEmpty
        } finally {
            if(-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
    }
}

Describe 'Real Setup entry-point startup cardinalities (offline synthetic installations)' -Skip:(-not $IsWindows) {
        BeforeAll {
            $script:startupEntry = Join-Path $PSScriptRoot '..\Start-Demo.ps1'
        }
        BeforeEach {
            Mock Invoke-AzJson -ModuleName Demo.Setup { throw 'OFFLINE: unexpected Azure call' }
            Mock New-DemoFieldConfig -ModuleName Demo.Setup { throw 'OFFLINE_CONFIGURATION_CHECKPOINT' }
            Mock Write-Error -ModuleName Demo.Setup {}
            Mock Read-Host -ModuleName Demo.Setup { throw 'OFFLINE: unexpected interactive prompt' }
            Mock git -ModuleName Demo.Setup { $global:LASTEXITCODE = 0 }
            Mock az { throw 'OFFLINE: external Azure CLI blocked' }
        }
        It 'reaches configuration from a clean automatic first-run directory' {
            $originalKit = [IO.Path]::GetFullPath((Split-Path $script:startupEntry))
            $repo = Join-Path $TestDrive 'new-checkout'
            $fakeKit = Join-Path $repo 'demos\demo2'
            [void][IO.Directory]::CreateDirectory($fakeKit)
            [IO.File]::WriteAllText((Join-Path $repo '.gitignore'),"# synthetic checkout`n")
            & (Get-Module Demo.Setup) { param($Path) $script:Kit=$Path } $fakeKit
            try {
                { & $script:startupEntry -Mode Setup } | Should -Throw '*OFFLINE_CONFIGURATION_CHECKPOINT*'
                Should -Invoke New-DemoFieldConfig -ModuleName Demo.Setup -Times 1
                Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 0
                Should -Invoke az -Times 0
                Should -Invoke Read-Host -ModuleName Demo.Setup -Times 0
                Get-Content (Join-Path $repo '.gitignore') | Should -Contain '/.private/demo2/'
                @(Get-ChildItem (Join-Path $repo '.private\demo2\installs') -Recurse -File |
                    Where-Object Name -ne '.setup.lock').Count | Should -Be 0
            } finally { & (Get-Module Demo.Setup) { param($Path) $script:Kit=$Path } $originalKit }
        }
        It 'reaches configuration when resuming an empty pre-journal installation' {
            $install = Join-Path $TestDrive 'empty-install'
            New-DemoPrivateDirectory $install
            { & $script:startupEntry -Mode Setup -InstallPath $install } | Should -Throw '*OFFLINE_CONFIGURATION_CHECKPOINT*'
            Should -Invoke New-DemoFieldConfig -ModuleName Demo.Setup -Times 1
            Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 0
            Should -Invoke az -Times 0
            Test-Path (Join-Path $install 'install.json') | Should -BeFalse
        }
        It 'preserves and rejects <Items> unjournaled file(s) before configuration or key generation' -ForEach @(
            @{Items=1}, @{Items=2}
        ) {
            $install = Join-Path $TestDrive "unjournaled-$Items"
            New-DemoPrivateDirectory $install
            $expected = @{}
            for ($i=0; $i -lt $Items; $i++) {
                $file = Join-Path $install "synthetic-$i.marker"
                [IO.File]::WriteAllText($file,"synthetic retained fixture $i")
                $expected[$file] = (Get-FileHash $file).Hash
            }
            { & $script:startupEntry -Mode Setup -InstallPath $install } | Should -Throw '*Unjournaled private files exist*'
            foreach ($file in $expected.Keys) { (Get-FileHash $file).Hash | Should -Be $expected[$file] }
            Should -Invoke New-DemoFieldConfig -ModuleName Demo.Setup -Times 0
            Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 0
            Should -Invoke az -Times 0
            Test-Path (Join-Path $install 'install.json') | Should -BeFalse
        }
        It 'reads an existing journal with <Items> extra artifact(s) without rewriting retained state' -ForEach @(
            @{Items=0}, @{Items=1}, @{Items=2}
        ) {
            $install = Join-Path $TestDrive "journaled-$Items"
            New-DemoPrivateDirectory $install
            $config = New-TestConfiguration
            $journal = @{schemaVersion=1;installationId=[guid]::NewGuid().ToString('N');config=$config
                configFingerprint=(Get-DemoConfigFingerprint $config);receipts=@{};status='Preparing'}
            $journalPath = Join-Path $install 'install.json'
            Save-DemoJournal $journal $journalPath
            for ($i=0; $i -lt $Items; $i++) {
                [IO.File]::WriteAllText((Join-Path $install "synthetic-$i.marker"),"synthetic retained fixture $i")
            }
            $expected = @{}
            foreach ($file in Get-ChildItem -LiteralPath $install -File) { $expected[$file.FullName] = (Get-FileHash $file.FullName).Hash }
            $result = & $script:startupEntry -Mode Status -InstallPath $install
            $result.Mode | Should -Be 'LocalJournalOnly'
            $result.Status | Should -Be 'Preparing'
            $result.DemoReady | Should -BeFalse
            foreach ($file in $expected.Keys) { (Get-FileHash $file).Hash | Should -Be $expected[$file] }
            Should -Invoke New-DemoFieldConfig -ModuleName Demo.Setup -Times 0
            Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 0
            Should -Invoke az -Times 0
        }
        It 'reports a missing resume journal without treating it as a new installation' {
            $install = Join-Path $TestDrive 'missing-journal'
            New-DemoPrivateDirectory $install
            { & $script:startupEntry -Mode Status -InstallPath $install } | Should -Throw '*Installation journal not found*'
            Should -Invoke New-DemoFieldConfig -ModuleName Demo.Setup -Times 0
            Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 0
            Should -Invoke az -Times 0
        }
}

Describe 'Managed command reconciliation with Azure mocked' {
    InModuleScope Demo.Setup {
        BeforeEach {
            $journal = @{installationId='a'*32;config=@{location='test'};resources=@{vmId='/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/test'};pendingAgent=$null;publicUploads=@{}}
            $path = Join-Path $TestDrive 'agent-journal.json'
            Mock Save-DemoJournal {}
            Mock Start-Sleep {}
            function New-TestAgentRecord {
                param([string]$Operation,[string]$Body,[string]$State='Succeeded',[string]$Output)
                if (-not $Output) { $Output=@{operationId=$Operation;ok=$true} | ConvertTo-Json -Compress }
                @{id="$($journal.resources.vmId)/runCommands/demo2-field-setup";location='test';tags=@{installationId=$journal.installationId;operationId=$Operation}
                    properties=@{source=@{script=$Body.Replace('__OPERATION_ID__',$Operation)};provisioningState='Succeeded';instanceView=@{executionState=$State;exitCode=0;output=$Output}}}
            }
        }
        It 'refuses a different command while an earlier outcome is unresolved' {
            $journal.pendingAgent = @{operationId=[guid]::NewGuid().ToString();digest=('F'*64)}
            Mock Invoke-AzJson { throw 'No Azure call allowed' }
            { Invoke-DemoAgentScript $journal $path 'public source' } | Should -Throw '*unresolved*'
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'observes a pending command without resubmitting its PUT' {
            $script = 'public source'
            $operation = [guid]::NewGuid().ToString()
            $journal.pendingAgent = @{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))}
            Mock Invoke-AzJson {
                New-TestAgentRecord $operation $script
            }
            (Invoke-DemoAgentScript $journal $path $script).ok | Should -BeTrue
            $journal.pendingAgent | Should -BeNullOrEmpty
            Should -Invoke Invoke-AzJson -Times 1 -ParameterFilter { $Arguments -contains 'get' }
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'does not treat ARM completion as guest success' {
            $script = 'public source'
            $operation = [guid]::NewGuid().ToString()
            $journal.pendingAgent = @{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))}
            Mock Invoke-AzJson { New-TestAgentRecord $operation $script -State Failed }
            { Invoke-DemoAgentScript $journal $path $script } | Should -Throw '*failed*'
        }
        It 'retains unknown/truncated output for reconciliation' {
            $script = 'public source'
            $operation = [guid]::NewGuid().ToString()
            $journal.pendingAgent = @{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))}
            Mock Invoke-AzJson { New-TestAgentRecord $operation $script -Output 'truncated-json' }
            { Invoke-DemoAgentScript $journal $path $script } | Should -Throw '*truncated*'
            $journal.pendingAgent.operationId | Should -Be $operation
        }
        It 'rejects a stale command owned by another operation before accepting output' {
            $script = 'public source'
            $journal.pendingAgent = @{operationId=[guid]::NewGuid().ToString();digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))}
            Mock Invoke-AzJson { New-TestAgentRecord ([guid]::NewGuid().ToString()) $script }
            { Invoke-DemoAgentScript $journal $path $script } | Should -Throw '*correlation*'
        }
        It 'reuses verified public upload receipts when resuming later stages' {
            $bytes = [Text.Encoding]::UTF8.GetBytes('reviewed public content')
            $remote = '/var/lib/demo2-setup/' + ('a'*32) + '/kit/example.txt'
            $journal.publicUploads[$remote] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            Mock Invoke-DemoAgentScript { throw 'Must not replay earlier upload' }
            Send-DemoPublicFile $journal $path $remote $bytes
            Should -Invoke Invoke-DemoAgentScript -Times 0
        }
        It 'reconciles an exact later public upload before an earlier changed shared module without changing its script or operation' {
            $remote='/var/lib/demo2-setup/'+('a'*32)
            $assets=@(@{remotePath="$remote/kit/scripts/Demo.Common.psm1";bytes=[Text.Encoding]::UTF8.GetBytes('reviewed diagnostics update')},
                @{remotePath="$remote/recipient.cer";bytes=[byte[]](1,2,3)})
            $original=Get-DemoPublicUploadScript $assets[1].remotePath $assets[1].bytes
            $operation=[guid]::NewGuid().ToString()
            $journal.pendingAgent=@{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($original)))}
            $ordered=@(Get-DemoPublicUploadOrder $assets $journal.pendingAgent)
            $ordered.Count | Should -Be 2
            $ordered[0].remotePath | Should -Be $assets[1].remotePath
            $ordered[1].remotePath | Should -Be $assets[0].remotePath
            Mock Invoke-AzJson { New-TestAgentRecord $operation $original }
            Send-DemoPublicFile $journal $path $ordered[0].remotePath $ordered[0].bytes
            $journal.pendingAgent | Should -BeNullOrEmpty
            $journal.publicUploads.ContainsKey($ordered[0].remotePath) | Should -BeTrue
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'blocks a changed or unknown pending public payload before dispatching a different artifact' {
            $assets=@(@{remotePath=('/var/lib/demo2-setup/'+('a'*32)+'/kit/file.txt');bytes=[byte[]](1,2,3)})
            { Get-DemoPublicUploadOrder $assets @{digest=('F'*64)} } | Should -Throw '*exactly one*'
            { Get-DemoPublicUploadOrder $assets @{digest='unknown'} } | Should -Throw '*Unknown pending*'
            Should -Invoke Save-DemoJournal -Times 0
        }
        It 'retains accepted intent after local CLI failure and resumes the exact operation without another PUT' {
            $body='public __OPERATION_ID__ source'
            $script:accepted=$null
            Mock Invoke-AzJson {
                if ($Arguments -contains 'put') {
                    $file=$Arguments[[array]::IndexOf($Arguments,'--body')+1].Substring(1)
                    $request=Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
                    $script:accepted=New-TestAgentRecord $request.tags.operationId $request.properties.source.script
                    throw 'Synthetic CLI shell failure after ARM accepted'
                }
                if ($null -eq $script:accepted) { throw 'Azure CLI failed: {"code":"ResourceNotFound"}' }
                $script:accepted
            }
            { Invoke-DemoAgentScript $journal $path $body } | Should -Throw '*after ARM accepted*'
            $operation=$journal.pendingAgent.operationId
            $operation | Should -Be $script:accepted.tags.operationId
            (Invoke-DemoAgentScript $journal $path $body).ok | Should -BeTrue
            $journal.pendingAgent | Should -BeNullOrEmpty
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'keeps <Provisioning>/<Execution> pending and times out boundedly without overwriting it' -ForEach @(
            @{Provisioning='Creating';Execution='Running'},
            @{Provisioning='Succeeded';Execution='Unknown'}
        ) {
            $body='public __OPERATION_ID__ source'
            $operation=[guid]::NewGuid().ToString()
            $journal.pendingAgent=@{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body)))}
            $script:clock=[datetime]'2026-01-01T00:00:00Z'
            Mock Get-Date { $script:clock=$script:clock.AddSeconds(5); $script:clock }
            Mock Invoke-AzJson { $record=New-TestAgentRecord $operation $body -State $Execution; $record.properties.provisioningState=$Provisioning; $record }
            { Invoke-DemoAgentScript $journal $path $body -ObservationTimeoutSeconds 1 } | Should -Throw '*observation expired*'
            $journal.pendingAgent.operationId | Should -Be $operation
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'put' }
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'get' }
        }
        It 'refuses a fresh submission over an unknown existing managed command' {
            Mock Invoke-AzJson { New-TestAgentRecord ([guid]::NewGuid().ToString()) 'unknown intent' -State Running }
            { Invoke-DemoAgentScript $journal $path 'new public source' } | Should -Throw '*unknown intent*'
            $journal.pendingAgent | Should -BeNullOrEmpty
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'allows the next stage only after proving the exact recorded previous command finished successfully' {
            $oldOperation=[guid]::NewGuid().ToString()
            $oldSource='earlier __OPERATION_ID__ source'
            $journal.agentTimings=@(@{operationId=$oldOperation;sourceDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($oldSource)))})
            $script:command=New-TestAgentRecord $oldOperation $oldSource
            Mock Invoke-AzJson {
                if ($Arguments -contains 'put') {
                    $file=$Arguments[[array]::IndexOf($Arguments,'--body')+1].Substring(1)
                    $request=Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
                    $script:command=New-TestAgentRecord $request.tags.operationId $request.properties.source.script
                }
                $script:command
            }
            (Invoke-DemoAgentScript $journal $path 'next __OPERATION_ID__ source').ok | Should -BeTrue
            $journal.agentTimings.Count | Should -Be 2
            $journal.pendingAgent | Should -BeNullOrEmpty
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'does not resubmit when a retained command is absent or not observable' {
            $body='pending source'
            $operation=[guid]::NewGuid().ToString()
            $journal.pendingAgent=@{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body)))}
            Mock Invoke-AzJson { throw 'Azure CLI failed: {"code":"ResourceNotFound"}' }
            { Invoke-DemoAgentScript $journal $path $body } | Should -Throw '*not observable*'
            $journal.pendingAgent.operationId | Should -Be $operation
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'rejects <Problem> while retaining exact pending intent' -ForEach @(
            @{Problem='wrong installation';Kind='installation'},
            @{Problem='wrong resource';Kind='resource'},
            @{Problem='changed payload';Kind='payload'},
            @{Problem='missing exit status';Kind='exit'},
            @{Problem='wrong final operation';Kind='result'},
            @{Problem='terminal guest failure';Kind='failed'}
        ) {
            $body='public __OPERATION_ID__ source'
            $operation=[guid]::NewGuid().ToString()
            $journal.pendingAgent=@{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body)))}
            $record=New-TestAgentRecord $operation $body
            switch ($Kind) {
                installation { $record.tags.installationId='b'*32 }
                resource { $record.id+='/different' }
                payload { $record.properties.source.script='unexpected payload' }
                exit { $record.properties.instanceView.Remove('exitCode') }
                result { $record.properties.instanceView.output='{"operationId":"wrong","ok":true}' }
                failed { $record.properties.instanceView.executionState='Failed' }
            }
            Mock Invoke-AzJson { $record }
            { Invoke-DemoAgentScript $journal $path $body } | Should -Throw
            $journal.pendingAgent.operationId | Should -Be $operation
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'refuses path traversal before issuing any command' {
            Mock Invoke-DemoAgentScript { throw 'Must not run' }
            { Send-DemoPublicFile $journal $path '/var/lib/demo2-setup/../../etc/shadow' ([byte[]](1,2)) } | Should -Throw '*destination*'
        }
        It 'does not adopt a resource group with a different installation marker' {
            $journal.config.resourceGroup = 'rg-demo2-test'
            $journal.config.subscriptionId = [guid]::NewGuid().ToString()
            $journal.receipts = @{}
            Mock Invoke-AzJson {
                if ($Arguments -contains 'exists') { return $true }
                @{tags=@{purpose='demo2-only';installationId='another-install'}}
            }
            { Assert-DemoInstallOwner $journal } | Should -Throw '*not owned*'
        }
        It 'does not silently recreate a missing previously provisioned group' {
            $journal.config.resourceGroup = 'rg-demo2-test'
            $journal.config.subscriptionId = [guid]::NewGuid().ToString()
            $journal.receipts = @{Foundation=@{}}
            Mock Invoke-AzJson { $false }
            { Assert-DemoInstallOwner $journal } | Should -Throw '*reconciliation*'
        }
        It 'refuses a private install path inside a different Git checkout' {
            $other = Join-Path $TestDrive 'other-checkout'
            New-DemoPrivateDirectory $other
            [void][IO.Directory]::CreateDirectory((Join-Path $other '.git'))
            $install = Join-Path $other 'install'
            New-DemoPrivateDirectory $install
            { Assert-DemoInstallPrivacy $install } | Should -Throw '*another Git checkout*'
        }
        It 'reconciles an already configured install without replaying deployment, activation or key creation' {
            . (Join-Path $script:Kit 'tests\TestData.ps1')
            $config = New-TestConfiguration
            $install = Join-Path $TestDrive 'completed-install'
            New-DemoPrivateDirectory $install
            $journal = @{schemaVersion=1;installationId=[guid]::NewGuid().ToString('N');config=$config
                configFingerprint=(Get-DemoConfigFingerprint $config);sourceFingerprint=(Get-DemoSourceFingerprint)
                pendingAgent=$null;status='ConfiguredNeedsRehearsal';resources=@{}
                receipts=@{Custody=@{};Foundation=@{};PublicPayload=@{};Guest=@{};DomainBackup=@{};Keys=@{};Storage=@{};Content=@{};Worker=@{};Reduced=@{}}}
            foreach ($name in 'controllerIdentityClientId','controllerPrincipalId','liveStorageIdentityPrincipalId','twinStorageIdentityPrincipalId') { $journal.resources[$name]=$config[$name] }
            Save-DemoJournal $journal (Join-Path $install 'install.json')
            # Use the real journal writer in this test, not the transport fixture mock.
            $journal | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $install 'install.json')
            Mock Assert-DemoAzureContext {}
            Mock Assert-DemoInstallOwner { $true }
            Mock Send-DemoPublicFile {}
            Mock Invoke-DemoGuestStage { @{state='ConfiguredNeedsRehearsal';demoReady=$false} }
            Mock Invoke-AzJson { throw 'Completed install must not replay Azure mutations' }
            $result = Invoke-DemoSetup -Mode Setup -InstallPath $install
            $result | Should -Match 'NOT demo-ready'
            Should -Invoke Invoke-AzJson -Times 0
            Should -Invoke Invoke-DemoGuestStage -Times 1 -ParameterFilter { $Action -eq 'Status' }
        }
    }
}

Describe 'Read-only setup diagnostics and protected error metadata (offline)' -Skip:(-not $IsWindows) {
        BeforeEach {
            . (Join-Path $PSScriptRoot 'TestData.ps1')
            $directory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-DemoPrivateDirectory $directory
            [IO.File]::WriteAllText((Join-Path $directory '.setup.lock'),'')
            $config=New-TestConfiguration
            $operation=[guid]::NewGuid().ToString()
            $body='synthetic __OPERATION_ID__ public source'
            $journal=@{schemaVersion=1;installationId=('a'*32);config=$config;configFingerprint=(Get-DemoConfigFingerprint $config)
                status='Preparing';receipts=@{Custody=@{};Foundation=@{}};resources=@{vmId="/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)/providers/Microsoft.Compute/virtualMachines/demo2-test"}
                pendingAgent=@{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body)));startedUtc=[datetimeoffset]::UtcNow.ToString('o')}}
            $journalPath=Join-Path $directory 'install.json'
            Save-DemoJournal $journal $journalPath
            Protect-DemoPrivateFile $journalPath
            $before=(Get-FileHash $journalPath).Hash
            Mock Save-DemoJournal -ModuleName Demo.Setup { throw 'Diagnostic must not rewrite a journal' }
            Mock Invoke-AzJson -ModuleName Demo.Setup { throw 'Unexpected Azure request' }
            Mock Assert-DemoAzureContext -ModuleName Demo.Setup {}
        }
        It 'reports only local progress by default with no Azure access or journal changes' {
            $result=& (Join-Path $PSScriptRoot '..\scripts\Get-SetupDiagnostic.ps1') -InstallPath $directory | ConvertFrom-Json
            $result.mode | Should -Be 'LocalProgressOnly'
            $result.pendingOperationId | Should -Be $operation
            (Get-FileHash $journalPath).Hash | Should -Be $before
            Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 0
            Should -Invoke Save-DemoJournal -ModuleName Demo.Setup -Times 0
        }
        It 'reads and proves only exact pending command metadata without PUT, payload output or journal migration' {
            Mock Invoke-AzJson -ModuleName Demo.Setup {
                if ($Arguments -contains 'account') { return @{id=$config.subscriptionId;tenantId=$config.tenantId;environmentName='AzureCloud'} }
                @{id="$($journal.resources.vmId)/runCommands/demo2-field-setup";location=$config.location;tags=@{installationId=$journal.installationId;operationId=$operation}
                    properties=@{source=@{script=$body.Replace('__OPERATION_ID__',$operation)};provisioningState='Succeeded'
                        instanceView=@{executionState='Succeeded';exitCode=0;output=(@{operationId=$operation;ok=$true;DO_NOT_LOG_PAYLOAD='DO_NOT_LOG_SECRET'} | ConvertTo-Json -Compress)}}}
            }
            $text=& (Join-Path $PSScriptRoot '..\scripts\Get-SetupDiagnostic.ps1') -InstallPath $directory -ReadManagedCommand | Out-String
            $result=$text | ConvertFrom-Json
            $result.command.finalReceiptVerified | Should -BeTrue
            $result.command.ownershipAndPayloadMatch | Should -BeTrue
            $text | Should -Not -Match 'DO_NOT_LOG|public source'
            (Get-FileHash $journalPath).Hash | Should -Be $before
            Should -Invoke Assert-DemoAzureContext -ModuleName Demo.Setup -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -ModuleName Demo.Setup -Times 0 -ParameterFilter { $Arguments -contains 'put' }
            Should -Invoke Save-DemoJournal -ModuleName Demo.Setup -Times 0
        }
        It 'writes current-user-only sanitized ErrorRecord metadata, not target objects or ErrorDetails' {
            $exception=[InvalidOperationException]::new('Safe CLI failure')
            $exception.Data['AzureCliExitCode']=1
            $exception.Data['StderrClassification']='Usage'
            $exception.Data['UnknownRawField']='DO_NOT_LOG_UNKNOWN'
            $record=[Management.Automation.ErrorRecord]::new($exception,'AzureCliFailure',[Management.Automation.ErrorCategory]::InvalidOperation,'DO_NOT_LOG_TARGET')
            $record.ErrorDetails=[Management.Automation.ErrorDetails]::new('DO_NOT_LOG_DETAILS')
            $diagnostic=& (Get-Module Demo.Setup) { param($R,$D) Save-DemoSetupDiagnostic $R $D 'PublicPayload/config.schema.json' } $record $directory
            Assert-DemoPrivatePath $diagnostic
            $text=Get-Content $diagnostic -Raw
            $text | Should -Not -Match 'DO_NOT_LOG'
            $saved=$text | ConvertFrom-Json
            $saved.stage | Should -Be 'PublicPayload/config.schema.json'
            $saved.cli.AzureCliExitCode | Should -Be 1
            $saved.cli.StderrClassification | Should -Be 'Usage'
    }
}

Describe 'Fresh encrypted custody (local synthetic keys only)' -Skip:(-not $IsWindows) {
    BeforeAll {
        $custody = Join-Path $TestDrive 'protected-install'
        $backup = Join-Path $TestDrive 'protected-backup'
        New-DemoPrivateDirectory $custody
        $passphrase = New-TestPassphrase
        New-DemoCustody $custody $backup $passphrase ([guid]::NewGuid().ToString('N'))
    }
    It 'exports no unencrypted wrapping private keys and validates the retained PFX' {
        Test-DemoCustodyBackup $custody $passphrase
        @(Get-ChildItem $custody -Filter '*.key').Count | Should -Be 0
        @(Get-ChildItem $custody -Filter '*.cer').Count | Should -Be 5
        Assert-DemoPrivatePath (Join-Path $custody 'custody.pfx')
    }
    It 'refuses accidental regeneration over an existing custody package' {
        { New-DemoCustody $custody $backup $passphrase ([guid]::NewGuid().ToString('N')) } | Should -Throw '*already exists*'
    }
    It 'rejects a wrong backup passphrase' {
        $wrong = New-TestPassphrase
        { Test-DemoCustodyBackup $custody $wrong } | Should -Throw
    }
    It 'decrypts a synthetic domain envelope without returning plaintext' {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
        $public = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText((Join-Path $custody 'recipient.cer')))
        try {
            $cms = [Security.Cryptography.Pkcs.EnvelopedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new([Text.Encoding]::UTF8.GetBytes('{"EncData":"synthetic-not-an-azure-domain"}')))
            $cms.Encrypt([Security.Cryptography.Pkcs.CmsRecipient]::new($public))
            $path = Join-Path $custody 'synthetic-domain.cms'
            [IO.File]::WriteAllBytes($path,$cms.Encode())
            @(Test-DemoDomainEnvelope $custody $passphrase $path).Count | Should -Be 0
        } finally { $public.Dispose() }
    }
}
