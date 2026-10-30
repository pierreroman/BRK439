BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
}

Describe 'Value-only lifecycle orchestration (offline; synthetic local custody)' -Skip:(-not $IsWindows) {
    InModuleScope Demo.Setup {
        BeforeEach {
            $install=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $backup=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-DemoPrivateDirectory $install
            $script:answers=[Collections.Generic.Queue[object]]::new()
            $script:prompts=[Collections.Generic.List[string]]::new()
            $script:stages=[Collections.Generic.List[string]]::new()
            $script:previewFails=$false
            $script:domainMalformed=$false
            $script:secret=[securestring]::new()
            foreach ($value in [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) { $script:secret.AppendChar([char](33+($value % 90))) }
            $script:issuedSecret=$script:secret.Copy()
            foreach ($value in @('1','1','1','1','presenter@example.com','100','10.91.0.0/24',$backup,$script:issuedSecret,$script:secret.Copy())) {
                $script:answers.Enqueue($value)
            }
            Mock Read-Host {
                $script:prompts.Add($Prompt)
                if (-not $script:answers.Count) { throw 'Unexpected extra prompt' }
                $script:answers.Dequeue()
            }
            Mock Assert-DemoSecureInputAvailable {}
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Write-Error {}
            Mock Get-DemoSourceFingerprint { 'synthetic-current' }
            Mock Assert-DemoAzureContext {}
            Mock Import-DemoConfig {}
            Mock Test-DemoFieldPreflight {}
            Mock Assert-DemoInstallOwner { $Journal.receipts.ContainsKey('Foundation') }
            Mock Send-DemoPublicFile {}
            Mock Invoke-DemoAgentScript { @{ok=$true} }
            Mock Invoke-DemoFieldRun {}
            Mock az {
                if (($args -join ' ') -notmatch '^account set --subscription 11111111-1111-1111-1111-111111111111$') {
                    throw 'OFFLINE: unexpected direct Azure CLI'
                }
                $global:LASTEXITCODE=0
            }
            Mock Invoke-AzJson {
                if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'list') {
                    return @{name='Synthetic';id='11111111-1111-1111-1111-111111111111';tenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}
                }
                if ($Arguments -contains 'list-locations') { return @(@{name='westus2'},@{name='eastus'}) }
                if ($Arguments -contains 'list-skus') {
                    return @{name='Standard_DC2as_v6';family='confidential';restrictions=@()
                        capabilities=@(@{name='ConfidentialComputingType';value='SNP'},@{name='vCPUs';value='2'})}
                }
                if ($Arguments -contains 'list-usage') {
                    return @(@{name=@{value='confidential'};limit=20;currentValue=0},@{name=@{value='cores'};limit=20;currentValue=0})
                }
                if ($Arguments -contains 'image') {
                    return @{publisher='Canonical';offer='0001-com-ubuntu-confidential-vm-jammy';sku='22_04-lts-cvm';version='1.0.0'}
                }
                if ($Arguments -contains 'signed-in-user') { return @{id='cccccccc-cccc-cccc-cccc-cccccccccccc'} }
                if ($Arguments -contains 'vnet') { return @() }
                if ($Arguments -contains 'what-if') { return @{status=$(if ($script:previewFails) { 'Failed' } else { 'Succeeded' })} }
                if ($Arguments[0] -eq 'deployment' -and $Arguments -contains 'create') {
                    return @{id='synthetic-deployment';properties=@{provisioningState='Succeeded';outputs=@{foundationResources=@{value=@{
                        vmId='synthetic-vm';custodyDiskId='synthetic-disk';controllerIdentityClientId='synthetic-client'
                        controllerPrincipalId='synthetic-controller';liveStorageIdentityPrincipalId='synthetic-live'
                        twinStorageIdentityPrincipalId='synthetic-twin';bootstrapClientId='synthetic-bootstrap-client'
                        bootstrapPrincipalId='synthetic-bootstrap';bootstrapIdentityId='synthetic-bootstrap-identity'
                        bootstrapReaderAssignmentId='synthetic-bootstrap-reader'
                    }}}}}
                }
                if ($Arguments[0] -eq 'role' -and $Arguments -contains 'create') { return @{id='synthetic-upload-role'} }
                if ($Arguments[0] -eq 'role' -and $Arguments -contains 'list') { return @() }
                if ($Arguments[0] -eq 'role' -and $Arguments -contains 'delete') { return }
                if ($Arguments[0] -eq 'vm' -and $Arguments -contains 'remove') { return }
                if ($Arguments[0] -eq 'vm' -and $Arguments -contains 'show') { return @{identity=@{userAssignedIdentities=@{}}} }
                throw "OFFLINE: unrecognized mocked Azure request: $($Arguments -join ' ')"
            }
            Mock Invoke-DemoGuestStage {
                $script:stages.Add($Action)
                switch ($Action) {
                    Inspect { return @{hostKey='ssh-ed25519 synthetic-fixture'} }
                    Activate {
                        if (-not (Test-Path (Join-Path $InstallPath 'custody.json'))) { throw 'Activation before encrypted custody' }
                        return @{digest='synthetic-domain-digest'}
                    }
                    Keys {
                        if (-not $Journal.receipts.ContainsKey('DomainBackup')) { throw 'Keys before domain backup' }
                        $local=Join-Path $InstallPath 'security-domain.cms'
                        if ((Get-FileHash $local).Hash -cne (Get-FileHash $Journal.receipts.DomainBackup.path).Hash) { throw 'Domain backup differs' }
                        $targets=$Journal.config.targets
                        $targets.Live.keyVersion='11111111111111111111111111111111'
                        $targets.Twin.keyVersion='22222222222222222222222222222222'
                        return @{targets=$targets}
                    }
                    { $_ -in 'Content','Worker','Reduce','Status' } { return @{verified=$true} }
                    default { throw "OFFLINE: unexpected guest stage $Action" }
                }
            }
            Mock Receive-DemoEnvelope {
                Add-Type -AssemblyName System.Security.Cryptography.Pkcs
                $recipient=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
                    [IO.File]::ReadAllText((Join-Path $install 'recipient.cer')))
                try {
                    $text=if ($script:domainMalformed) { '{"NotDomain":true}' } else { '{"EncData":"synthetic-domain"}' }
                    $cms=[Security.Cryptography.Pkcs.EnvelopedCms]::new(
                        [Security.Cryptography.Pkcs.ContentInfo]::new([Text.Encoding]::UTF8.GetBytes($text)))
                    $cms.Encrypt([Security.Cryptography.Pkcs.CmsRecipient]::new($recipient))
                    return ,$cms.Encode()
                } finally { $recipient.Dispose() }
            }
        }
        AfterEach {
            $script:secret.Dispose()
            while ($script:answers.Count) {
                $remaining=$script:answers.Dequeue()
                if ($remaining -is [securestring]) { $remaining.Dispose() }
            }
        }
        It 'completes first-run with exactly required values/secrets, then resumes configured state without prompts' {
            Invoke-DemoSetup -Mode Setup -InstallPath $install
            { $copy=$script:issuedSecret.Copy(); $copy.Dispose() } | Should -Throw '*disposed*'
            $script:answers.Count | Should -Be 0
            $script:prompts.Count | Should -Be 10
            ($script:prompts -join "`n") | Should -Not -Match '(?-i:Type exactly|CONFIRM TARGET|APPROVE|ACCEPT)|quote|hourly|monthly estimate|risk acknowledgement'
            @($script:prompts | Where-Object { $_ -like '*passphrase*' }).Count | Should -Be 2
            $journalPath=Join-Path $install 'install.json'
            $journal=Get-Content $journalPath -Raw | ConvertFrom-Json -AsHashtable
            $journal.status | Should -Be 'ConfiguredNeedsRehearsal'
            $journal.receipts.ContainsKey('Cost') | Should -BeFalse
            $journal.receipts.ContainsKey('DomainBackup') | Should -BeTrue
            $journal.config.targets.Live.keyVersion | Should -Not -Be $journal.config.targets.Twin.keyVersion
            ($script:stages -join ',') | Should -Be 'Inspect,Activate,Keys,Content,Worker,Reduce,Status'
            Should -Invoke Test-DemoFieldPreflight -Times 1 -Exactly
            $archive=Join-Path $install 'custody.pfx'
            $before=(Get-FileHash $archive).Hash
            $script:prompts.Clear()
            Invoke-DemoSetup -Mode Setup -InstallPath $install
            $script:prompts.Count | Should -Be 0
            (Get-FileHash $archive).Hash | Should -Be $before
            Should -Invoke Invoke-AzJson -Times 2 -Exactly -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments -contains 'create' }
            Should -Invoke Invoke-DemoGuestStage -Times 1 -Exactly -ParameterFilter { $Action -eq 'Activate' }
            Should -Invoke Invoke-DemoFieldRun -Times 0
        }
        It 'keeps values and encrypted keys after failed preview; resume asks once for the retained secret only' {
            $script:previewFails=$true
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*what-if did not succeed*'
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'create' }
            $archive=Join-Path $install 'custody.pfx'
            $before=(Get-FileHash $archive).Hash
            $script:previewFails=$false
            $script:answers.Enqueue($script:secret.Copy())
            $script:prompts.Clear()
            Invoke-DemoSetup -Mode Setup -InstallPath $install
            $script:prompts.Count | Should -Be 1
            $script:prompts[0] | Should -BeLike 'Existing custody passphrase*'
            (Get-FileHash $archive).Hash | Should -Be $before
            Should -Invoke az -Times 1 -Exactly
        }
        It 'fails before activation/deployment if the retained encrypted backup is missing' {
            $script:previewFails=$true
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*what-if did not succeed*'
            $receipt=Get-Content (Join-Path $install 'custody.json') -Raw | ConvertFrom-Json -AsHashtable
            Remove-Item -LiteralPath $receipt.backupFile
            $script:answers.Enqueue('q')
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*cancelled*'
            Should -Invoke Invoke-DemoGuestStage -Times 0
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'create' }
            Test-Path (Join-Path $install 'custody.pfx') | Should -BeTrue
        }
        It 'never creates keys or storage when actual encrypted domain readability fails' {
            $script:domainMalformed=$true
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*not a security-domain document*'
            Should -Invoke Invoke-DemoGuestStage -Times 0 -ParameterFilter { $Action -eq 'Keys' }
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'stage=storage' }
            $journal=Get-Content (Join-Path $install 'install.json') -Raw | ConvertFrom-Json -AsHashtable
            $journal.receipts.ContainsKey('DomainBackup') | Should -BeFalse
            $journal.receipts.ContainsKey('DomainActivated') | Should -BeTrue
        }
        It 'rechecks a retained security-domain backup on resume before creating any CMKs' {
            Mock Invoke-DemoGuestStage { throw 'Synthetic stop before CMKs' } -ParameterFilter { $Action -eq 'Keys' }
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*Synthetic stop before CMKs*'
            $journal=Get-Content (Join-Path $install 'install.json') -Raw | ConvertFrom-Json -AsHashtable
            Remove-Item -LiteralPath $journal.receipts.DomainBackup.path
            $script:answers.Enqueue($script:secret.Copy())
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*Security-domain backup is unavailable*before creating CMKs*'
            Should -Invoke Invoke-DemoGuestStage -Times 1 -Exactly -ParameterFilter { $Action -eq 'Keys' }
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'stage=storage' -and $Arguments -contains 'create' }
        }
        It 'keeps <Mode> local and nonmutating even with the legacy live switch' -ForEach @(
            @{Mode='Status'},@{Mode='RetirementPlan'}
        ) {
            . (Join-Path $script:Kit 'tests\TestData.ps1')
            $config=New-TestConfiguration
            $path=Join-Path $install 'install.json'
            Save-DemoJournal @{schemaVersion=1;installationId=[guid]::NewGuid().ToString('N');config=$config
                configFingerprint=(Get-DemoConfigFingerprint $config);sourceFingerprint='unknown';status='Preparing';receipts=@{}} $path
            $before=(Get-FileHash $path).Hash
            $null=Invoke-DemoSetup -Mode $Mode -InstallPath $install -AuthorizeLiveChanges
            (Get-FileHash $path).Hash | Should -Be $before
            Should -Invoke Invoke-AzJson -Times 0
            Should -Invoke Read-Host -Times 0
            Should -Invoke Invoke-DemoFieldRun -Times 0
        }
        It 'uses the requested <Mode> as runtime intent without extra approval or live switches' -ForEach @(
            @{Mode='Run'},@{Mode='Rehearse'}
        ) {
            . (Join-Path $script:Kit 'tests\TestData.ps1')
            $config=New-TestConfiguration
            Save-DemoJournal @{schemaVersion=1;installationId=[guid]::NewGuid().ToString('N');config=$config
                configFingerprint=(Get-DemoConfigFingerprint $config);sourceFingerprint='synthetic-current'
                status='ConfiguredNeedsRehearsal';receipts=@{}} (Join-Path $install 'install.json')
            $script:expectedMode=$Mode
            Invoke-DemoSetup -Mode $Mode -InstallPath $install
            Should -Invoke Invoke-DemoFieldRun -Times 1 -Exactly -ParameterFilter { $Mode -eq $script:expectedMode }
            Should -Invoke Read-Host -Times 0
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'contains no orchestrated approval/quote reader and explicitly suppresses nested ShouldProcess confirmations' {
            $source=[IO.File]::ReadAllText((Join-Path $script:Kit 'scripts\Demo.Setup.psm1'))
            $source | Should -Not -Match 'Confirm-DemoCheckpoint|ShouldProcess|Read-DemoText .Quote|Reviewed Managed HSM hourly|I UNDERSTAND THE RISKS|ACCEPT PROMPT'
            $source | Should -Match 'Test-PolicyExamples.ps1.*-AuthorizeLiveChanges -PolicyReviewConfirmed -Confirm:\$false'
            $source | Should -Match 'Invoke-LiveRehearsal.ps1.*-AuthorizeLiveChanges'
            $guest=[IO.File]::ReadAllText((Join-Path $script:Kit 'host\Invoke-SetupStage.ps1'))
            foreach ($scriptName in @('Initialize-Hsm','Initialize-Content','Install-Watchdog')) {
                $guest | Should -Match "$scriptName.ps1.*-Confirm:\`$false"
            }
        }
    }
}
