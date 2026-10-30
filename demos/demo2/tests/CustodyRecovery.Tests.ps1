BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
}

Describe 'Missing external custody backup recovery (synthetic only)' -Skip:(-not $IsWindows) {
    InModuleScope Demo.Setup {
        BeforeAll {
            $script:fixtureId=[guid]::NewGuid().ToString('N')
            $script:fixturePassword=[securestring]::new()
            foreach ($value in [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) { $script:fixturePassword.AppendChar([char](33+($value % 90))) }
            $script:template=Join-Path $TestDrive 'custody-template'
            New-DemoPrivateDirectory $script:template
            New-DemoCustody $script:template (Join-Path $TestDrive 'template-backup') $script:fixturePassword $script:fixtureId
            $script:otherTemplate=Join-Path $TestDrive 'other-template'
            New-DemoPrivateDirectory $script:otherTemplate
            New-DemoCustody $script:otherTemplate (Join-Path $TestDrive 'other-backup') $script:fixturePassword ([guid]::NewGuid().ToString('N'))
        }
        AfterAll { $script:fixturePassword.Dispose() }
        BeforeEach {
            $install=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-DemoPrivateDirectory $install
            Copy-Item (Join-Path $script:template 'custody.pfx') $install
            Copy-Item (Join-Path $script:template 'custody.json') $install
            $receiptPath=Join-Path $install 'custody.json'
            $receipt=Get-Content $receiptPath -Raw | ConvertFrom-Json -AsHashtable
            $backup=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $receipt.backupFile=Join-Path $backup "$($script:fixtureId)-custody.pfx"
            [IO.File]::WriteAllText($receiptPath,($receipt | ConvertTo-Json -Depth 10))
            $script:answers=[Collections.Generic.Queue[object]]::new()
            Mock Read-Host { $value=$script:answers.Dequeue(); if ($value -is [scriptblock]) { & $value } else { $value } }
            Mock Assert-DemoSecureInputAvailable {}
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock New-DemoCustody { throw 'Never generate replacement custody' }
            Mock Invoke-AzJson { throw 'OFFLINE: no Azure calls' }
            Mock az { throw 'OFFLINE: no Azure CLI' }
            Mock Get-DemoCustodyPathItem -ModuleName Demo.Custody {
                try { Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
                catch [Management.Automation.ItemNotFoundException] { return $null }
                catch [Management.Automation.DriveNotFoundException] { return $null }
            }
        }
        It 'reports the missing stored backup path before any secret prompt and cancels without changing custody' {
            $before=(Get-FileHash $receiptPath).Hash
            $script:answers.Enqueue('q')
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*cancelled*'
            Should -Invoke Read-Host -Times 0 -ParameterFilter { $AsSecureString }
            Should -Invoke Write-Host -Times 1 -ParameterFilter { "$Object" -like "*$($receipt.backupFile)*" }
            (Get-FileHash $receiptPath).Hash | Should -Be $before
            Should -Invoke New-DemoCustody -Times 0
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'reports an unavailable synthetic E drive without probing real removable media' {
            $receipt.backupFile="E:\Demo2-Synthetic\$($script:fixtureId)-custody.pfx"
            [IO.File]::WriteAllText($receiptPath,($receipt | ConvertTo-Json -Depth 10))
            Mock Get-DemoCustodyPathItem -ModuleName Demo.Custody { $null } -ParameterFilter { $Path -eq 'E:\' -or $Path -like 'E:\Demo2-Synthetic\*' }
            $script:answers.Enqueue('q')
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*cancelled*'
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { "$Message" -like '*disconnected*' }
            Should -Invoke Read-Host -Times 0 -ParameterFilter { $AsSecureString }
        }
        It 'rechecks the same stored path after reconnect and authenticates without changing its receipt' {
            $before=(Get-FileHash $receiptPath).Hash
            $script:answers.Enqueue({
                New-DemoPrivateDirectory $backup
                [IO.File]::Copy((Join-Path $install 'custody.pfx'),$receipt.backupFile,$false)
                '1'
            })
            $script:answers.Enqueue($script:fixturePassword.Copy())
            $password=Read-DemoCustodyPassphrase $install
            try { Test-DemoCustodyBackup $install $password } finally { $password.Dispose() }
            (Get-FileHash $receiptPath).Hash | Should -Be $before
            Should -Invoke Read-Host -Times 1 -ParameterFilter { $AsSecureString }
        }
        It 'authenticates a relocated renamed package before updating only the backup receipt' {
            New-DemoPrivateDirectory $backup
            $relocated=Join-Path $backup 'relocated-original.pfx'
            [IO.File]::Copy((Join-Path $install 'custody.pfx'),$relocated,$false)
            $before=(Get-FileHash (Join-Path $install 'custody.pfx')).Hash
            foreach ($value in @('2',$relocated,$script:fixturePassword.Copy())) { $script:answers.Enqueue($value) }
            $password=Read-DemoCustodyPassphrase $install
            try { Test-DemoCustodyBackup $install $password } finally { $password.Dispose() }
            (Get-Content $receiptPath -Raw | ConvertFrom-Json).backupFile | Should -Be $relocated
            (Get-FileHash (Join-Path $install 'custody.pfx')).Hash | Should -Be $before
            Should -Invoke New-DemoCustody -Times 0
        }
        It 'creates a separate backup from the exact authenticated local bytes without new keys or approvals' {
            $before=(Get-FileHash (Join-Path $install 'custody.pfx')).Hash
            foreach ($value in @('3',$backup,$script:fixturePassword.Copy())) { $script:answers.Enqueue($value) }
            $password=Read-DemoCustodyPassphrase $install
            try { Test-DemoCustodyBackup $install $password } finally { $password.Dispose() }
            (Get-FileHash $receipt.backupFile).Hash | Should -Be $before
            (Get-FileHash (Join-Path $install 'custody.pfx')).Hash | Should -Be $before
            Should -Invoke New-DemoCustody -Times 0
            Should -Invoke Write-Host -Times 1 -ParameterFilter { "$Object" -like '*does not prove physical/offline custody*' }
        }
        It 'restores a missing local encrypted copy only from its verified external original' {
            New-DemoPrivateDirectory $backup
            [IO.File]::Copy((Join-Path $install 'custody.pfx'),$receipt.backupFile,$false)
            $before=(Get-FileHash $receiptPath).Hash
            Remove-Item -LiteralPath (Join-Path $install 'custody.pfx')
            $script:answers.Enqueue($script:fixturePassword.Copy())
            $password=Read-DemoCustodyPassphrase $install
            try { Test-DemoCustodyBackup $install $password } finally { $password.Dispose() }
            (Get-FileHash $receiptPath).Hash | Should -Be $before
            ((Get-FileHash (Join-Path $install 'custody.pfx')).Hash -ceq (Get-FileHash $receipt.backupFile).Hash) | Should -BeTrue
        }
        It 'blocks missing sole custody without secret prompts or regeneration' {
            Remove-Item -LiteralPath (Join-Path $install 'custody.pfx')
            $script:answers.Enqueue('q')
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*cancelled*'
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { "$Message" -like '*No accessible custody package remains*cannot be regenerated*' }
            Should -Invoke Read-Host -Times 0 -ParameterFilter { $AsSecureString }
            Should -Invoke New-DemoCustody -Times 0
        }
        It 'surfaces corrupt retained packages without creating a folder, updating receipts or retrying passwords' {
            [IO.File]::WriteAllText((Join-Path $install 'custody.pfx'),'synthetic corrupt archive')
            $before=(Get-FileHash $receiptPath).Hash
            foreach ($value in @('3',$backup,$script:fixturePassword.Copy())) { $script:answers.Enqueue($value) }
            { Read-DemoCustodyPassphrase $install } | Should -Throw
            Test-Path $backup | Should -BeFalse
            (Get-FileHash $receiptPath).Hash | Should -Be $before
            Should -Invoke Read-Host -Times 1 -ParameterFilter { $AsSecureString }
        }
        It 'rejects a conflicting relocated archive before secrets and never overwrites it' {
            New-DemoPrivateDirectory $backup
            $wrong=Join-Path $backup 'wrong.pfx'
            [IO.File]::WriteAllText($wrong,'synthetic unrelated archive')
            $before=(Get-FileHash $wrong).Hash
            foreach ($value in @('2',$wrong,'q')) { $script:answers.Enqueue($value) }
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*cancelled*'
            (Get-FileHash $wrong).Hash | Should -Be $before
            Should -Invoke Read-Host -Times 0 -ParameterFilter { $AsSecureString }
        }
        It 'rejects an authenticated archive with different keys even when no local copy remains' {
            Remove-Item -LiteralPath (Join-Path $install 'custody.pfx')
            New-DemoPrivateDirectory $backup
            $other=Join-Path $backup 'other-keys.pfx'
            [IO.File]::Copy((Join-Path $script:otherTemplate 'custody.pfx'),$other,$false)
            $before=(Get-FileHash $receiptPath).Hash
            foreach ($value in @('2',$other,$script:fixturePassword.Copy())) { $script:answers.Enqueue($value) }
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*exact five expected certificates*'
            (Get-FileHash $receiptPath).Hash | Should -Be $before
            Test-Path (Join-Path $install 'custody.pfx') | Should -BeFalse
        }
        It 'surfaces <Kind> failures distinctly without retrying or asking for secrets' -ForEach @(
            @{Kind='access';Failure=[UnauthorizedAccessException]::new('Synthetic access denied')},
            @{Kind='IO';Failure=[IO.IOException]::new('Synthetic device IO failure')}
        ) {
            Mock Get-DemoCustodyPathItem -ModuleName Demo.Custody { throw $Failure } -ParameterFilter { $Path -like '*-custody.pfx' }
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*Synthetic*'
            Should -Invoke Read-Host -Times 0
        }
        It 'handles repeated reconnect then EOF without a busy loop or receipt change' {
            $before=(Get-FileHash $receiptPath).Hash
            $script:answers.Enqueue('1'); $script:answers.Enqueue($null)
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*EOF*'
            Should -Invoke Read-Host -Times 2 -Exactly
            (Get-FileHash $receiptPath).Hash | Should -Be $before
        }
        It 'validates copy destinations before secret input and leaves no copy on secure cancellation' {
            $before=(Get-FileHash $receiptPath).Hash
            foreach ($value in @('3',([IO.Path]::GetPathRoot($install)),$backup,[securestring]::new())) { $script:answers.Enqueue($value) }
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*Secure input cancelled*'
            Test-Path $backup | Should -BeFalse
            (Get-FileHash $receiptPath).Hash | Should -Be $before
            Should -Invoke Read-Host -Times 1 -ParameterFilter { $AsSecureString }
        }
        It 'gives low-level callers an explicit missing backup error rather than raw Get-Item failure' {
            { Test-DemoCustodyBackup $install $script:fixturePassword } | Should -Throw '*backup is unavailable*guided Setup recovery*'
        }
        It 'preserves the original receipt and exact copies if receipt persistence fails after backup verification' {
            $recoveryDirectory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $before=(Get-FileHash $receiptPath).Hash
            Mock Write-DemoCustodyMetadata -ModuleName Demo.Custody { throw [IO.IOException]::new('Synthetic receipt write failure') }
            foreach ($value in @('3',$recoveryDirectory,$script:fixturePassword.Copy())) { $script:answers.Enqueue($value) }
            { Read-DemoCustodyPassphrase $install } | Should -Throw '*Synthetic receipt write failure*'
            (Get-FileHash $receiptPath).Hash | Should -Be $before
            $copy=Join-Path $recoveryDirectory "$($script:fixtureId)-custody.pfx"
            ((Get-FileHash $copy).Hash -ceq (Get-FileHash (Join-Path $install 'custody.pfx')).Hash) | Should -BeTrue
            Test-DemoCustodyBackup $install $script:fixturePassword -ArchivePath $copy
            Should -Invoke New-DemoCustody -Times 0
        }
    }
}
