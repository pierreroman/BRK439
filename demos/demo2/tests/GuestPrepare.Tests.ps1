BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Demo.Setup.psm1') -Force
}
BeforeAll {
    $kit=Split-Path $PSScriptRoot -Parent
}

Describe 'GuestPrepare safe error metadata and exact failed-operation recovery (offline)' {
    InModuleScope Demo.Setup {
        BeforeEach {
            $journal=@{installationId=('a'*32);status='Preparing';sourceFingerprint='6822E148B4A597D7C6C950E608D8C19478705C0E8D64062A8DF223E3CFDD0427'
                config=@{location='test';subscriptionId='synthetic';nameSuffix='synthetic'}
                resources=@{vmId='/synthetic/vm';custodyDiskId='/synthetic/disk'}
                receipts=@{Custody=@{};Foundation=@{};PublicPayload=@{}}
                publicUploads=@{};pendingAgent=$null}
            $operation=[guid]::NewGuid().ToString()
            $source=Get-DemoGuestPrepareScript $journal -Legacy
            $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)))
            $journal.pendingAgent=@{operationId=$operation;digest=$digest;startedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            $record=@{id='/synthetic/vm/runCommands/demo2-field-setup';location='test';tags=@{installationId=$journal.installationId;operationId=$operation}
                properties=@{source=@{script=$source.Replace('__OPERATION_ID__',$operation)};provisioningState='Succeeded'
                    instanceView=@{executionState='Failed';exitCode=1;output='DO_NOT_LOG_CONTENT'
                        error="E: Conflicting values set for option Signed-By regarding source https://DO_NOT_LOG_SOURCE jammy: secret`nE: The list of sources could not be read."}}}
            $path=Join-Path $TestDrive 'journal.json'
            Mock Save-DemoJournal {}
            Mock Write-Host {}
            Mock Assert-DemoAzureContext {}
            Mock Assert-DemoInstallOwner { $true }
            Mock Get-DemoArmRecord { $record }
            Mock Invoke-AzJson { throw 'OFFLINE GUARD: unexpected Azure command' }
        }
        It 'classifies the actual Signed-By failure without returning source, output, or arbitrary server text' {
            $facts=Get-DemoGuestFailureSummary $record
            $facts.category | Should -Be 'AptSourceConflict'
            $facts.executionState | Should -Be 'Failed'
            $facts.exitCode | Should -Be 1
            ($facts | ConvertTo-Json) | Should -Not -Match 'DO_NOT_LOG|secret'
            try { Read-DemoManagedResult $record $operation; throw 'Expected failure' }
            catch {
                $_.Exception.Message | Should -Match 'AptSourceConflict'
                $_.Exception.Message | Should -Not -Match 'DO_NOT_LOG|secret'
            }
        }
        It 'accepts only fixed phase markers and numeric lines, never echoed command text' {
            $record.properties.instanceView.error="DEMO2_PREPARE_ERROR phase=Packages line=123 exit=100`nDO_NOT_LOG_CONTENT"
            $facts=Get-DemoGuestFailureSummary $record
            $facts.phase | Should -Be 'Packages'
            $facts.line | Should -Be 123
            $facts.exitCode | Should -Be 1
            $record.properties.instanceView.error='DEMO2_PREPARE_ERROR phase=DO_NOT_LOG_CONTENT line=123 exit=100'
            (Get-DemoGuestFailureSummary $record).phase | Should -Be 'Unknown'
        }
        It 'preserves a real child shell exit status and emits no success receipt after failure' -Skip:(-not $IsWindows) {
            $wrapper=Get-DemoGuestPrepareScript $journal
            $lines=$wrapper -split "`n"
            $lines[0]="bash -c 'exit 37'"
            $output=@(& 'C:\Program Files\Git\bin\bash.exe' -c ($lines -join "`n") 2>&1)
            $LASTEXITCODE | Should -Be 37
            ($output -join "`n") | Should -Not -Match '"ok":true'
        }
        It 'archives the exact known terminal failure without submitting a new operation or authorizing disk formatting' {
            Initialize-DemoGuestPrepareRecovery $journal $path 'synthetic-current'
            $journal.guestPrepareRecovery.failedIntent.operationId | Should -Be $operation
            $journal.guestPrepareRecovery.failedIntent.digest | Should -Be $digest
            $journal.pendingAgent | Should -BeNullOrEmpty
            $journal.sourceFingerprint | Should -Be 'synthetic-current'
            (Get-DemoGuestPrepareScript $journal) | Should -Match '^DEMO2_REQUIRE_EXISTING_DISK=1 /bin/bash '
            Should -Invoke Save-DemoJournal -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'does not let Run authorize a repair or changed unrelated source bypass the migration boundary' {
            { Update-DemoLocalPromptSource $journal $path 'Run' } | Should -Throw '*Run/Rehearse*'
            Should -Invoke Get-DemoArmRecord -Times 0
            Mock Get-DemoSourceFingerprint { 'unreviewed-source' }
            { Initialize-DemoGuestPrepareRecovery $journal $path 'synthetic-current' } | Should -Throw '*restricted*'
            $journal.pendingAgent.operationId | Should -Be $operation
            Should -Invoke Save-DemoJournal -Times 0
        }
        It 'leaves intent untouched for <Kind>' -ForEach @(
            @{Kind='running guest';Change='Running'},
            @{Kind='different failure';Change='DifferentFailure'},
            @{Kind='changed pending payload';Change='ChangedPayload'},
            @{Kind='later activation receipts';Change='Activated'},
            @{Kind='another operation';Change='WrongOperation'}
        ) {
            switch ($Change) {
                Running { $record.properties.instanceView.executionState='Running' }
                DifferentFailure { $record.properties.instanceView.error='Different error' }
                ChangedPayload { $journal.pendingAgent.digest='F'*64 }
                Activated { $journal.receipts.DomainActivated=@{} }
                WrongOperation { $record.tags.operationId=[guid]::NewGuid().ToString() }
            }
            { Initialize-DemoGuestPrepareRecovery $journal $path 'synthetic-current' } | Should -Throw
            $journal.pendingAgent.operationId | Should -Be $operation
            $journal.sourceFingerprint | Should -Be '6822E148B4A597D7C6C950E608D8C19478705C0E8D64062A8DF223E3CFDD0427'
            Should -Invoke Save-DemoJournal -Times 0
            Should -Invoke Invoke-AzJson -Times 0
        }
        It 'permits only the pinned public patch as replacement for the archived failed command' {
            Initialize-DemoGuestPrepareRecovery $journal $path 'synthetic-current'
            Mock Invoke-AzJson { $record }
            { Invoke-DemoAgentScript $journal $path 'unrelated upload or guest action' } | Should -Throw '*exact reviewed public host-patch*'
            $journal.pendingAgent | Should -BeNullOrEmpty
            Should -Invoke Invoke-AzJson -Times 0 -ParameterFilter { $Arguments -contains 'put' }
        }
        It 'submits exactly the pinned patch and preserves the archived failure on an unknown new submission outcome' {
            Initialize-DemoGuestPrepareRecovery $journal $path 'synthetic-current'
            $remote="/var/lib/demo2-setup/$($journal.installationId)/kit/host/Prepare-FieldHost.sh"
            $bytes=[Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $script:Kit 'host\Prepare-FieldHost.sh')).Replace("`r`n","`n"))
            $patch=Get-DemoPublicUploadScript $remote $bytes
            Mock Invoke-AzJson { throw 'Synthetic accepted submission with lost response' }
            { Invoke-DemoAgentScript $journal $path $patch } | Should -Throw '*lost response*'
            $journal.pendingAgent.digest | Should -Be $journal.guestPrepareRecovery.patchDigest
            $journal.pendingAgent.operationId | Should -Not -Be $operation
            $journal.guestPrepareRecovery.failedIntent.operationId | Should -Be $operation
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'put' }
            $patchOperation=$journal.pendingAgent.operationId
            Mock Wait-DemoManagedCommand { @{ok=$true} }
            Invoke-DemoAgentScript $journal $path $patch | Out-Null
            $journal.pendingAgent | Should -BeNullOrEmpty
            $journal.agentTimings[-1].operationId | Should -Be $patchOperation
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'put' }
        }
    }
}

Describe 'Actual Bash host control flow with synthetic Linux commands (no Azure or real disks)' -Skip:(-not $IsWindows) {
    BeforeAll {
        $bash='C:\Program Files\Git\bin\bash.exe'
        if (-not (Test-Path $bash)) { throw 'Git Bash is required for offline shell boundary tests.' }
        $hostSource=[IO.File]::ReadAllText((Join-Path $kit 'host\Prepare-FieldHost.sh')).Replace("`r`n","`n")
        function New-HostFixture {
            param([string]$Name,[switch]$Fresh)
            $root=Join-Path $TestDrive $Name
            $null=New-Item $root -ItemType Directory
            $unix=(& $bash -c 'cygpath -u "$1"' 'fixture' $root).Trim()
            foreach ($relative in 'bin','etc/apt/sources.list.d','usr/share/keyrings','dev/disk/azure/scsi1','mnt/dispo-keys',('var/lib/demo2-setup/'+('a'*32))) {
                $null=New-Item (Join-Path $root $relative) -ItemType Directory -Force
            }
            [IO.File]::WriteAllText((Join-Path $root 'etc/os-release'),"ID=ubuntu`nVERSION_ID=22.04`n")
            foreach ($relative in 'etc/fstab','usr/share/keyrings/ubuntu-archive-keyring.gpg','dev/disk/azure/scsi1/lun0') {
                [IO.File]::WriteAllText((Join-Path $root $relative),'')
            }
            $original='deb https://packages.microsoft.com/ubuntu/22.04/prod jammy main'
            [IO.File]::WriteAllText((Join-Path $root 'etc/apt/sources.list.d/microsoft-prod.list'),"$original`n")
            foreach ($product in 'powershell','azure-cli') {
                $repository=if($product -eq 'powershell') {'https://packages.microsoft.com/ubuntu/22.04/prod'}else{'https://packages.microsoft.com/repos/azure-cli/'}
                $line="deb [arch=amd64 signed-by=$unix/etc/apt/keyrings/demo2-microsoft.gpg] $repository jammy main`n"
                [IO.File]::WriteAllText((Join-Path $root "etc/apt/sources.list.d/demo2-$product.list"),$line)
            }
            if (-not $Fresh) {
                [IO.File]::WriteAllText((Join-Path $root ('var/lib/demo2-setup/'+('a'*32)+'/disk.json')),'{"uuid":"fixture-uuid"}')
                [IO.File]::WriteAllText((Join-Path $root 'formatted'),'')
                [IO.File]::WriteAllText((Join-Path $root 'mounted'),'')
            }
            $fake=@'
#!/bin/bash
set -eu
root="$FIXTURE_ROOT"
name="${0##*/}"
case "$name" in
 id) printf '0\n';;
 install)
   if [[ "$*" == *'/mnt/dispo-keys'* ]]; then touch "$root/volume-permissions"; fi
   while [[ "$1" == -* ]]; do
     if test "$1" = -m; then shift 2; else shift; fi
   done
   mkdir -p -- "$@";;
 chmod) if [[ "$*" == *'/mnt/dispo-keys'* ]]; then touch "$root/volume-permissions"; fi;;
 dpkg) printf 'amd64\n';;
 python3)
   if test "$1" = -c; then printf 'fixture-uuid\n'
   elif [[ "$2" == */disk.json ]]; then printf '{"uuid":"fixture-uuid"}' > "$2"
   else cat >/dev/null; fi;;
 blockdev) if test -f "$root/wrong-size"; then printf '1\n'; else printf '34359738368\n'; fi;;
 blkid)
   if test "$2" = TYPE; then printf 'ext4\n'
   elif test -f "$root/wrong-uuid"; then printf 'wrong-uuid\n'
   else printf 'fixture-uuid\n'; fi;;
 lsblk) if test "$3" = NAME; then printf 'fixture-device\n'; fi;;
 wipefs) if test -f "$root/formatted"; then printf 'existing-signature\n'; fi;;
 mkfs.ext4) printf 'format\n' >> "$root/mutations"; touch "$root/formatted";;
 mountpoint) test -f "$root/mounted";;
 findmnt) if test -f "$root/wrong-mount"; then printf 'different\n'; else printf 'fixture-uuid\n'; fi;;
 mount) printf 'mount\n' >> "$root/mutations"; touch "$root/mounted";;
 apt-get)
   [[ "$*" == *Dir::Etc::sourceparts=-* ]] || exit 91
   printf '%s\n' "$*" >> "$root/apt-calls"
   if test -f "$root/apt-fail"; then rm "$root/apt-fail"; exit 100; fi
   if [[ "$*" == *'powershell azure-cli'* ]]; then touch "$root/installed"; fi;;
 curl) while test "$1" != -o; do shift; done; printf 'synthetic-key' > "$2";;
 gpg)
   if test "$1" = --show-keys; then
     if test -f "$root/wrong-key"; then printf 'fpr:::::::::untrusted:\n'
     else printf 'fpr:::::::::BC528686B50D79E339D3721CEB3E94ADBE1229CF:\n'; fi
   else while test "$1" != --output; do shift; done; printf 'synthetic-keyring' > "$2"; fi;;
 pwsh) if test -f "$root/pwsh-fail"; then exit 71; fi;;
 az) exit 0;;
 timedatectl) if test -f "$root/bad-time"; then printf 'no\n'; else printf 'yes\n'; fi;;
 *) exit 99;;
esac
'@
            foreach ($name in 'id','install','chmod','dpkg','python3','blockdev','blkid','lsblk','wipefs','mkfs.ext4','mountpoint','findmnt','mount','apt-get','curl','gpg','pwsh','az','timedatectl') {
                [IO.File]::WriteAllText((Join-Path $root "bin/$name"),$fake.Replace("`r`n","`n"))
            }
            $prefix=@'
export FIXTURE_ROOT='__ROOT__'
export PATH="$FIXTURE_ROOT/bin:$PATH"
command() {
    if test "$1" = -v && { test "$2" = pwsh || test "$2" = az; } && ! test -f "$FIXTURE_ROOT/installed"; then return 1; fi
    builtin command "$@"
}
'@
            $source=$hostSource
            foreach ($path in '/etc/os-release','/etc/apt','/etc/fstab','/usr/share/keyrings','/var/lib','/mnt/dispo-keys','/dev/disk/azure') { $source=$source.Replace($path,"$unix$path") }
            $source=$source.Replace('test -b "$candidate"','test -f "$candidate"')
            $script=Join-Path $root 'prepare.sh'
            [IO.File]::WriteAllText($script,($prefix.Replace('__ROOT__',$unix).Replace("`r`n","`n")+"`n"+$source))
            & $bash -c 'chmod +x "$1"/bin/*' 'fixture' $unix
            @{root=$root;unix=$unix;script=$script;original="$original`n"}
        }
        function Invoke-HostFixture {
            param([hashtable]$Fixture,[switch]$Recovery)
            $env:DEMO2_REQUIRE_EXISTING_DISK=if($Recovery){'1'}else{'0'}
            try {
                $output=@(& $bash $Fixture.script ('a'*32) synthetic vm disk 2>&1 | ForEach-Object { "$_" })
                @{exit=$LASTEXITCODE;output=($output -join "`n")}
            } finally { Remove-Item Env:\DEMO2_REQUIRE_EXISTING_DISK }
        }
    }
    It 'recovers the duplicate-repository case without changing the existing source or reformatting the disk' {
        $f=New-HostFixture 'conflict'
        $r=Invoke-HostFixture $f -Recovery
        $r.exit | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $f.root 'etc/apt/sources.list.d/microsoft-prod.list')) | Should -BeExactly $f.original
        Test-Path (Join-Path $f.root 'etc/apt/sources.list.d/demo2-powershell.list') | Should -BeFalse
        Test-Path (Join-Path $f.root 'mutations') | Should -BeFalse
        $calls=[IO.File]::ReadAllText((Join-Path $f.root 'apt-calls'))
        ($calls -split "`n" | Where-Object { $_ -and $_ -notmatch 'Dir::Etc::sourceparts=-' }).Count | Should -Be 0
        $r.output | Should -Match 'FIELD_HOST_PREPARED'
    }
    It 'formats a blank synthetic disk once and preserves its receipt on subsequent invocation' {
        $f=New-HostFixture 'fresh' -Fresh
        (Invoke-HostFixture $f).exit | Should -Be 0
        (Invoke-HostFixture $f).exit | Should -Be 0
        @((Get-Content (Join-Path $f.root 'mutations')) | Where-Object { $_ -eq 'format' }).Count | Should -Be 1
    }
    It 'preserves existing disk and receipt across a package failure and safe retry' {
        $f=New-HostFixture 'apt-retry'
        [IO.File]::WriteAllText((Join-Path $f.root 'apt-fail'),'')
        $r=Invoke-HostFixture $f -Recovery
        $r.exit | Should -Be 100
        $r.output | Should -Match 'DEMO2_PREPARE_ERROR phase=Dependencies line=[0-9]+ exit=100'
        (Invoke-HostFixture $f -Recovery).exit | Should -Be 0
        Test-Path (Join-Path $f.root 'mutations') | Should -BeFalse
    }
    It 'stops before packages or irreversible writes for <Kind>' -ForEach @(
        @{Kind='missing disk receipt';Flag='receipt'},
        @{Kind='wrong disk UUID';Flag='wrong-uuid'},
        @{Kind='wrong mount UUID';Flag='wrong-mount'},
        @{Kind='missing expected mount';Flag='mounted'},
        @{Kind='unrecognized demo repository file';Flag='repository'}
    ) {
        $f=New-HostFixture $Flag
        switch($Flag) {
            receipt { Remove-Item (Join-Path $f.root ('var/lib/demo2-setup/'+('a'*32)+'/disk.json')) }
            mounted { Remove-Item (Join-Path $f.root 'mounted') }
            repository { [IO.File]::WriteAllText((Join-Path $f.root 'etc/apt/sources.list.d/demo2-powershell.list'),'unrecognized source') }
            default { [IO.File]::WriteAllText((Join-Path $f.root $Flag),'') }
        }
        $r=Invoke-HostFixture $f -Recovery
        $r.exit | Should -Not -Be 0
        $r.output | Should -Match 'DEMO2_PREPARE_ERROR phase=(DiskInspect|Mount|Repositories)'
        Test-Path (Join-Path $f.root 'apt-calls') | Should -BeFalse
        Test-Path (Join-Path $f.root 'mutations') | Should -BeFalse
        if ($Flag -in 'receipt','wrong-uuid','wrong-mount','mounted') {
            Test-Path (Join-Path $f.root 'volume-permissions') | Should -BeFalse
        }
    }
    It 'reports <Phase> failures without exposing a command or silently accepting a bad prerequisite' -ForEach @(
        @{Phase='Device';Flag='wrong-size'},
        @{Phase='SigningKey';Flag='wrong-key'},
        @{Phase='PowerShell';Flag='pwsh-fail'},
        @{Phase='TimeSync';Flag='bad-time'}
    ) {
        $f=New-HostFixture $Flag
        [IO.File]::WriteAllText((Join-Path $f.root $Flag),'')
        $r=Invoke-HostFixture $f -Recovery
        $r.exit | Should -Not -Be 0
        $r.output | Should -Match "DEMO2_PREPARE_ERROR phase=$Phase line=[0-9]+ exit=[0-9]+"
        $r.output | Should -Not -Match 'BASH_COMMAND'
        Test-Path (Join-Path $f.root 'mutations') | Should -BeFalse
    }
}
