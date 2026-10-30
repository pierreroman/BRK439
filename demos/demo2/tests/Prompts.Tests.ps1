BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Custody.psm1')
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Custody.psm1')
}

Describe 'Shared lifecycle prompt boundaries (offline)' {
    InModuleScope Demo.Setup {
        BeforeAll {
            function New-PromptSecret {
                param([int]$Length=32)
                $value=[securestring]::new()
                foreach ($byte in [Security.Cryptography.RandomNumberGenerator]::GetBytes($Length)) { $value.AppendChar([char](33+($byte % 90))) }
                return $value
            }
        }
        BeforeEach {
            $script:answers=[Collections.Generic.Queue[object]]::new()
            Mock Read-Host { $script:answers.Dequeue() }
            Mock Assert-DemoSecureInputAvailable {}
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock az { throw 'OFFLINE: unexpected Azure CLI' }
            Mock Invoke-AzJson { throw 'OFFLINE: unexpected Azure operation' }
        }
        It 'retries <Kind> amount input without a default' -ForEach @(
            @{Kind='blank';Value=''},@{Kind='text';Value='unknown'},@{Kind='zero';Value='0'},
            @{Kind='negative';Value='-1'},@{Kind='currency symbol';Value='$12'},
            @{Kind='grouped';Value='1,000'},@{Kind='NaN';Value='NaN'},
            @{Kind='overflow';Value='999999999999999999999999999999999999'}
        ) {
            $script:answers.Enqueue($Value); $script:answers.Enqueue('12.50')
            Read-DemoPositiveAmount 'Synthetic reviewed amount' | Should -Be 12.50
            Should -Invoke Read-Host -Times 2 -Exactly
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*positive amount*1234.56*' }
        }
        It 'retries an invalid email and keeps the valid result' {
            $script:answers.Enqueue('not-an-email'); $script:answers.Enqueue('presenter@example.com')
            Read-DemoEmail | Should -Be 'presenter@example.com'
            Should -Invoke Read-Host -Times 2 -Exactly
        }
        It 'retries empty required text without losing an earlier valid value' {
            foreach ($value in @('100','','synthetic required value')) { $script:answers.Enqueue($value) }
            Read-DemoPositiveAmount 'Budget' | Should -Be 100
            Read-DemoText 'Required text' | Should -Be 'synthetic required value'
            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Budget*' }
            Should -Invoke Read-Host -Times 2 -Exactly -ParameterFilter { $Prompt -like 'Required text*' }
        }
        It 'retries <Kind> CIDR input and generates contained disjoint subnets' -ForEach @(
            @{Kind='invalid octets';Value='999.91.0.0/24'},
            @{Kind='host bits';Value='10.91.0.1/24'},
            @{Kind='wrong prefix';Value='10.91.0.0/25'},
            @{Kind='public address';Value='8.8.8.0/24'},
            @{Kind='leading zeros';Value='010.091.000.0/24'},
            @{Kind='overlap';Value='10.92.0.0/24'}
        ) {
            $script:answers.Enqueue($Value); $script:answers.Enqueue('10.91.0.0/24')
            $cidr=Read-DemoVnetCidr @('10.92.0.0/16','fd00::/64')
            $config=@{network=@{}}
            Set-DemoFieldNetwork $config $cidr
            $config.network.vnetCidr | Should -Be '10.91.0.0/24'
            $config.network.computeSubnetCidr | Should -Be '10.91.0.0/26'
            $config.network.endpointSubnetCidr | Should -Be '10.91.0.64/27'
            $config.network.bastionSubnetCidr | Should -Be '10.91.0.128/26'
            Should -Invoke Read-Host -Times 2 -Exactly
        }
        It 'revalidates only the conflicting saved CIDR during preflight' {
            $script:answers.Enqueue('10.91.0.0/24')
            Read-DemoVnetCidr -ExistingCidrs @('10.92.0.0/24') -CurrentValue '10.92.0.0/24' | Should -Be '10.91.0.0/24'
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'cancels text input on <Kind> without a busy loop' -ForEach @(
            @{Kind='EOF';Value=$null;Expected='*EOF*'},@{Kind='q';Value='q';Expected='*cancelled*'},@{Kind='cancel';Value='cancel';Expected='*cancelled*'}
        ) {
            $script:answers.Enqueue($Value)
            { Read-DemoText 'Synthetic text' } | Should -Throw $Expected
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'cancels unavailable or interrupted host input without retrying' {
            Mock Read-Host { throw [OperationCanceledException]::new('Synthetic host interruption') }
            { Read-DemoText 'Synthetic text' } | Should -Throw '*Input unavailable or cancelled*'
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'does not retry unexpected validator IO failures' {
            $script:answers.Enqueue('synthetic')
            { Read-DemoText 'Synthetic text' { throw [IO.IOException]::new('Unexpected disk failure') } } | Should -Throw '*Unexpected disk failure*'
            Should -Invoke Read-Host -Times 1 -Exactly
            Should -Invoke Write-Warning -Times 0
        }
        It 'retries a short passphrase and only the incorrect confirmation, without revealing either' {
            $short=New-PromptSecret 4; $good=New-PromptSecret; $wrong=New-PromptSecret
            $script:answers.Enqueue($short); $script:answers.Enqueue($good)
            $script:answers.Enqueue($wrong); $script:answers.Enqueue($good.Copy())
            $result=Read-DemoNewPassphrase
            try { [object]::ReferenceEquals($result,$good) | Should -BeTrue }
            finally { $result.Dispose() }
            Should -Invoke Read-Host -Times 2 -Exactly -ParameterFilter { $Prompt -like 'New custody*' -and $AsSecureString }
            Should -Invoke Read-Host -Times 2 -Exactly -ParameterFilter { $Prompt -like 'Re-enter*' -and $AsSecureString }
            Should -Invoke Write-Warning -Times 2 -Exactly
        }
        It 'cancels secure input on <Kind> without retrying' -ForEach @(
            @{Kind='EOF';Cancel=$null},@{Kind='empty';Cancel=''},@{Kind='q';Cancel='q'}
        ) {
            $value=$null
            if ($null -ne $Cancel) {
                $value=[securestring]::new()
                foreach ($character in $Cancel.ToCharArray()) { $value.AppendChar($character) }
            }
            $script:answers.Enqueue($value)
            { Read-DemoNewPassphrase } | Should -Throw '*custody*'
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'retries only failed password authentication, not arbitrary cryptographic failures' {
            Mock Resolve-DemoCustodyBackupLocation { @{SourcePath='synthetic';Recover=$false} }
            $wrong=New-PromptSecret; $good=New-PromptSecret
            $script:answers.Enqueue($wrong); $script:answers.Enqueue($good)
            $script:macChecks=0
            Mock Test-DemoCustodyPassword { ++$script:macChecks -eq 2 }
            Mock Test-DemoCustodyBackup {}
            $result=Read-DemoCustodyPassphrase 'synthetic-not-read'
            try { [object]::ReferenceEquals($result,$good) | Should -BeTrue } finally { $result.Dispose() }
            Should -Invoke Test-DemoCustodyBackup -Times 1 -Exactly
            Should -Invoke Read-Host -Times 2 -Exactly
        }
        It 'surfaces malformed retained archives without requesting another password' {
            Mock Resolve-DemoCustodyBackupLocation { @{SourcePath='synthetic';Recover=$false} }
            $script:answers.Enqueue((New-PromptSecret))
            Mock Test-DemoCustodyPassword { throw [Security.Cryptography.CryptographicException]::new('Malformed synthetic archive') }
            { Read-DemoCustodyPassphrase 'synthetic-not-read' } | Should -Throw '*Malformed synthetic archive*'
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'shows a numeric suggestion but never accepts it on Enter' {
            $script:answers.Enqueue(''); $script:answers.Enqueue('2')
            $result=Select-DemoValue 'Synthetic choice' @(@{name='first'},@{name='second'}) 'name' -SuggestedIndex 2 -SuggestionReason 'Synthetic catalog evidence.'
            $result.name | Should -Be 'second'
            Should -Invoke Read-Host -Times 2 -Exactly
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Suggested choice 2: second*Enter does not accept it*' }
        }
        It 'suggests a listed DC2 SKU only with enough <Description>' -ForEach @(
            @{Description='family and regional quota';FamilyLimit=20;RegionalLimit=20;ExpectedIndex=2},
            @{Description='family quota missing';FamilyLimit=1;RegionalLimit=20;ExpectedIndex=0},
            @{Description='regional quota missing';FamilyLimit=20;RegionalLimit=1;ExpectedIndex=0}
        ) {
            $skus=@(
                @{name='Standard_DC8as_v6';family='confidential';capabilities=@(@{name='vCPUs';value='8'})},
                @{name='Standard_DC2as_v6';family='confidential';capabilities=@(@{name='vCPUs';value='2'})}
            )
            $usage=@(@{name=@{value='confidential'};limit=$FamilyLimit;currentValue=0},@{name=@{value='cores'};limit=$RegionalLimit;currentValue=0})
            Get-DemoSkuSuggestion $skus $usage | Should -Be $ExpectedIndex
            Get-DemoSkuSuggestion $skus @() | Should -Be 0
        }
        It 'proposes a CIDR outside known overlap and labels the discovery limits' {
            $script:answers.Enqueue('10.92.0.0/24')
            Read-DemoVnetCidr -ExistingCidrs @('10.91.0.0/16') -DiscoveryVerified | Should -Be '10.92.0.0/24'
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Suggested network: 10.92.0.0/24*discovered subscription VNets only*NOT verified*Enter does not accept it*' }
        }
        It 'offers no invalid CIDR default when the bounded example ranges all overlap' {
            $script:answers.Enqueue('q')
            { Read-DemoVnetCidr @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16') } | Should -Throw '*cancelled*'
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'No nonoverlapping network suggestion*no default*' }
            Should -Invoke Read-Host -Times 1 -Exactly
        }
        It 'centralizes every custom lifecycle Read-Host in the guarded reader' {
            $calls=@(foreach ($directory in @('scripts','host')) {
                foreach ($file in Get-ChildItem (Join-Path $script:Kit $directory) -Recurse -File -Include '*.ps1','*.psm1') {
                    $tokens=$null; $errors=$null
                    $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
                    foreach ($command in $ast.FindAll({param($Node) $Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Read-Host'},$true)) {
                        $parent=$command.Parent
                        while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent=$parent.Parent }
                        @{file=$file.Name;function=$parent.Name}
                    }
                }
            })
            $calls.Count | Should -Be 1
            $calls[0].file | Should -Be 'Demo.Setup.psm1'
            $calls[0].function | Should -Be 'Read-DemoAnswer'
        }
        It 'retains earlier choices through invalid region, SKU, email, budget and network input' {
            $script:subscriptions=@(
                @{name='Duplicate';id='11111111-1111-1111-1111-111111111111';tenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'},
                @{name='Duplicate';id='22222222-2222-2222-2222-222222222222';tenantId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}
            )
            Mock Invoke-AzJson {
                if ($Arguments -contains 'list-locations') { return @(@{name='first'},@{name='second'}) }
                if ($Arguments -contains 'list-skus') { return @{name='Standard_DC2as_v6';restrictions=@();capabilities=@(@{name='ConfidentialComputingType';value='SNP'})} }
                if ($Arguments -contains 'list-usage') { return @() }
                if ($Arguments -contains 'image') { return @{publisher='Canonical';offer='confidential';sku='cvm';version='1.0.0'} }
                if ($Arguments -contains 'signed-in-user') { return @{id='cccccccc-cccc-cccc-cccc-cccccccccccc'} }
                if ($Arguments -contains 'network') { return @{addressSpace=@{addressPrefixes=@('10.92.0.0/24')}} }
                if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'list') { return $script:subscriptions }
                throw 'Unexpected synthetic discovery request'
            }
            Mock az { $global:LASTEXITCODE=0 }
            foreach ($value in @('2','bad','1','0','1','1','bad-email','presenter@example.com','0','100','10.92.0.1/24','10.92.0.0/24','10.91.0.0/24')) { $script:answers.Enqueue($value) }
            $config=New-DemoFieldConfig
            $config.subscriptionId | Should -Be $script:subscriptions[1].id
            $config.location | Should -Be 'first'
            $config.vmSize | Should -Be 'Standard_DC2as_v6'
            $config.alertEmail | Should -Be 'presenter@example.com'
            $config.budgetAmount | Should -Be 100
            $config.network.vnetCidr | Should -Be '10.91.0.0/24'
            Should -Invoke az -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'account' -and $Arguments[1] -eq 'list' }
            Should -Invoke Read-Host -Times 2 -Exactly -ParameterFilter { $Prompt -like '*example 100*NOT a price estimate or spending cap*Enter does not accept a suggestion*' }
        }
    }
}

Describe 'Backup paths are read-only validated before secure input (synthetic directories)' -Skip:(-not $IsWindows) {
    InModuleScope Demo.Setup {
        BeforeEach {
            $install=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-DemoPrivateDirectory $install
            $id=[guid]::NewGuid().ToString('N')
            $safe=Join-Path $TestDrive "backup-$id"
            $script:pathAnswers=[Collections.Generic.Queue[object]]::new()
            Mock Read-Host { $script:pathAnswers.Dequeue() }
            Mock Assert-DemoSecureInputAvailable {}
            Mock Write-Warning {}
            Mock Write-Host {}
            Mock New-DemoCustody { throw 'Should not create custody before validated secure input' }
            Mock New-DemoPrivateDirectory { throw 'Path validation must not create/change directories' }
        }
        It 'rejects drive roots before asking for a passphrase or creating any folder' {
            $script:pathAnswers.Enqueue([IO.Path]::GetPathRoot($install))
            $script:pathAnswers.Enqueue($safe)
            $script:pathAnswers.Enqueue([securestring]::new())
            { Initialize-DemoFieldCustody $install $id } | Should -Throw '*Secure input cancelled*'
            Should -Invoke Read-Host -Times 2 -Exactly -ParameterFilter { -not $AsSecureString }
            Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $AsSecureString }
            Should -Invoke New-DemoPrivateDirectory -Times 0
            Should -Invoke New-DemoCustody -Times 0
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like '*<your-drive>:\Demo2-Recovery\*No drive, encryption or offline custody is assumed*' }
            Test-Path -LiteralPath $safe | Should -BeFalse
        }
        It 'rejects relative, root, nested, ancestor and reserved path inputs before mutation' {
            foreach ($path in @('relative','Registry:\HKCU',([IO.Path]::GetPathRoot($install)),$install,(Join-Path $install 'child'),(Split-Path $install -Parent),(Join-Path $TestDrive 'CON'),(Join-Path $TestDrive 'trailing.'))) {
                Get-DemoBackupPathError $path $install $id | Should -Not -BeNullOrEmpty
            }
            Should -Invoke New-DemoPrivateDirectory -Times 0
        }
        It 'rejects an unrelated broad existing folder without altering its ACL' {
            $folder=Join-Path $TestDrive "broad-$id"
            [void][IO.Directory]::CreateDirectory($folder)
            $before=(Get-Acl -LiteralPath $folder).Sddl
            Get-DemoBackupPathError $folder $install $id | Should -Match 'current-user-only'
            (Get-Acl -LiteralPath $folder).Sddl | Should -Be $before
        }
        It 'rejects Git directories including ignored backup paths' {
            $repo=Join-Path $TestDrive "repo-$id"
            [void][IO.Directory]::CreateDirectory((Join-Path $repo '.git'))
            Get-DemoBackupPathError (Join-Path $repo '.private\backup') $install $id | Should -Match 'Git checkout'
        }
        It 'rejects file and reparse-point destinations' {
            $file=Join-Path $TestDrive "$id.marker"
            [IO.File]::WriteAllText($file,'synthetic')
            Get-DemoBackupPathError $file $install $id | Should -Match 'directory'
            $link=Join-Path $TestDrive "link-$id"
            New-Item -ItemType Junction -Path $link -Target $install | Out-Null
            Get-DemoBackupPathError (Join-Path $link 'backup') $install $id | Should -Match 'reparse'
        }
    }
}

Describe 'Custody transaction recovery (local encrypted synthetic keys)' -Skip:(-not $IsWindows) {
    InModuleScope Demo.Custody {
        BeforeAll {
            $script:recoveryId=[guid]::NewGuid().ToString('N')
            $script:recoveryPassword=[securestring]::new()
            foreach ($byte in [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) { $script:recoveryPassword.AppendChar([char](33+($byte % 90))) }
        }
        AfterAll { $script:recoveryPassword.Dispose() }
        It 'preserves an encrypted package across IO failure and resumes the same keys without regeneration' {
            $install=Join-Path $TestDrive 'interrupted-custody'
            $backup=Join-Path $TestDrive 'interrupted-backup'
            New-DemoPrivateDirectory $install
            $resumeBody=(Get-Command Resume-DemoCustody).ScriptBlock
            Mock Resume-DemoCustody { throw [IO.IOException]::new('Synthetic failure after encrypted package flush') }
            { New-DemoCustody $install $backup $script:recoveryPassword $script:recoveryId } | Should -Throw '*Synthetic failure*'
            $pending=Join-Path $install 'custody.pfx.pending'
            Test-Path $pending | Should -BeTrue
            @(Get-ChildItem $install -Filter '*.cer').Count | Should -Be 0
            $before=(Get-FileHash $pending).Hash
            Test-DemoCustodyPassword $install $script:recoveryPassword -Pending | Should -BeTrue
            $wrong=[securestring]::new()
            foreach ($byte in [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) { $wrong.AppendChar([char](33+($byte % 90))) }
            try { Test-DemoCustodyPassword $install $wrong -Pending | Should -BeFalse } finally { $wrong.Dispose() }
            $uncommitted=Join-Path $install 'custody.json.pending-synthetic-interrupted-metadata'
            [IO.File]::WriteAllText($uncommitted,'synthetic incomplete receipt, not committed')
            $metadataHash=(Get-FileHash $uncommitted).Hash
            & $resumeBody $install $backup $script:recoveryPassword $script:recoveryId
            (Get-FileHash (Join-Path $install 'custody.pfx')).Hash | Should -Be $before
            @(Get-ChildItem $install -Filter '*.cer').Count | Should -Be 5
            Test-DemoCustodyBackup $install $script:recoveryPassword
            (Get-FileHash $uncommitted).Hash | Should -Be $metadataHash
            { New-DemoCustody $install $backup $script:recoveryPassword $script:recoveryId } | Should -Throw '*already exists*'
        }
        It 'rejects an invalid root and short passphrase before creating custody artifacts or changing ACLs' {
            $install=Join-Path $TestDrive 'input-rejected-custody'
            New-DemoPrivateDirectory $install
            $short=[securestring]::new(); $short.AppendChar('x')
            Mock New-DemoPrivateDirectory { throw 'Must not create backup directory' }
            Mock Set-Acl { throw 'Must not change any ACL' }
            try {
                { New-DemoCustody $install ([IO.Path]::GetPathRoot($install)) $short $script:recoveryId } | Should -Throw '*root*'
                { New-DemoCustody $install (Join-Path $TestDrive 'unused-backup') $short $script:recoveryId } | Should -Throw '*16 characters*'
                @(Get-ChildItem $install -Force).Count | Should -Be 0
                Should -Invoke New-DemoPrivateDirectory -Times 0
                Should -Invoke Set-Acl -Times 0
            } finally { $short.Dispose() }
        }
    }
}

Describe 'Cancellation and recognized local-tooling update preserve state (offline)' -Skip:(-not $IsWindows) {
    InModuleScope Demo.Setup {
        BeforeAll { . (Join-Path $script:Kit 'tests\TestData.ps1') }
        BeforeEach {
            $config=New-TestConfiguration
            $install=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-DemoPrivateDirectory $install
            $path=Join-Path $install 'install.json'
            $journal=@{schemaVersion=1;installationId=[guid]::NewGuid().ToString('N');config=$config
                configFingerprint=(Get-DemoConfigFingerprint $config);sourceFingerprint='synthetic-current'
                receipts=@{};resources=@{};pendingAgent=$null;status='Preparing'}
            Save-DemoJournal $journal $path
            Mock Get-DemoSourceFingerprint {
                if ($CliTransportBase) { return '6B3A956238A3D4361B5283133DBBE1A664D3B1AA7B5B413E8CA0997B2E5D3F92' }
                if ($PolicyIsolationBase) { return 'B1931C627719F5ABFBE310DF448C5B6B93C003E73621141F5B9E2EB65DF20923' }
                if ($ProvisioningOnly) { return '5A4FC5C4AF99D602ECF4BAB342B6BF3C5E4A2FB6E0953BBA49975622B903A2F0' }
                'synthetic-current'
            }
            Mock Test-DemoPolicyIsolationRecovery { @{verifiedUtc='synthetic';deploymentName='synthetic';legacyLocation='westus2';ownedGroupExists=$false} }
            Mock Assert-DemoAzureContext {}
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Write-Error {}
            Mock Assert-DemoSecureInputAvailable {}
            Mock az { throw 'OFFLINE: unexpected Azure CLI' }
            Mock Invoke-AzJson { throw 'OFFLINE: unexpected Azure operation' }
        }
        It 'releases its installation lock on cancellation and keeps the journal/custody unchanged' {
            $before=(Get-FileHash $path).Hash
            Mock Read-Host { 'q' }
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*cancelled*'
            (Get-FileHash $path).Hash | Should -Be $before
            $lock=[IO.File]::Open((Join-Path $install '.setup.lock'),'Open','ReadWrite','None')
            $lock.Dispose()
            Should -Invoke Invoke-AzJson -Times 0
            Should -Invoke az -Times 0
        }
        It 'never deploys when retained custody authentication is cancelled' {
            Mock Resolve-DemoCustodyBackupLocation { @{SourcePath='synthetic';Recover=$false} }
            $journal.receipts=@{Custody=@{}}
            Save-DemoJournal $journal $path
            Mock Assert-DemoInstallOwner { $false }
            Mock Read-Host { $cancel=[securestring]::new(); $cancel.AppendChar('q'); $cancel }
            { Invoke-DemoSetup -Mode Setup -InstallPath $install } | Should -Throw '*cancelled*'
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'automatically migrates the recognized <Revision> tooling without prompts and preserves receipts' -ForEach @(
            @{Revision='case-sensitive revision';Fingerprint='EA5289ADEFAF98ADC808972182337EC3764507D226F4A35BDAD381267AE008A4'},
            @{Revision='all-prompts revision';Fingerprint='3C97B68209B2913A11E71EB37D5889446ED7A9CC2108151B043E1F3C1829B852'},
            @{Revision='value-only revision';Fingerprint='542448B679ED37A2F1A86FDD237FA2841516621A38D83A25654CE9631D9955CF'}
        ) {
            $journal.sourceFingerprint=$Fingerprint
            $journal.receipts=@{Cost=@{reference='Synthetic quote'}}
            Mock Read-Host { throw 'No input needed for verified compatibility' }
            Update-DemoLocalPromptSource $journal $path
            $updated=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
            $updated.sourceFingerprint | Should -Be 'synthetic-current'
            $updated.receipts.Cost.reference | Should -Be 'Synthetic quote'
            $updated.config.subscriptionId | Should -Be $config.subscriptionId
            Should -Invoke Read-Host -Times 0
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'migrates only the exact preceding local-custody revision with unchanged runtime and known stages' {
            $journal.sourceFingerprint='1A0FEBF1A04E310EA6C3862F99D9511D6B8C9DCD4A2E6A3885C3FAF05292D233'
            $journal.receipts=@{Custody=@{preserved=$true};PolicyIsolation=@{verified=$true}}
            $before=$journal.configFingerprint
            Update-DemoLocalPromptSource $journal $path
            $updated=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
            $updated.sourceFingerprint | Should -Be 'synthetic-current'
            $updated.configFingerprint | Should -Be $before
            $updated.receipts.Custody.preserved | Should -BeTrue
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'refuses a custody update with changed runtime, unknown stage or pending operation' {
            $journal.sourceFingerprint='1A0FEBF1A04E310EA6C3862F99D9511D6B8C9DCD4A2E6A3885C3FAF05292D233'
            $journal.pendingAgent=@{operationId='unknown'}
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*unknown/pending*'
            $journal.pendingAgent=$null
            $journal.receipts.UnknownStage=@{}
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*unknown/pending*'
            $journal.receipts.Remove('UnknownStage')
            Mock Get-DemoSourceFingerprint { 'unreviewed-runtime' }
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Source changed*'
            $journal.sourceFingerprint | Should -Be '1A0FEBF1A04E310EA6C3862F99D9511D6B8C9DCD4A2E6A3885C3FAF05292D233'
        }
        It 'reconciles an exact known pending transport operation read-only before migrating and leaves intent for its original stage' {
            $journal.sourceFingerprint='2178046C1AD381BE26E2471DF735C59D4F54A892AD583C68BB8356E3AF57774E'
            $journal.pendingAgent=@{operationId=[guid]::NewGuid().ToString('D');digest=('A'*64);startedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            $operation=$journal.pendingAgent.operationId
            Mock Assert-DemoInstallOwner { $true }
            Mock Wait-DemoManagedCommand { @{ok=$true} }
            Update-DemoLocalPromptSource $journal $path
            $journal.sourceFingerprint | Should -Be 'synthetic-current'
            $journal.pendingAgent.operationId | Should -Be $operation
            Should -Invoke Wait-DemoManagedCommand -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'accepts the exact <Revision> revision for reset diagnostics without clearing pending intent' -ForEach @(
            @{Revision='native transport';Fingerprint='D4F9A14CC558797D6F4A2DC8D438C6FA8973C523B95D1185A88BF4C73E08CF76'},
            @{Revision='actionable diagnostics';Fingerprint='AABFC62FDB574831ABF95A47F3083209C68F73E1CF9738680D0079211A6D758A'}
        ) {
            $journal.sourceFingerprint=$Fingerprint
            $journal.pendingAgent=@{operationId=[guid]::NewGuid().ToString('D');digest=('A'*64);startedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            $operation=$journal.pendingAgent.operationId
            Mock Assert-DemoInstallOwner { $true }
            Mock Wait-DemoManagedCommand { @{ok=$true} }
            Update-DemoLocalPromptSource $journal $path
            $journal.sourceFingerprint | Should -Be 'synthetic-current'
            $journal.pendingAgent.operationId | Should -Be $operation
            Should -Invoke Wait-DemoManagedCommand -Times 1 -Exactly
        }
        It 'does not stamp a transport update or clear intent when exact pending reconciliation fails' {
            $journal.sourceFingerprint='2178046C1AD381BE26E2471DF735C59D4F54A892AD583C68BB8356E3AF57774E'
            $journal.pendingAgent=@{operationId=[guid]::NewGuid().ToString('D');digest=('A'*64);startedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            $operation=$journal.pendingAgent.operationId
            Mock Assert-DemoInstallOwner { $true }
            Mock Wait-DemoManagedCommand { throw 'Synthetic payload mismatch/pending' }
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Synthetic payload mismatch*'
            $journal.sourceFingerprint | Should -Be '2178046C1AD381BE26E2471DF735C59D4F54A892AD583C68BB8356E3AF57774E'
            $journal.pendingAgent.operationId | Should -Be $operation
        }
        It 'rejects unknown revisions, stages and pending operations without requesting an approval' {
            Mock Read-Host { throw 'No approval can migrate this state' }
            $journal.sourceFingerprint='unknown'
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Source changed*'
            $journal.sourceFingerprint='EA5289ADEFAF98ADC808972182337EC3764507D226F4A35BDAD381267AE008A4'
            $journal.pendingAgent=@{operationId='unknown'}
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Source changed*'
            $journal.pendingAgent=$null
            $journal.receipts.UnknownStage=@{}
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Source changed*'
            Should -Invoke Read-Host -Times 0
        }
        It 'leaves incompatible source state untouched rather than requesting approval' {
            $journal.sourceFingerprint='unknown'
            Save-DemoJournal $journal $path
            $before=(Get-FileHash $path).Hash
            Mock Read-Host { throw 'No approval can override compatibility' }
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Source changed*'
            (Get-FileHash $path).Hash | Should -Be $before
            Should -Invoke Read-Host -Times 0
        }
        It 'preserves but refuses automatic upgrade of already provisioned resource/key receipts' {
            $journal.sourceFingerprint='3C97B68209B2913A11E71EB37D5889446ED7A9CC2108151B043E1F3C1829B852'
            $journal.resources=@{vmId='synthetic-owned-vm'}
            $journal.receipts=@{Foundation=@{deployment='synthetic'};Keys=@{pinned='synthetic-key-version'}}
            Mock Read-Host { throw 'No migration approval needed' }
            Save-DemoJournal $journal $path
            $before=(Get-FileHash $path).Hash
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Source changed*'
            (Get-FileHash $path).Hash | Should -Be $before
            Should -Invoke Read-Host -Times 0
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'refuses a local-only migration when any provisioning/runtime source has changed' {
            $journal.sourceFingerprint='EA5289ADEFAF98ADC808972182337EC3764507D226F4A35BDAD381267AE008A4'
            Mock Get-DemoSourceFingerprint { 'unreviewed-change' } -ParameterFilter { $PolicyIsolationBase }
            Mock Read-Host { throw 'No local-only approval can authorize changed infrastructure/guest source' }
            { Update-DemoLocalPromptSource $journal $path } | Should -Throw '*Source changed*'
            Should -Invoke Read-Host -Times 0
        }
    }
}
