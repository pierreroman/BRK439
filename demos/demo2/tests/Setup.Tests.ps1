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

Describe 'Managed command reconciliation with Azure mocked' {
    InModuleScope Demo.Setup {
        BeforeEach {
            $journal = @{installationId='a'*32;config=@{location='test'};resources=@{vmId='/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/test'};pendingAgent=$null;publicUploads=@{}}
            $path = Join-Path $TestDrive 'agent-journal.json'
            Mock Save-DemoJournal {}
            Mock Start-Sleep {}
        }
        It 'refuses a different command while an earlier outcome is unresolved' {
            $journal.pendingAgent = @{operationId=[guid]::NewGuid().ToString();digest='unresolved-other-script'}
            Mock Invoke-AzJson { throw 'No Azure call allowed' }
            { Invoke-DemoAgentScript $journal $path 'public source' } | Should -Throw '*unresolved*'
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'observes a pending command without resubmitting its PUT' {
            $script = 'public source'
            $operation = [guid]::NewGuid().ToString()
            $journal.pendingAgent = @{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))}
            Mock Invoke-AzJson {
                @{tags=@{operationId=$operation};properties=@{instanceView=@{executionState='Succeeded';exitCode=0;output=(@{operationId=$operation;ok=$true}|ConvertTo-Json -Compress)}}}
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
            Mock Invoke-AzJson { @{tags=@{operationId=$operation};properties=@{provisioningState='Succeeded';instanceView=@{executionState='Failed';exitCode=2;output=''}}} }
            { Invoke-DemoAgentScript $journal $path $script } | Should -Throw '*failed*'
        }
        It 'retains unknown/truncated output for reconciliation' {
            $script = 'public source'
            $operation = [guid]::NewGuid().ToString()
            $journal.pendingAgent = @{operationId=$operation;digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))}
            Mock Invoke-AzJson { @{tags=@{operationId=$operation};properties=@{instanceView=@{executionState='Succeeded';exitCode=0;output='truncated-json'}}} }
            { Invoke-DemoAgentScript $journal $path $script } | Should -Throw '*truncated*'
            $journal.pendingAgent.operationId | Should -Be $operation
        }
        It 'rejects a stale command owned by another operation before accepting output' {
            $script = 'public source'
            $journal.pendingAgent = @{operationId=[guid]::NewGuid().ToString();digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))}
            Mock Invoke-AzJson { @{tags=@{operationId=[guid]::NewGuid().ToString()}} }
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
