Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Demo.Custody.psm1')
$script:Kit = Split-Path $PSScriptRoot -Parent

function Save-DemoJournal {
    param([hashtable]$Journal,[string]$Path)
    $temporary = "$Path.tmp"
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 40))
    $stream = [IO.File]::Open($temporary,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($temporary,$Path,$true)
}

function Save-DemoSetupDiagnostic {
    param([Management.Automation.ErrorRecord]$Record,[string]$InstallPath,[string]$Stage)
    Assert-DemoPrivatePath $InstallPath
    $facts=@{}
    foreach ($name in 'AzureCliExitCode','AzureCliCode','AzureErrorCodes','Command','OperationId','ProvisioningState','HttpStatus','requestId','correlationId','NativeErrorCode','StderrClassification','StdoutClassification','GuestFailure') {
        if ($Record.Exception.Data.Contains($name)) { $facts[$name]=$Record.Exception.Data[$name] }
    }
    $snapshot=@{utc=[datetimeoffset]::UtcNow.ToString('o');stage=$Stage;cli=$facts;exceptionType=$Record.Exception.GetType().FullName
        errorId=$Record.FullyQualifiedErrorId;category=[string]$Record.CategoryInfo.Category;stack=$Record.ScriptStackTrace}
    $path=Join-Path $InstallPath ("setup-diagnostic-"+[guid]::NewGuid().ToString('N')+'.local.json')
    $bytes=[Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Depth 6))
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes) } finally { $stream.Dispose() }
    Protect-DemoPrivateFile $path
    return $path
}

function Assert-DemoJournal {
    param([hashtable]$Journal)
    if ($Journal.schemaVersion -ne 1 -or $Journal.installationId -notmatch '^[a-f0-9]{32}$' -or
        $Journal.config.resourceGroup -ne "rg-demo2-$($Journal.config.nameSuffix)" -or
        -not ($Journal.receipts -is [Collections.IDictionary])) { throw 'Invalid install journal; do not reconstruct it by guessing resource ownership.' }
    $fingerprint = Get-DemoConfigFingerprint $Journal.config
    if ($fingerprint -ne $Journal.configFingerprint) { throw 'Configuration drift detected. Reconcile this installation rather than starting new resources.' }
}

function Get-DemoConfigFingerprint {
    param([hashtable]$Config)
    $immutable = @($Config.tenantId,$Config.subscriptionId,$Config.resourceGroup,$Config.nameSuffix,$Config.location,
        $Config.hsmName,$Config.vmSize,($Config.imageReference | ConvertTo-Json -Compress),
        ($Config.network | ConvertTo-Json -Compress),$Config.manualRecoveryObjectId,$Config.sshPublicKey,
        $Config.alertEmail,$Config.budgetAmount,$Config.hsmRetentionDays,$Config.policyMode,$Config.deniedLocation)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($immutable -join '|'))))
}

function Get-DemoSourceFingerprint {
    param([switch]$ProvisioningOnly,[switch]$PolicyIsolationBase,[switch]$CliTransportBase,[switch]$GuestPrepareBase)
    $paths = @('Start-Demo.ps1','config.schema.json','content','host','scripts','infra')
    $localModules=@((Join-Path $script:Kit 'scripts\Demo.Setup.psm1'),(Join-Path $script:Kit 'scripts\Demo.Custody.psm1'))
    $isolationFiles=@('infra\main.bicep','scripts\Deploy-Demo.ps1','scripts\Test-PolicyExamples.ps1') | ForEach-Object { Join-Path $script:Kit $_ }
    $manifest = foreach ($path in $paths) {
        Get-ChildItem (Join-Path $script:Kit $path) -Recurse -File | Where-Object Extension -in '.json','.txt','.ps1','.psm1','.sh','.bicep' |
            Where-Object { -not ($ProvisioningOnly -or $PolicyIsolationBase -or $CliTransportBase -or $GuestPrepareBase) -or $_.FullName -notin $localModules -or ($GuestPrepareBase -and $_.FullName -eq $localModules[1]) } |
            Where-Object { -not $PolicyIsolationBase -or $_.FullName -notin $isolationFiles } |
            Where-Object { -not $CliTransportBase -or $_.FullName -ne (Join-Path $script:Kit 'scripts\Demo.Common.psm1') } |
            Where-Object { -not $GuestPrepareBase -or $_.FullName -notin @((Join-Path $script:Kit 'host\Prepare-FieldHost.sh'),(Join-Path $script:Kit 'scripts\Get-SetupDiagnostic.ps1')) } |
            ForEach-Object { $_.FullName.Substring($script:Kit.Length) + ':' + (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((($manifest | Sort-Object) -join "`n"))))
}

function Read-DemoAnswer {
    param([string]$Label,[switch]$Secure)
    if ($Secure) { Assert-DemoSecureInputAvailable }
    try { $answer=Read-Host "$Label$(if ($Secure) { ' (masked; empty or q cancels)' } else { ' (q cancels; Enter does not accept a suggestion)' })" -AsSecureString:$Secure }
    catch { throw [OperationCanceledException]::new('Input unavailable or cancelled. Use interactive PowerShell without -NonInteractive and reuse the printed installation path.', $_.Exception) }
    if ($Secure) {
        if ($null -eq $answer -or $answer.Length -eq 0) {
            if ($null -ne $answer) { $answer.Dispose() }
            throw [OperationCanceledException]::new('Secure input cancelled or ended (EOF). Existing custody is preserved.')
        }
        if ($answer.Length -eq 1) {
            $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($answer)
            try { $cancel=[Runtime.InteropServices.Marshal]::ReadInt16($pointer) -in 81,113 }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
            if ($cancel) { $answer.Dispose(); throw [OperationCanceledException]::new('Selection cancelled by the operator. Existing custody is preserved.') }
        }
    } else {
        if ($null -eq $answer) { throw [OperationCanceledException]::new('Input ended (EOF). Retry from interactive PowerShell with the same installation path.') }
        if ($answer.Trim() -iin @('q','cancel')) { throw [OperationCanceledException]::new('Selection cancelled by the operator. Existing resources and custody files are preserved.') }
    }
    return $answer
}

function Assert-DemoSecureInputAvailable {
    if ([Console]::IsInputRedirected) {
        throw [OperationCanceledException]::new('Secure input unavailable from redirected input. Use an interactive PowerShell terminal; do not pipe passphrases or Setup input. Existing custody is preserved.')
    }
}

function Read-DemoText {
    param([string]$Label,[scriptblock]$Validate={ param($Value) if ([string]::IsNullOrWhiteSpace($Value)) { 'Enter a nonempty value.' } })
    while ($true) {
        $value=(Read-DemoAnswer $Label).Trim()
        $problem=& $Validate $value
        if (-not $problem) { return $value }
        Write-Warning $problem
    }
}

function Read-DemoPositiveAmount {
    param([string]$Label)
    $value=Read-DemoText $Label {
        param($Text)
        $number=[decimal]0
        if (-not [decimal]::TryParse($Text,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or $number -le 0) {
            'Enter a positive amount, for example 1234.56, using a decimal point and no currency symbol or thousands separators. Budgets are notifications, not caps.'
        }
    }
    [decimal]::Parse($value,[Globalization.CultureInfo]::InvariantCulture)
}

function Read-DemoEmail {
    Read-DemoText 'Recovery alert email: your monitored mailbox (format example presenter@example.com, not a suggested recipient)' {
        param($Value)
        $address=$null
        if ($Value -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' -or
            -not [Net.Mail.MailAddress]::TryCreate($Value,[ref]$address) -or $address.Address -cne $Value) {
            'Enter one plain email address, for example presenter@example.com, without a display name or spaces.'
        }
    }
}

function Get-DemoIpv4Range {
    param([string]$Cidr)
    $address=$null; $parts=$Cidr.Split('/'); $bits=0
    if ($parts.Count -ne 2 -or -not [ipaddress]::TryParse($parts[0],[ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        -not [int]::TryParse($parts[1],[ref]$bits) -or $bits -lt 0 -or $bits -gt 32) { throw 'Discovered IPv4 CIDR is invalid; overlap cannot be verified.' }
    $b=$address.GetAddressBytes()
    $start=[uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+$b[3]
    @{start=$start;end=$start+[uint64][math]::Pow(2,32-$bits)-1}
}

function Read-DemoVnetCidr {
    param([string[]]$ExistingCidrs=@(),[string]$CurrentValue,[switch]$DiscoveryVerified)
    $ranges=@(foreach ($cidr in $ExistingCidrs) { if (-not $cidr.Contains(':')) { Get-DemoIpv4Range $cidr } })
    $validate={
        param($Value)
        $address=$null
        if ($Value -notmatch '^(\d{1,3}\.){3}0/24$' -or -not [ipaddress]::TryParse(($Value -split '/')[0],[ref]$address) -or
            "$address/24" -cne $Value -or -not ($Value -match '^10\.' -or $Value -match '^192\.168\.' -or $Value -match '^172\.(1[6-9]|2\d|3[01])\.')) {
            return 'Enter a network-aligned private IPv4 /24, for example 10.91.0.0/24 (10/8, 172.16/12 or 192.168/16). No host bits, shorthand or invalid octets.'
        }
        $candidate=Get-DemoIpv4Range $Value
        foreach ($range in $ranges) {
            if ($candidate.start -le $range.end -and $candidate.end -ge $range.start) { return 'That /24 overlaps a discovered subscription VNet. Choose a different nonoverlapping private /24.' }
        }
    }
    if ($CurrentValue) {
        $problem=& $validate $CurrentValue
        if (-not $problem) { return $CurrentValue }
        Write-Warning $problem
    }
    $suggestion=$null
    foreach ($candidate in @('10.91.0.0/24','10.92.0.0/24','10.93.0.0/24','172.31.240.0/24','192.168.240.0/24')) {
        if (-not (& $validate $candidate)) { $suggestion=$candidate; break }
    }
    if ($suggestion) {
        $basis=if ($DiscoveryVerified) { 'checked against discovered subscription VNets only' } else { 'example checked only against supplied ranges; discovery is unverified' }
        Write-Host "Suggested network: $suggestion ($basis). Peered, other-subscription and on-premises ranges are NOT verified. Type your approved range; Enter does not accept it."
    } else { Write-Host 'No nonoverlapping network suggestion is available from the example ranges. Enter your own approved private /24; no default is selected.' }
    Read-DemoText 'New nonoverlapping private /24 VNet (network address, not a host address)' $validate
}

function Set-DemoFieldNetwork {
    param([hashtable]$Config,[string]$Cidr)
    $prefix=($Cidr -split '/')[0] -replace '\.0$',''
    $Config.network.vnetCidr=$Cidr; $Config.network.computeSubnetCidr="$prefix.0/26"
    $Config.network.endpointSubnetCidr="$prefix.64/27"; $Config.network.bastionSubnetCidr="$prefix.128/26"
}

function Read-DemoBackupDirectory {
    param([string]$InstallPath,[string]$InstallationId,[string]$CurrentValue,[switch]$Resume)
    $validate={ param($Value) Get-DemoBackupPathError $Value $InstallPath $InstallationId -Resume:$Resume }
    if ($CurrentValue) {
        $problem=& $validate $CurrentValue
        if (-not $problem) { return $CurrentValue }
        Write-Warning $problem
    }
    Write-Host "On your independently approved protected/removable drive, use a NEW dedicated directory such as <your-drive>:\Demo2-Recovery\$InstallationId. No drive, encryption or offline custody is assumed; Enter does not accept an example."
    Read-DemoText 'Separate backup directory: type the full path on your chosen medium (not a drive root, repository, or this installation)' $validate
}

function Test-DemoPassphraseEqual {
    param([securestring]$Left,[securestring]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    $a=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Left)
    $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Right)
    try {
        $difference=0
        for ($i=0; $i -lt $Left.Length; $i++) { $difference=$difference -bor ([Runtime.InteropServices.Marshal]::ReadInt16($a,$i*2) -bxor [Runtime.InteropServices.Marshal]::ReadInt16($b,$i*2)) }
        return $difference -eq 0
    } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Read-DemoNewPassphrase {
    $password=$null; $returned=$false
    try {
        while ($true) {
            $password=Read-DemoAnswer 'New custody backup passphrase (at least 16 characters, kept separately)' -Secure
            if ($password.Length -ge 16) { break }
            $password.Dispose(); $password=$null
            Write-Warning 'Use at least 16 characters. The passphrase is never logged; empty or q cancels.'
        }
        while ($true) {
            $confirmation=Read-DemoAnswer 'Re-enter the same new passphrase' -Secure
            try { $matches=Test-DemoPassphraseEqual $password $confirmation }
            finally { $confirmation.Dispose() }
            if ($matches) { $returned=$true; return $password }
            Write-Warning 'Passphrases do not match. Re-enter the original passphrase, or q to cancel; it has not been used to create keys.'
        }
    } finally { if (-not $returned -and $null -ne $password) { $password.Dispose() } }
}

function Resolve-DemoCustodyBackupLocation {
    param([string]$InstallPath)
    while ($true) {
        $state=Get-DemoCustodyRecoveryState $InstallPath
        $expected=$state.receipt.backupFile
        Write-Host "Expected encrypted custody backup: $expected"
        if ($state.backupAvailable) { return @{SourcePath=$expected;BackupFile=$expected;Recover=(-not $state.localAvailable)} }
        Write-Warning $(if (-not $state.driveAvailable) { 'The recorded backup drive is disconnected, locked or remapped. Reconnect it or locate the original encrypted package.' } else { 'The recorded external backup file is missing. Its location has not been verified.' })
        if (-not $state.localAvailable) { Write-Warning 'No accessible custody package remains. Setup is blocked until you reconnect or locate the original backup. Keys cannot be regenerated.' }
        $options=@(@{name='Reconnect/unlock the recorded medium, then retry its stored path';action='retry'},
            @{name='Locate an existing relocated encrypted .pfx backup';action='locate'})
        if ($state.localAvailable) { $options+=@{name='Authenticate the retained local package, then copy those exact encrypted bytes to a separate dedicated backup directory';action='copy'} }
        $choice=Select-DemoValue 'Custody backup recovery action' $options 'name'
        if ($choice.action -eq 'retry') { continue }
        if ($choice.action -eq 'copy') {
            $directory=Read-DemoBackupDirectory $InstallPath $state.receipt.installationId -Resume
            return @{SourcePath=$state.localPath;BackupFile=(Join-Path $directory "$($state.receipt.installationId)-custody.pfx");Recover=$true}
        }
        $validate={
            param($Value)
            if ($Value -notmatch '^[A-Za-z]:\\' -or $Value -match '[*?"/<>|\x00-\x1f]' -or $Value.Substring(2).Contains(':')) { return 'Type the full drive-qualified path to the original encrypted .pfx file.' }
            $problem=Get-DemoBackupPathError (Split-Path $Value -Parent) $InstallPath $state.receipt.installationId -Resume -Recovery -ArchiveName (Split-Path $Value -Leaf)
            if ($problem) { return $problem }
            if (-not (Test-Path -LiteralPath $Value -PathType Leaf -ErrorAction Stop)) { return 'Encrypted file not found. Reconnect the medium or enter its actual full .pfx path.' }
            try { Assert-DemoPrivatePath $Value } catch [ArgumentException] { return $_.Exception.Message }
        }
        $path=Read-DemoText 'Full path to the relocated original encrypted .pfx backup (same package, no replacement keys)' $validate
        return @{SourcePath=$path;BackupFile=$path;Recover=$true}
    }
}

function Read-DemoCustodyPassphrase {
    param([string]$InstallPath,[switch]$Pending)
    $location=if ($Pending) { @{SourcePath='';Recover=$false} } else { Resolve-DemoCustodyBackupLocation $InstallPath }
    while ($true) {
        $password=Read-DemoAnswer 'Existing custody passphrase (no keys regenerated)' -Secure
        $returned=$false
        try {
            if (-not (Test-DemoCustodyPassword $InstallPath $password -Pending:$Pending -ArchivePath $location.SourcePath)) {
                Write-Warning 'Passphrase did not authenticate the retained encrypted backup. Retry or q to cancel. If you believe it is correct, stop and inspect the backup; no keys will be regenerated.'
                continue
            }
            if (-not $Pending) {
                if ($location.Recover) {
                    Restore-DemoCustodyBackup $InstallPath $location.SourcePath $location.BackupFile $password
                    Write-Host 'The same encrypted custody package is readable at the recorded backup location. No keys were regenerated. A separate folder does not prove physical/offline custody; retain the medium independently and keep the passphrase separate.'
                } else { Test-DemoCustodyBackup $InstallPath $password }
            }
            $returned=$true
            return $password
        } finally { if (-not $returned) { $password.Dispose() } }
    }
}

function Initialize-DemoFieldCustody {
    param([string]$InstallPath,[string]$InstallationId)
    if (Test-Path -LiteralPath (Join-Path $InstallPath 'custody.json')) {
        return (Read-DemoCustodyPassphrase $InstallPath)
    }
    $planPath=Join-Path $InstallPath 'custody-plan.json'
    $plan=$null
    if (Test-Path -LiteralPath $planPath) {
        $plan=Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -AsHashtable
        if ($plan.schemaVersion -ne 1 -or $plan.installationId -cne $InstallationId) { throw 'Custody plan does not match this installation. Preserve it for explicit reconciliation.' }
    }
    $pending=(Test-Path -LiteralPath (Join-Path $InstallPath 'custody.pfx')) -or (Test-Path -LiteralPath (Join-Path $InstallPath 'custody.pfx.pending'))
    if (-not $pending -and @(Get-ChildItem -LiteralPath $InstallPath -Filter '*.cer').Count) {
        throw 'Incomplete legacy certificate-only custody found. Preserve it and restore its existing encrypted custody.pfx into this protected installation before resuming; no replacement keys will be generated.'
    }
    $previous=if ($plan) { $plan.backupDirectory } else { '' }
    $backup=Read-DemoBackupDirectory $InstallPath $InstallationId -CurrentValue $previous -Resume:$pending
    $password=$null; $returned=$false
    try {
        if ($pending) {
            $password=Read-DemoCustodyPassphrase $InstallPath -Pending
            if (-not $plan) { Save-DemoJournal @{schemaVersion=1;installationId=$InstallationId;backupDirectory=$backup} $planPath }
            Resume-DemoCustody $InstallPath $backup $password $InstallationId
        } else {
            $password=Read-DemoNewPassphrase
            New-DemoCustody $InstallPath $backup $password $InstallationId
        }
        $returned=$true
        return $password
    } finally { if (-not $returned -and $null -ne $password) { $password.Dispose() } }
}

function Update-DemoLocalPromptSource {
    param([hashtable]$Journal,[string]$JournalPath,[string]$Mode='Setup')
    $current=Get-DemoSourceFingerprint
    if ($Journal.sourceFingerprint -ceq $current) { return }
    if ($Journal.sourceFingerprint -ceq '6822E148B4A597D7C6C950E608D8C19478705C0E8D64062A8DF223E3CFDD0427') {
        if ($Mode -cne 'Setup') { throw 'Use Setup to reconcile this failed preparation. Run/Rehearse cannot authorize a guest-host repair.' }
        Initialize-DemoGuestPrepareRecovery $Journal $JournalPath $current
        return
    }
    if ($Journal.sourceFingerprint -cin @('AABFC62FDB574831ABF95A47F3083209C68F73E1CF9738680D0079211A6D758A','D4F9A14CC558797D6F4A2DC8D438C6FA8973C523B95D1185A88BF4C73E08CF76','2178046C1AD381BE26E2471DF735C59D4F54A892AD583C68BB8356E3AF57774E','1A0FEBF1A04E310EA6C3862F99D9511D6B8C9DCD4A2E6A3885C3FAF05292D233')) {
        $known=@('Custody','Cost','PolicyIsolation','Foundation','PublicPayload','Guest','DomainActivated','DomainBackup','Keys','Storage','UploadRoleLive','UploadRoleTwin','Content','Worker','Reduced','Baseline')
        if ((Get-DemoSourceFingerprint -CliTransportBase) -cne '6B3A956238A3D4361B5283133DBBE1A664D3B1AA7B5B413E8CA0997B2E5D3F92' -or
            (Get-FileHash (Join-Path $script:Kit 'scripts\Demo.Common.psm1')).Hash -cne '615C4EFE72D170E7790581C755381186672589EC09582C1C7186FCDA75782942' -or
            $Journal.status -notin 'Preparing','ConfiguredNeedsRehearsal' -or @($Journal.receipts.get_Keys() | Where-Object { $_ -notin $known }).Count) {
            throw 'Source changed outside the exact CLI transport patch or has unknown/pending stages. Preserve state for explicit reconciliation; no guest-stage/runtime upgrade is authorized.'
        }
        if ($Journal.pendingAgent) {
            $intent=$Journal.pendingAgent
            if ($intent -isnot [Collections.IDictionary] -or [string]$intent['operationId'] -notmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
                [string]$intent['digest'] -notmatch '^[a-fA-F0-9]{64}$' -or -not $intent.ContainsKey('startedUtc')) {
                throw 'Unknown/pending agent intent cannot migrate. Preserve it; no approval or new operation can bypass correlation.'
            }
            Assert-DemoAzureContext $Journal.config
            if (-not (Assert-DemoInstallOwner $Journal)) { throw 'Pending command has no owned resource group; preserve intent for reconciliation.' }
            $null=Wait-DemoManagedCommand $Journal $intent.operationId $intent.digest
        }
        $Journal.sourceFingerprint=$current
        Save-DemoJournal $Journal $JournalPath
        Write-Host 'Verified exact CLI transport/diagnostics update and any retained command. Pending intent is preserved for its original stage; no changed guest-stage/worker code accepted.'
        return
    }
    $previous=@('EA5289ADEFAF98ADC808972182337EC3764507D226F4A35BDAD381267AE008A4',
        '3C97B68209B2913A11E71EB37D5889446ED7A9CC2108151B043E1F3C1829B852',
        '542448B679ED37A2F1A86FDD237FA2841516621A38D83A25654CE9631D9955CF')
    $unchanged=@('B1931C627719F5ABFBE310DF448C5B6B93C003E73621141F5B9E2EB65DF20923',
        '202B0DDE40DA388C29A1231284D4A8727D1ABB13073DB410D622D5AAFA74BAC9')
    $patches=@{
        'infra\main.bicep'='20CD44BCD3711BB994D465E036E3C583D08F5746DB852947E784D7E4A1B02E21'
        'scripts\Deploy-Demo.ps1'='7E0668403CE917D5837802E87AD3E595470021BAC89A5F7A88713EE2D0CFE0DE'
        'scripts\Test-PolicyExamples.ps1'='4298532D04A0D287D0D4D33F296A35CA54FE929AD7CA3BC30D9A8D966E958897'
    }
    if ($Journal.sourceFingerprint -cnotin $previous -or (Get-DemoSourceFingerprint -PolicyIsolationBase) -cnotin $unchanged -or $Journal.pendingAgent -or
        $Journal.resources.Count -or @($Journal.receipts.get_Keys() | Where-Object { $_ -notin 'Custody','Cost' }).Count -or $Journal.status -ne 'Preparing' -or $Journal.config.policyMode -ne 'sandbox') {
        throw 'Source changed since this installation began. Only a recognized pre-foundation installation can reconcile the policy-name fix. Preserve unknown, provisioned or pending-operation states for explicit reconciliation.'
    }
    foreach ($path in $patches.get_Keys()) {
        if ((Get-FileHash -LiteralPath (Join-Path $script:Kit $path)).Hash -cne $patches[$path]) { throw 'Source changed outside the exact reviewed deployment-name patch. No migration or deployment attempted.' }
    }
    $proof=Test-DemoPolicyIsolationRecovery $Journal
    Write-Host 'Verified policy deployment-name recovery. Existing target/custody and partial foundation resources are preserved; no guest/runtime upgrade is authorized.'
    $Journal.sourceFingerprint=$current
    $Journal.receipts.PolicyIsolation=$proof
    Save-DemoJournal $Journal $JournalPath
}

function Get-DemoArmRecord {
    param([string]$Uri,[string[]]$NotFoundCodes)
    try { $record=Invoke-AzJson @('rest','--method','get','--url',$Uri) }
    catch {
        $failure=$_; $text=$failure.Exception.Message
        $start=$text.IndexOf('{'); $end=$text.LastIndexOf('}')
        if ($start -lt 0 -or $end -lt $start) { throw $failure }
        try { $errorBody=$text.Substring($start,$end-$start+1) | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { throw $failure }
        $code=if ($errorBody.ContainsKey('code')) { $errorBody['code'] } elseif ($errorBody['error'] -is [Collections.IDictionary]) { $errorBody['error']['code'] } else { '' }
        if ($code -notin $NotFoundCodes) { throw $failure }
        Write-Verbose "Exact ARM metadata record is absent ($code): $Uri"
        return $null
    }
    if ($record -isnot [Collections.IDictionary] -or $record['id'] -ine ([uri]$Uri).AbsolutePath) { throw 'ARM metadata did not identify the exact requested resource; no reconciliation attempted.' }
    return $record
}

function Test-DemoPolicyLocationCollision {
    param([object]$Node)
    if ($Node -is [Collections.IDictionary]) {
        if ($Node['code'] -eq 'InvalidDeploymentLocation' -and [string]$Node['message'] -match '(?<![a-z0-9_.()-])demo2-sandbox-policy(?![a-z0-9_.()-])') { return $true }
        foreach ($value in $Node.Values) { if (Test-DemoPolicyLocationCollision $value) { return $true } }
    } elseif ($Node -is [Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($value in $Node) { if (Test-DemoPolicyLocationCollision $value) { return $true } }
    } elseif ($Node -is [string] -and $Node.TrimStart().StartsWith('{')) {
        try { $decoded=$Node | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { return $false }
        return (Test-DemoPolicyLocationCollision $decoded)
    }
    return $false
}

function Assert-DemoUnusedPolicyNames {
    param([hashtable]$Config)
    if ($Config.policyMode -ne 'sandbox') { return }
    foreach ($suffix in 'storage-cmk','confidential-vm') {
        $uri="https://management.azure.com/subscriptions/$($Config.subscriptionId)/providers/Microsoft.Authorization/policyDefinitions/demo2-$($Config.nameSuffix)-${suffix}?api-version=2023-04-01"
        $definition=Get-DemoArmRecord $uri @('PolicyDefinitionNotFound','ResourceNotFound')
        if ($null -ne $definition) { throw 'This installation policy-definition name already exists. Ownership is not proven; preserve it and reconcile explicitly rather than modify an earlier policy.' }
    }
    Write-Host 'Exact installation policy-definition names are unused; earlier installation policies will not be adopted.'
}

function Test-DemoPolicyIsolationRecovery {
    param([hashtable]$Journal)
    $config=$Journal.config
    Assert-DemoAzureContext $config
    $groupExists=Assert-DemoInstallOwner $Journal
    $scope="https://management.azure.com/subscriptions/$($config.subscriptionId)/providers/Microsoft.Resources/deployments"
    $name="demo2-$($Journal.installationId)"
    $deployment=Get-DemoArmRecord "$scope/${name}?api-version=2022-09-01" @('DeploymentNotFound')
    if ($null -ne $deployment) {
        if (-not $groupExists) { throw 'Failed foundation history exists but its resource group is missing. Preserve custody/history and reconcile retained resources; do not recreate the group automatically.' }
        $parameters=$deployment.properties.parameters
        $sameConfig=[Newtonsoft.Json.Linq.JToken]::DeepEquals(
            [Newtonsoft.Json.Linq.JToken]::Parse(($config | ConvertTo-Json -Depth 40 -Compress)),
            [Newtonsoft.Json.Linq.JToken]::Parse(($parameters.config.value | ConvertTo-Json -Depth 40 -Compress)))
        if ($deployment.location -ne $config.location -or $deployment.properties.provisioningState -ne 'Failed' -or
            $parameters.installationId.value -cne $Journal.installationId -or $parameters.stage.value -ne 'foundation' -or
            $parameters.bootstrapEnabled.value -ne $true -or -not $sameConfig -or
            -not (Test-DemoPolicyLocationCollision $deployment.properties.error)) {
            throw 'Foundation history is not the matching terminal policy-location failure. Preserve resources/history; reconcile its ownership and operation state explicitly.'
        }
    } elseif ($groupExists) { throw 'An owned group exists without correlated foundation history. Preserve it; read-only deployment/resource reconciliation is required before retry.' }
    $legacy=Get-DemoArmRecord "$scope/demo2-sandbox-policy?api-version=2022-09-01" @('DeploymentNotFound')
    if ($null -eq $legacy -or $legacy.location -eq $config.location) { throw 'The earlier cross-region policy deployment collision cannot be verified. No migration or provisioning attempted.' }
    if ($groupExists) {
        $operations=@(Invoke-AzJson @('deployment','group','list','--subscription',$config.subscriptionId,'--resource-group',$config.resourceGroup))
        if (@($operations | Where-Object { $_.properties.provisioningState -notin 'Succeeded','Failed','Canceled' }).Count) {
            throw 'A resource-group deployment is still active/unknown. Wait for or reconcile that operation; no new deployment is submitted.'
        }
    }
    Assert-DemoUnusedPolicyNames $config
    return @{verifiedUtc=[datetimeoffset]::UtcNow.ToString('o');deploymentName=$name;legacyLocation=$legacy.location;ownedGroupExists=$groupExists}
}

function Assert-DemoInstallPrivacy {
    param([string]$Path)
    $repo=[IO.Path]::GetFullPath((Join-Path $script:Kit '..\..')).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.StartsWith("$repo\",[StringComparison]::OrdinalIgnoreCase)) {
        $allowed=Join-Path $repo '.private\demo2\installs'
        if (-not $full.StartsWith("$allowed\",[StringComparison]::OrdinalIgnoreCase)) { throw 'In-repo installation state must stay under .private\demo2\installs.' }
        $tracked=@(& git -C $repo ls-files -- .private/demo2)
        if ($LASTEXITCODE -ne 0 -or $tracked.Count) { throw 'Private installation root contains tracked paths.' }
        $relative=$full.Substring($repo.Length+1).Replace('\','/')+'/install.json'
        & git -C $repo check-ignore --no-index -q -- $relative
        if ($LASTEXITCODE -ne 0) { throw 'Installation state is not Git-ignored.' }
    } else {
        for ($parent=Get-Item -LiteralPath $full; $null -ne $parent; $parent=$parent.Parent) {
            if (Test-Path -LiteralPath (Join-Path $parent.FullName '.git')) { throw 'Do not store installation secrets in another Git checkout.' }
        }
    }
}

function Select-DemoValue {
    param([string]$Label,[object[]]$Values,[string]$Property,[string[]]$IdentityProperties=@(),[int]$SuggestedIndex=0,[string]$SuggestionReason)
    if ($Values.Count -eq 0) { throw "No eligible options for $Label." }
    for ($i=0; $i -lt $Values.Count; $i++) {
        $description="$($Values[$i][$Property])"
        if ($IdentityProperties.Count) {
            $identity=foreach ($field in $IdentityProperties) { "$field=$($Values[$i][$field])" }
            $description+=" [$($identity -join '; ')]"
        }
        Write-Host "$($i+1): $description"
    }
    if ($SuggestedIndex -ge 1 -and $SuggestedIndex -le $Values.Count) {
        Write-Host "Suggested choice $SuggestedIndex`: $($Values[$SuggestedIndex-1][$Property]). $SuggestionReason Type its number explicitly; Enter does not accept it."
    } elseif ($SuggestionReason) { Write-Host $SuggestionReason }
    while ($true) {
        $answer=(Read-DemoAnswer "$Label (1-$($Values.Count))").Trim()
        $choice=0
        if ([int]::TryParse($answer,[ref]$choice) -and $choice -ge 1 -and $choice -le $Values.Count) { return $Values[$choice-1] }
        Write-Warning "Enter a whole number from 1 to $($Values.Count), or q to cancel. Blank input does not select a default."
    }
}

function Get-DemoSkuSuggestion {
    param([object[]]$Skus,[object[]]$Usage)
    $candidates=@(for ($i=0; $i -lt $Skus.Count; $i++) {
        $sku=$Skus[$i]; $cores=0
        $cpu=@($sku['capabilities'] | Where-Object name -eq 'vCPUs')
        if ($cpu.Count -ne 1 -or -not [int]::TryParse([string]$cpu[0].value,[ref]$cores) -or $cores -lt 1 -or -not $sku['family']) { continue }
        $enough=$true
        foreach ($family in @($sku['family'],'cores')) {
            $quota=@($Usage | Where-Object { $_.name.value -eq $family })
            if ($quota.Count -ne 1 -or ($quota[0].limit-$quota[0].currentValue) -lt $cores) { $enough=$false; break }
        }
        if ($enough) { @{index=$i+1;cores=$cores;preferred=($sku.name -eq 'Standard_DC2as_v6')} }
    })
    if (-not $candidates.Count) { return 0 }
    ($candidates | Sort-Object @{Expression='preferred';Descending=$true},cores | Select-Object -First 1).index
}

function New-DemoFieldConfig {
    Get-Command az,ssh,ssh-keygen -ErrorAction Stop | Out-Null
    $accounts = @(Invoke-AzJson @('account','list'))
    if ($accounts.Count -eq 0) {
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { throw 'Sign-in failed; use the displayed trusted Microsoft device-login instructions.' }
        $accounts = @(Invoke-AzJson @('account','list'))
    }
    $selected = Select-DemoValue 'Choose subscription by its tenant/subscription GUIDs; no target is recommended' $accounts 'name' -IdentityProperties @('id','tenantId')
    Write-Host "Selected subscription $($selected.name) ($($selected.id)); tenant $($selected.tenantId)."
    & az account set --subscription $selected.id
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the chosen subscription.' }
    $locations = @(Invoke-AzJson @('account','list-locations'))
    while ($true) {
        $location = Select-DemoValue 'Choose an approved deployment region from the catalog (residency, HSM support and capacity still require preflight)' $locations 'name'
        $skus = @(Invoke-AzJson @('vm','list-skus','--location',$location.name,'--resource-type','virtualMachines','--all'))
        $eligible = @($skus | Where-Object {
            $_.restrictions.Count -eq 0 -and
            @($_.capabilities | Where-Object { $_.name -eq 'ConfidentialComputingType' -and $_.value -notin @('','None') }).Count -gt 0
        })
        if (-not $eligible.Count) { Write-Warning 'No unrestricted confidential SKU is listed in that region. Choose another region, or q to cancel; no default SKU will be used.'; continue }
        $images = @(Invoke-AzJson @('vm','image','list','--location',$location.name,'--publisher','Canonical',
            '--offer','0001-com-ubuntu-confidential-vm-jammy','--sku','22_04-lts-cvm','--all'))
        if (-not $images.Count) { Write-Warning 'The supported confidential Ubuntu 22.04 image is unavailable there. Choose another region, or q to cancel.'; continue }
        $usage=@(Invoke-AzJson @('vm','list-usage','--location',$location.name))
        $suggested=Get-DemoSkuSuggestion $eligible $usage
        $reason=if ($suggested) { 'Catalog-eligible with enough reported family/regional vCPU quota; availability is not reserved or guaranteed.' } else { 'No quota-verified SKU suggestion is available. Catalog presence alone is not quota, permission or allocatable capacity; choose only after reviewing your requirements.' }
        $sku = Select-DemoValue 'Choose an unrestricted confidential SKU' $eligible 'name' -SuggestedIndex $suggested -SuggestionReason $reason
        break
    }
    $image = $images | Sort-Object version | Select-Object -Last 1
    $user = Invoke-AzJson @('ad','signed-in-user','show')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0,10)
    $config = Get-Content (Join-Path $script:Kit 'config.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $config.tenantId=$selected.tenantId; $config.subscriptionId=$selected.id
    $config.nameSuffix=$suffix; $config.resourceGroup="rg-demo2-$suffix"; $config.hsmName="hsm-demo2-$suffix"
    $config.location=$location.name; $config.allowedLocations=@($location.name)
    $config.deniedLocation=(Select-DemoValue 'Choose the deliberately disallowed test region' @($locations | Where-Object name -ne $location.name) 'name' -SuggestedIndex 1 -SuggestionReason 'This catalog candidate is outside this installation allowed location; it is only for a policy-denial probe.').name
    $config.vmSize=$sku.name; $config.allowedConfidentialVmSkus=@($sku.name)
    $config.imageReference=@{publisher=$image.publisher;offer=$image.offer;sku=$image.sku;version=$image.version}
    $config.manualRecoveryObjectId=$user.id; $config.initialAdminObjectIds=@($user.id)
    $config.alertEmail=Read-DemoEmail
    $config.budgetAmount=Read-DemoPositiveAmount 'Monthly notification budget: example 100 in subscription billing currency, solely an alert threshold (NOT a price estimate or spending cap); type your chosen amount'
    $vnets=@(Invoke-AzJson @('network','vnet','list','--subscription',$selected.id))
    Set-DemoFieldNetwork $config (Read-DemoVnetCidr -ExistingCidrs @($vnets | ForEach-Object { $_.addressSpace.addressPrefixes }) -DiscoveryVerified)
    $config.targets.Live.accountName="demo2${suffix}live"; $config.targets.Twin.accountName="demo2${suffix}twin"
    $config.targets.Live.keyName="demo2-$suffix-live"; $config.targets.Twin.keyName="demo2-$suffix-twin"
    return $config
}

function Test-DemoFieldPreflight {
    param([hashtable]$Config,[string]$ConfigPath)
    Assert-DemoAzureContext $Config
    Assert-DemoUnusedPolicyNames $Config
    & (Join-Path $PSScriptRoot 'Test-AzurePrerequisites.ps1') -ConfigPath $ConfigPath -AuthorizeAzureReads | Format-List | Out-Host
    Write-Host 'Quick setup uses RG-scoped sandbox policies, NOT an SLZ. Private endpoints, trusted Storage HSM access, Bastion, NAT/package/Entra/ARM egress and authenticated Monitor are required. Inherited policies are never weakened.'
    $permissions=Invoke-AzJson @('rest','--method','get','--url',"https://management.azure.com/subscriptions/$($Config.subscriptionId)/providers/Microsoft.Authorization/permissions?api-version=2022-04-01")
    foreach ($action in @('Microsoft.Resources/subscriptions/resourceGroups/write','Microsoft.Resources/deployments/write',
        'Microsoft.Authorization/policyDefinitions/write','Microsoft.Authorization/policyAssignments/write','Microsoft.Authorization/roleAssignments/write',
        'Microsoft.KeyVault/managedHSMs/write','Microsoft.Compute/virtualMachines/write','Microsoft.Network/virtualNetworks/write',
        'Microsoft.Storage/storageAccounts/write','Microsoft.ManagedIdentity/userAssignedIdentities/write','Microsoft.Consumption/budgets/write',
        'Microsoft.Insights/scheduledQueryRules/write','Microsoft.OperationalInsights/workspaces/write')) {
        $allowed=@($permissions.value | Where-Object {
            $grant=$_
            @($grant.actions | Where-Object { $action -like $_ }).Count -gt 0 -and
            @($grant.notActions | Where-Object { $action -like $_ }).Count -eq 0
        }).Count -gt 0
        if (-not $allowed) { throw "Required effective subscription permission not demonstrated: $action. Activate the appropriate scoped role/PIM access and retry." }
    }
    $sku = @(Invoke-AzJson @('vm','list-skus','--location',$Config.location,'--size',$Config.vmSize,'--all') |
        Where-Object { $_.name -eq $Config.vmSize -and $_.resourceType -eq 'virtualMachines' })
    if ($sku.Count -ne 1) { throw 'SKU discovery is ambiguous.' }
    $cores = [int](@($sku[0].capabilities | Where-Object name -eq 'vCPUs')[0].value)
    $usage = @(Invoke-AzJson @('vm','list-usage','--location',$Config.location))
    foreach ($family in @($sku[0].family,'cores')) {
        $limit = @($usage | Where-Object { $_.name.value -eq $family })
        if ($limit.Count -ne 1 -or ($limit[0].limit - $limit[0].currentValue) -lt $cores) { throw "Insufficient or unknown quota for $family. No quota request was submitted." }
    }
    foreach ($provider in @('Microsoft.KeyVault','Microsoft.Network','Microsoft.Compute','Microsoft.Storage','Microsoft.ManagedIdentity','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Consumption')) {
        $registration=Invoke-AzJson @('provider','show','--namespace',$provider)
        if ($registration.registrationState -ne 'Registered') { throw "$provider is not registered. Ask a platform administrator; no registration was attempted." }
        if ($provider -eq 'Microsoft.KeyVault') {
            $type=@($registration.resourceTypes | Where-Object resourceType -eq 'managedHSMs')
            if ($type.Count -ne 1 -or @($type[0].locations | Where-Object { ($_ -replace '\s','').ToLowerInvariant() -eq $Config.location }).Count -eq 0) { throw 'Managed HSM regional catalog support is unverified.' }
        }
    }
    $hsmName=Invoke-AzJson @('keyvault','check-name','--name',$Config.hsmName,'--resource-type','hsm')
    if (-not $hsmName.nameAvailable) { throw 'HSM name unavailable; never recover/adopt another or soft-deleted HSM.' }
    foreach ($target in 'Live','Twin') {
        $available=Invoke-AzJson @('storage','account','check-name','--name',$Config.targets[$target].accountName)
        if (-not $available.nameAvailable) { throw "$target account name unavailable." }
    }
    $vnets=@(Invoke-AzJson @('network','vnet','list'))
    Set-DemoFieldNetwork $Config (Read-DemoVnetCidr -ExistingCidrs @($vnets | ForEach-Object { $_.addressSpace.addressPrefixes }) -CurrentValue $Config.network.vnetCidr -DiscoveryVerified)
    Write-Host 'Catalog/quota checks passed; this does not reserve allocatable HSM/VM capacity.'
}

function Assert-DemoInstallOwner {
    param([hashtable]$Journal)
    $exists=Invoke-AzJson @('group','exists','--name',$Journal.config.resourceGroup,'--subscription',$Journal.config.subscriptionId)
    if ($exists) {
        $group=Invoke-AzJson @('group','show','--name',$Journal.config.resourceGroup,'--subscription',$Journal.config.subscriptionId)
        if ($group.tags.installationId -ne $Journal.installationId -or $group.tags.purpose -ne 'demo2-only') { throw 'Resource group is not owned by this exact installation; refusing adoption.' }
    } elseif ($Journal.receipts.ContainsKey('Foundation')) { throw 'Previously provisioned group is missing; explicit reconciliation required, not recreation.' }
    return [bool]$exists
}

function Assert-DemoManagedCommand {
    param([hashtable]$Journal,[hashtable]$Command,[string]$Operation,[string]$Digest)
    if ($Command['id'] -ine "$($Journal.resources.vmId)/runCommands/demo2-field-setup" -or $Command['location'] -ne $Journal.config.location -or
        $Command['tags'] -isnot [Collections.IDictionary] -or $Command.tags['installationId'] -cne $Journal.installationId -or $Command.tags['operationId'] -cne $Operation) {
        throw 'Guest command ownership/correlation mismatch. Pending intent retained; no command overwritten.'
    }
    $properties=$Command['properties']
    if ($properties -isnot [Collections.IDictionary] -or $properties['source'] -isnot [Collections.IDictionary] -or $properties.source['script'] -isnot [string]) {
        throw 'Guest command payload is unavailable for exact reconciliation. Pending intent retained.'
    }
    $source=$properties.source['script']
    if ($source.Contains('__OPERATION_ID__')) { throw 'Guest command payload correlation is ambiguous. Pending intent retained.' }
    $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source.Replace($Operation,'__OPERATION_ID__'))))
    if ($actual -cne $Digest.ToUpperInvariant() -or ($Command.tags.ContainsKey('payloadDigest') -and $Command.tags.payloadDigest -ine $Digest)) {
        throw 'Guest command payload digest mismatch. Pending intent retained; no changed guest code accepted.'
    }
}

function Read-DemoManagedResult {
    param([hashtable]$Command,[string]$Operation)
    $properties=$Command.properties
    $view=$properties['instanceView']
    if ($properties['provisioningState'] -in 'Failed','Canceled' -or
        ($view -is [Collections.IDictionary] -and $view['executionState'] -in 'Failed','Canceled','TimedOut')) {
        $summary=Get-DemoGuestFailureSummary $Command
        $failure=[InvalidOperationException]::new("Guest operation failed. ARM=$($summary.provisioningState); execution=$($summary.executionState); exit=$($summary.exitCode); phase=$($summary.phase); category=$($summary.category). Pending intent retained; no automatic replay. Raw output omitted.")
        $failure.Data['GuestFailure']=$summary
        throw $failure
    }
    if ($properties['provisioningState'] -ne 'Succeeded' -or $view -isnot [Collections.IDictionary] -or $view['executionState'] -ne 'Succeeded') { return $null }
    if (-not $view.ContainsKey('exitCode') -or $view.exitCode -ne 0) { throw 'Guest terminal result lacks a successful exit code; pending intent retained.' }
    $lines=([string]$view['output']).Trim() -split '\r?\n'
    try { $result=$lines[-1] | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw [InvalidOperationException]::new('Guest final result missing/malformed/truncated; pending intent retained. Output omitted.') }
    if ($result -isnot [Collections.IDictionary] -or $result['operationId'] -cne $Operation -or $result['ok'] -isnot [bool] -or $result.ok -ne $true) {
        throw 'Guest result correlation/acceptance failed; pending intent retained. Output omitted.'
    }
    return $result
}

function Get-DemoGuestFailureSummary {
    param([hashtable]$Command)
    $properties=$Command['properties']
    $view=$properties['instanceView']
    $summary=@{provisioningState='Unknown';executionState='Unknown';exitCode=$null;phase='Unknown';category='Unclassified';line=$null}
    if ($properties['provisioningState'] -in 'Accepted','Creating','Updating','Succeeded','Failed','Canceled','Deleting') { $summary.provisioningState=$properties['provisioningState'] }
    if ($view -isnot [Collections.IDictionary]) { return $summary }
    if ($view['executionState'] -in 'Pending','Running','Succeeded','Failed','Canceled','TimedOut','Unknown') { $summary.executionState=$view['executionState'] }
    if ([string]$view['exitCode'] -match '^-?[0-9]{1,10}$') { $summary.exitCode=[long]$view['exitCode'] }
    $errorText=[string]$view['error']
    if ($errorText -match '(?m)^E: Conflicting values set for option Signed-By regarding source ' -and
        $errorText -match '(?m)^E: The list of sources could not be read\.\r?$') {
        $summary.category='AptSourceConflict'; $summary.phase='Repositories'
    }
    $markers=@([regex]::Matches($errorText,'(?m)^DEMO2_PREPARE_ERROR phase=(Platform|Identity|Device|DiskInspect|DiskFormat|Mount|Repositories|Dependencies|SigningKey|Packages|PowerShell|TimeSync) line=([0-9]{1,5}) exit=([0-9]{1,3})\r?$'))
    if ($markers.Count) {
        $summary.phase=$markers[-1].Groups[1].Value
        $summary.line=[int]$markers[-1].Groups[2].Value
        if ($summary.category -eq 'Unclassified') { $summary.category='PreparePhaseFailure' }
    }
    return $summary
}

function Get-DemoGuestPrepareScript {
    param([hashtable]$Journal,[switch]$Legacy)
    $remote="/var/lib/demo2-setup/$($Journal.installationId)"
    $prefix=if (-not $Legacy -and $Journal['guestPrepareRecovery']) { 'DEMO2_REQUIRE_EXISTING_DISK=1 ' } else { '' }
    $exitCheck=if ($Legacy) { 'test $? -eq 0 || exit $?' } else { 'code=$?; if [ "$code" -ne 0 ]; then exit "$code"; fi' }
    return "$prefix/bin/bash $remote/kit/host/Prepare-FieldHost.sh $($Journal.installationId) $($Journal.config.subscriptionId) demo2-$($Journal.config.nameSuffix)-access $($Journal.resources.custodyDiskId)`n" +
        $exitCheck+ "`n" + 'printf ''%s\n'' ''{"operationId":"__OPERATION_ID__","ok":true}'''
}

function Initialize-DemoGuestPrepareRecovery {
    param([hashtable]$Journal,[string]$JournalPath,[string]$CurrentFingerprint)
    $intent=$Journal['pendingAgent']
    if ((Get-DemoSourceFingerprint -GuestPrepareBase) -cne 'D52F73DA185DE49261EFCBF4D30627F7803EFED3683C75C0A7C670752D10328F' -or
        (Get-FileHash (Join-Path $script:Kit 'host\Prepare-FieldHost.sh')).Hash -cne '7A2E6EA897A3124A0CDE1D0989AD0BCAA7A6C52A31E06094920AACCA3A2B13CB' -or
        (Get-FileHash (Join-Path $script:Kit 'scripts\Get-SetupDiagnostic.ps1')).Hash -cne 'CC52D476D3505DDD86B45DE194B5312905F8EC8F68B46F65815A5E05B03C5D38' -or
        $Journal.status -cne 'Preparing' -or $Journal['guestPrepareRecovery'] -or
        @($Journal.receipts.get_Keys() | Where-Object { $_ -notin 'Custody','Cost','PolicyIsolation','Foundation','PublicPayload' }).Count -or
        @('Custody','Foundation','PublicPayload' | Where-Object { -not $Journal.receipts.ContainsKey($_) }).Count -or
        $intent -isnot [Collections.IDictionary] -or [string]$intent['operationId'] -notmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') {
        throw 'Source update is restricted to the verified pre-activation GuestPrepare repository failure. Preserve incompatible or unknown state; no guest retry authorized.'
    }
    $original=Get-DemoGuestPrepareScript $Journal -Legacy
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($original)))
    if ($intent['digest'] -cne $digest) { throw 'Pending operation is not the exact preceding GuestPrepare wrapper. Preserve it; no retry or changed source accepted.' }
    Assert-DemoAzureContext $Journal.config
    if (-not (Assert-DemoInstallOwner $Journal)) { throw 'GuestPrepare recovery requires the exact existing owned resource group.' }
    $command=Get-DemoArmRecord "https://management.azure.com$($Journal.resources.vmId)/runCommands/demo2-field-setup?api-version=2024-07-01&`$expand=instanceView" @('ResourceNotFound')
    if ($null -eq $command) { throw 'Failed GuestPrepare command is not observable; no recovery or source migration attempted.' }
    Assert-DemoManagedCommand $Journal $command $intent.operationId $digest
    $failure=Get-DemoGuestFailureSummary $command
    if ($failure.provisioningState -cne 'Succeeded' -or $failure.executionState -cne 'Failed' -or $failure.exitCode -ne 1 -or $failure.category -cne 'AptSourceConflict') {
        throw 'Only the terminal, correlated Signed-By conflict is recoverable by this patch. Active, unknown or different guest failures retain pending intent.'
    }
    $remote="/var/lib/demo2-setup/$($Journal.installationId)/kit/host/Prepare-FieldHost.sh"
    $bytes=[Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $script:Kit 'host\Prepare-FieldHost.sh')).Replace("`r`n","`n"))
    $patch=Get-DemoPublicUploadScript $remote $bytes
    $Journal.guestPrepareRecovery=@{failedIntent=$intent.Clone();failure=$failure;verifiedUtc=[datetimeoffset]::UtcNow.ToString('o')
        patchDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($patch)))}
    $Journal.pendingAgent=$null
    $Journal.sourceFingerprint=$CurrentFingerprint
    Save-DemoJournal $Journal $JournalPath
    Write-Host 'Archived the exact failed repository operation. Recovery installs only the reviewed host patch; retry requires the existing matching custody disk and mount and cannot format a disk.'
}

function Wait-DemoManagedCommand {
    param([hashtable]$Journal,[string]$Operation,[string]$Digest,[ValidateRange(1,2100)][int]$ObservationTimeoutSeconds=2100)
    $uri="https://management.azure.com$($Journal.resources.vmId)/runCommands/demo2-field-setup?api-version=2024-07-01&`$expand=instanceView"
    $deadline=(Get-Date).ToUniversalTime().AddSeconds($ObservationTimeoutSeconds)
    do {
        $command=Get-DemoArmRecord $uri @('ResourceNotFound')
        if ($null -eq $command) { throw 'Pending managed command is not observable. Intent retained; no resubmission. Reconcile exact resource/history.' }
        Assert-DemoManagedCommand $Journal $command $Operation $Digest
        $result=Read-DemoManagedResult $command $Operation
        if ($null -ne $result) { return $result }
        if ((Get-Date).ToUniversalTime() -ge $deadline) { throw 'Agent observation expired; pending operation retained for reconciliation, not resubmitted.' }
        Start-Sleep -Seconds 5
    } while ($true)
}

function Invoke-DemoAgentScript {
    param([hashtable]$Journal,[string]$JournalPath,[string]$Script,[ValidateRange(1,2100)][int]$ObservationTimeoutSeconds=2100)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Script)))
    $vmId=$Journal.resources.vmId
    $uri="https://management.azure.com$vmId/runCommands/demo2-field-setup?api-version=2024-07-01"
    if ($Journal.pendingAgent) {
        $intent=$Journal.pendingAgent
        if ($intent -isnot [hashtable] -or [string]$intent['operationId'] -notmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
            [string]$intent['digest'] -notmatch '^[a-fA-F0-9]{64}$') { throw 'Unknown pending command intent. Preserve it for explicit reconciliation; no submission allowed.' }
        if ($intent.digest -ne $hash) { throw 'An earlier agent operation is unresolved. Repeat the same setup stage; do not overwrite an in-flight command.' }
        $operation=$Journal.pendingAgent.operationId
    } else {
        $existing=Get-DemoArmRecord ($uri+'&$expand=instanceView') @('ResourceNotFound')
        if ($null -ne $existing) {
            if ($existing['tags'] -isnot [Collections.IDictionary]) { throw 'An existing managed command has unknown intent/tags. No command overwritten.' }
            $recovery=$Journal['guestPrepareRecovery']
            if ($recovery -and $existing.tags['operationId'] -ceq $recovery.failedIntent.operationId) {
                Assert-DemoManagedCommand $Journal $existing $recovery.failedIntent.operationId $recovery.failedIntent.digest
                $failure=Get-DemoGuestFailureSummary $existing
                if ($hash -cne $recovery.patchDigest -or $failure.executionState -cne 'Failed' -or $failure.exitCode -ne 1 -or
                    $failure.provisioningState -cne 'Succeeded' -or $failure.category -cne 'AptSourceConflict') {
                    throw 'Reconciled failure can be replaced only by the exact reviewed public host-patch upload; no other command permitted.'
                }
            } else {
                $previous=@($Journal['agentTimings'] | Where-Object { $_ -is [Collections.IDictionary] -and $_['operationId'] -ceq $existing.tags['operationId'] })
                if ($previous.Count -ne 1) { throw 'An existing managed command has unknown intent. Reconcile it before a new submission; no command overwritten.' }
                Assert-DemoManagedCommand $Journal $existing $previous[0].operationId $previous[0].sourceDigest
                $previousResult=Read-DemoManagedResult $existing $previous[0].operationId
                if ($null -eq $previousResult) {
                    throw 'An existing managed command is active/unknown. No new submission is permitted.'
                }
            }
        }
        $operation=[guid]::NewGuid().ToString('D')
        $Journal.pendingAgent=@{operationId=$operation;digest=$hash;startedUtc=[datetimeoffset]::UtcNow.ToString('o')}
        Save-DemoJournal $Journal $JournalPath
        $body=@{location=$Journal.config.location;tags=@{installationId=$Journal.installationId;operationId=$operation;payloadDigest=$hash}
            properties=@{source=@{script=$Script.Replace('__OPERATION_ID__',$operation)};asyncExecution=$true;timeoutInSeconds=1800;treatFailureAsDeploymentFailure=$true}}
        $file=Join-Path (Split-Path $JournalPath) 'agent-request.local.json'
        try {
            $body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file
            $null=Invoke-AzJson @('rest','--method','put','--url',$uri,'--body',"@$file")
        } finally { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
    }
    $result=Wait-DemoManagedCommand $Journal $operation $hash -ObservationTimeoutSeconds $ObservationTimeoutSeconds
    if (-not $Journal.ContainsKey('agentTimings')) { $Journal.agentTimings=@() }
    $finished=[datetimeoffset]::UtcNow
    $started=$Journal.pendingAgent['startedUtc']
    $Journal.agentTimings += @{operationId=$operation;sourceDigest=$hash;startedUtc=$started;completedUtc=$finished.ToString('o')
        observedSeconds=$(if ($started) { ($finished-[datetimeoffset]::Parse($started)).TotalSeconds } else { $null })}
    $Journal.pendingAgent=$null
    Save-DemoJournal $Journal $JournalPath
    return $result
}

function Get-DemoPublicUploadScript {
    param([string]$RemotePath,[byte[]]$Bytes)
    if ($RemotePath -notmatch '^/var/lib/demo2-setup/[a-f0-9]{32}/[a-zA-Z0-9/._-]+$' -or $RemotePath.Contains('..')) { throw 'Invalid public artifact destination.' }
    $encoded=[Convert]::ToBase64String($Bytes)
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    $parent=$RemotePath.Substring(0,$RemotePath.LastIndexOf('/'))
    return "set -eu`numask 077`ninstall -d -m 0700 '$parent'`nprintf '%s' '$encoded' | base64 -d > '$RemotePath.tmp'`nprintf '%s  %s\n' '$digest' '$RemotePath.tmp' | sha256sum --check --status`nchmod 0600 '$RemotePath.tmp'`nmv '$RemotePath.tmp' '$RemotePath'`nprintf '%s\n' '{`"operationId`":`"__OPERATION_ID__`",`"ok`":true}'"
}

function Get-DemoPublicUploadOrder {
    param([object[]]$Assets,[object]$Pending)
    if (-not $Pending) { return $Assets }
    if ($Pending -isnot [Collections.IDictionary] -or [string]$Pending['digest'] -notmatch '^[a-fA-F0-9]{64}$') { throw 'Unknown pending public upload intent; preserve it for reconciliation.' }
    $matches=@($Assets | Where-Object {
        $template=Get-DemoPublicUploadScript $_.remotePath $_.bytes
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($template))) -ieq $Pending.digest
    })
    if ($matches.Count -ne 1) { throw 'Pending public upload does not match exactly one current planned artifact. Preserve intent and source; no different upload or regeneration attempted.' }
    $matches[0]
    $Assets | Where-Object remotePath -CNE $matches[0].remotePath
}

function Send-DemoPublicFile {
    param([hashtable]$Journal,[string]$JournalPath,[string]$RemotePath,[byte[]]$Bytes)
    if ($RemotePath -notmatch '^/var/lib/demo2-setup/[a-f0-9]{32}/[a-zA-Z0-9/._-]+$' -or $RemotePath.Contains('..')) { throw 'Invalid public artifact destination.' }
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    if (-not $Journal.ContainsKey('publicUploads')) { $Journal.publicUploads=@{} }
    if ($Journal.publicUploads.ContainsKey($RemotePath) -and $Journal.publicUploads[$RemotePath] -eq $digest) { return }
    # This channel carries reviewed source, config identifiers and public certificates only.
    $script=Get-DemoPublicUploadScript $RemotePath $Bytes
    $null=Invoke-DemoAgentScript $Journal $JournalPath $script
    $Journal.publicUploads[$RemotePath]=$digest
    Save-DemoJournal $Journal $JournalPath
}

function Invoke-DemoGuestStage {
    param([hashtable]$Journal,[string]$JournalPath,[string]$Action,[int]$Chunk=0)
    $remote="/var/lib/demo2-setup/$($Journal.installationId)"
    $script="umask 077`n/usr/bin/pwsh -NoProfile -NonInteractive -File $remote/kit/host/Invoke-SetupStage.ps1 -InstallationId $($Journal.installationId) -OperationId __OPERATION_ID__ -Action $Action -Chunk $Chunk"
    $response=Invoke-DemoAgentScript $Journal $JournalPath $script
    if ($response.installationId -ne $Journal.installationId -or $response.action -ne $Action) { throw 'Guest stage correlation failed.' }
    return $response.result
}

function Receive-DemoEnvelope {
    param([hashtable]$Info,[scriptblock]$ReadChunk)
    if ($Info.bytes -lt 1 -or $Info.bytes -gt 1000000 -or $Info.chunks -ne [int][math]::Ceiling($Info.bytes/1200.0) -or $Info.digest -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid encrypted envelope metadata.' }
    $memory=[IO.MemoryStream]::new()
    try {
        for ($i=0; $i -lt $Info.chunks; $i++) {
            $part=& $ReadChunk $i
            if ($part.index -ne $i -or $part.bytes -ne $Info.bytes) { throw 'Encrypted envelope chunk replay/reorder/length mismatch.' }
            $bytes=[Convert]::FromBase64String($part.data)
            if ($bytes.Length -ne [math]::Min(1200,$Info.bytes-$memory.Length)) { throw 'Encrypted envelope chunk truncated.' }
            $memory.Write($bytes)
        }
        $result=$memory.ToArray()
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($result)) -ne $Info.digest) { throw 'Encrypted envelope digest mismatch.' }
        return ,$result
    } finally { $memory.Dispose() }
}

function Invoke-DemoSetup {
    [CmdletBinding()]
    param([string]$Mode='Setup',[string]$InstallPath,[switch]$AuthorizeLiveChanges)
    if ($Mode -eq 'Plan') {
        return [pscustomobject]@{Mode='OfflinePlan';Architecture='Managed HSM + confidential Linux VM + private Live/Twin storage';Next='Setup creates billed resources and activates a new HSM; prompts collect required target, network, budget and encrypted-custody values only. Rehearse runs real policy/key tests; Run opens deliberate operator controls. No Azure operations performed by Plan.'}
    }
    if (-not $IsWindows) { throw 'Field entry point currently supports Windows PowerShell 7.4+; use pwsh, not Windows PowerShell 5.' }
    if (-not $InstallPath) {
        if ($Mode -ne 'Setup') { throw 'Specify -InstallPath for an existing installation; no implicit current environment.' }
        $id=[guid]::NewGuid().ToString('N')
        $repo=[IO.Path]::GetFullPath((Join-Path $script:Kit '..\..'))
        $ignore=Join-Path $repo '.gitignore'
        if (-not (Test-Path $ignore) -or (Get-Content $ignore) -notcontains '/.private/demo2/') {
            Write-Host 'Adding /.private/demo2/ to .gitignore before creating private installation data.'
            Add-Content -LiteralPath $ignore -Value "`n/.private/demo2/"
        }
        $InstallPath=Join-Path $repo ".private\demo2\installs\$id"
        $tracked=@(& git -C $repo ls-files -- .private/demo2)
        if ($LASTEXITCODE -ne 0 -or $tracked.Count) { throw 'Private root has tracked files or is not in a normal Git checkout.' }
        & git -C $repo check-ignore --no-index -q -- ".private/demo2/installs/$id/install.json"
        if ($LASTEXITCODE -ne 0) { throw 'Install state is not ignored.' }
        New-DemoPrivateDirectory $InstallPath
    }
    Assert-DemoPrivatePath $InstallPath
    Assert-DemoInstallPrivacy $InstallPath
    $InstallPath=[IO.Path]::GetFullPath($InstallPath)
    $journalPath=Join-Path $InstallPath 'install.json'
    Write-Host "Installation path: $InstallPath"
    $lock=$null; $custodyPassword=$null; $stage='Journal'
    try {
        $lock=[IO.File]::Open((Join-Path $InstallPath '.setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if (Test-Path $journalPath) {
            $journal=Get-Content $journalPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-DemoJournal $journal
        } else {
            if ($Mode -ne 'Setup') { throw 'Installation journal not found.' }
            if (@(Get-ChildItem -LiteralPath $InstallPath -Force | Where-Object Name -ne '.setup.lock').Count) { throw 'Unjournaled private files exist; reconcile custody rather than regenerating.' }
            $config=New-DemoFieldConfig
            foreach ($name in 'admin','operator') {
                & ssh-keygen -q -t ed25519 -N '' -f (Join-Path $InstallPath $name) -C "demo2-$($config.nameSuffix)-$name"
                if ($LASTEXITCODE -ne 0) { throw 'Fresh SSH generation failed.' }
                Protect-DemoPrivateFile (Join-Path $InstallPath $name)
                Protect-DemoPrivateFile (Join-Path $InstallPath "$name.pub")
            }
            $config.sshPublicKey=(Get-Content (Join-Path $InstallPath 'admin.pub') -Raw).Trim()
            $config.sshIdentityFile=Join-Path $InstallPath 'operator'; $config.sshUser='demooperator'
            $journal=@{schemaVersion=1;installationId=([guid]::NewGuid().ToString('N'));config=$config;configFingerprint=(Get-DemoConfigFingerprint $config)
                sourceFingerprint=(Get-DemoSourceFingerprint);receipts=@{};resources=@{};pendingAgent=$null;status='Preparing';createdUtc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        if ($Mode -eq 'RetirementPlan') {
            return [pscustomobject]@{Installation=$journal.installationId;Scope=$journal.config.resourceGroup;Mode='ReadOnlyGuidance';Steps=@('Authorize live inspection and restore both pinned keys; verify fresh reads and Closed runs.','Verify custody AND any required full-HSM backup; retain offline copies.','Inventory and review dedicated resources, retained disk, policy definitions and costs.','Separately authorize any resource deletion. HSM retains full billing during protected retention; no automatic purge/cleanup.')}
        }
        if ($Mode -eq 'Status') {
            return [pscustomobject]@{Mode='LocalJournalOnly';Status=$journal.status;Stages=@($journal.receipts.get_Keys());DemoReady=$false;Next="Use Setup -InstallPath '$InstallPath' to reconcile Azure/guest state. Journal is not live readiness."}
        }
        $stage='SourceReconciliation'
        Update-DemoLocalPromptSource $journal $journalPath $Mode
        $config=$journal.config
        Write-Host "Target: tenant $($config.tenantId); subscription $($config.subscriptionId); region $($config.location); group $($config.resourceGroup). Mode: $Mode; status: $($journal.status)."
        $configPath=Join-Path $InstallPath 'config.local.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
        $null=Import-DemoConfig $configPath -Phase Foundation
        $stage='TargetContext'
        Assert-DemoAzureContext $config
        if ($Mode -in 'Run','Rehearse') {
            if ($journal.status -ne 'ConfiguredNeedsRehearsal') { throw 'Setup has not finished all configuration/privilege-reduction stages.' }
            Invoke-DemoFieldRun -Journal $journal -InstallPath $InstallPath -Mode $Mode
            return
        }
        if ($Mode -ne 'Setup') { throw 'Live Status is performed by Setup reconciliation; plain Status never mutates Azure.' }
        if (-not $journal.receipts.ContainsKey('Custody')) {
            $stage='Custody'
            Write-Host 'Demo-only single-operator 3-of-4 custody. Keep the passphrase separate and retain recovery copies independently; software cannot prove physical/offline custody.'
            $custodyPassword=Initialize-DemoFieldCustody $InstallPath $journal.installationId
            $journal.receipts.Custody=@{verifiedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        $stage='ResourceOwnership'
        $exists=Assert-DemoInstallOwner $journal
        if (-not $journal.receipts.ContainsKey('Foundation')) {
            $stage='FoundationPreflight'
            if ($null -eq $custodyPassword) { $custodyPassword=Read-DemoCustodyPassphrase $InstallPath }
            Test-DemoCustodyBackup $InstallPath $custodyPassword
            if (-not $exists) {
                Test-DemoFieldPreflight $config $configPath
                $journal.configFingerprint=Get-DemoConfigFingerprint $config
                Save-DemoJournal $journal $journalPath
                $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
            }
            Write-Host "Cost notice: HSM bills continuously, even unactivated, and throughout protected $($config.hsmRetentionDays)-day deletion retention. CVM, Bastion, disk/network/storage/Monitor also bill. Budget $($config.budgetAmount) is a notification threshold, not a price or spending cap; review current regional pricing separately."
            $template=Join-Path $script:Kit 'infra\main.bicep'
            $preview=@('deployment','sub','what-if','--name',"demo2-$($journal.installationId)",'--no-pretty-print','--validation-level','Provider','--subscription',$config.subscriptionId,'--location',$config.location,'--template-file',$template,
                '--parameters',"config=@$configPath",'stage=foundation',"installationId=$($journal.installationId)",'bootstrapEnabled=true')
            $stage='FoundationPreview'
            $whatIf=Invoke-AzJson $preview
            if ($whatIf.status -ne 'Succeeded') { throw 'Foundation provider what-if did not succeed; no provisioning attempted.' }
            $whatIf | ConvertTo-Json -Depth 40 | Write-Host
            Write-Host 'Setup is provisioning billed isolated resources, scoped policies, private endpoints and a new blank custody disk; guest setup formats only its verified new disk and uses temporary bootstrap grants. Existing environments must not be replaced.'
            $stage='FoundationCreate'
            $deployment=Invoke-AzJson @('deployment','sub','create','--name',"demo2-$($journal.installationId)",'--subscription',$config.subscriptionId,'--location',$config.location,
                '--template-file',$template,'--parameters',"config=@$configPath",'stage=foundation',"installationId=$($journal.installationId)",'bootstrapEnabled=true')
            if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Foundation deployment failed; retain resources and resume after inspecting its actual errors.' }
            $journal.resources=$deployment.properties.outputs.foundationResources.value
            foreach ($name in 'controllerIdentityClientId','controllerPrincipalId','liveStorageIdentityPrincipalId','twinStorageIdentityPrincipalId') { $config[$name]=$journal.resources[$name] }
            $journal.receipts.Foundation=@{deployment=$deployment.id;utc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        foreach ($name in 'controllerIdentityClientId','controllerPrincipalId','liveStorageIdentityPrincipalId','twinStorageIdentityPrincipalId') { $config[$name]=$journal.resources[$name] }
        $stage='FoundationOwnership'
        [void](Assert-DemoInstallOwner $journal)
        $remote="/var/lib/demo2-setup/$($journal.installationId)"
        if ($journal['guestPrepareRecovery'] -and -not $journal.receipts.ContainsKey('Guest')) {
            $stage='GuestPrepareRecoveryPatch'
            $bytes=[Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $script:Kit 'host\Prepare-FieldHost.sh')).Replace("`r`n","`n"))
            Send-DemoPublicFile $journal $journalPath "$remote/kit/host/Prepare-FieldHost.sh" $bytes
        }
        if (-not $journal.receipts.ContainsKey('PublicPayload')) {
            $stage='PublicPayload'
            $files = foreach ($relative in @('config.schema.json','content\sovereignty-demo.txt',
                'host\Prepare-FieldHost.sh','host\Invoke-SetupStage.ps1','host\Demo.Worker.psm1',
                'host\Start-Watchdog.ps1','host\Submit-Request.ps1','scripts\Demo.Common.psm1',
                'scripts\Initialize-Hsm.ps1','scripts\Initialize-Content.ps1','scripts\Install-Watchdog.ps1')) {
                Get-Item -LiteralPath (Join-Path $script:Kit $relative)
            }
            $assets=@(foreach ($file in $files) {
                $relative=$file.FullName.Substring($script:Kit.Length+1).Replace('\','/')
                $text=[IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n")
                @{remotePath="$remote/kit/$relative";bytes=[Text.Encoding]::UTF8.GetBytes($text)}
            })
            foreach ($name in @('operator.pub','wrapping-01.cer','wrapping-02.cer','wrapping-03.cer','wrapping-04.cer','recipient.cer')) {
                $assets+=@{remotePath="$remote/$name";bytes=[IO.File]::ReadAllBytes((Join-Path $InstallPath $name))}
            }
            $metadata=@{installationId=$journal.installationId;bootstrapClientId=$journal.resources.bootstrapClientId;bootstrapPrincipalId=$journal.resources.bootstrapPrincipalId}
            $assets+=@{remotePath="$remote/setup.json";bytes=[Text.Encoding]::UTF8.GetBytes(($metadata|ConvertTo-Json))}
            foreach ($asset in @(Get-DemoPublicUploadOrder $assets $journal.pendingAgent)) {
                $stage='PublicPayload/'+$asset.remotePath.Substring($remote.Length+1)
                Send-DemoPublicFile $journal $journalPath $asset.remotePath $asset.bytes
            }
            $journal.receipts.PublicPayload=@{digest=$journal.sourceFingerprint}; Save-DemoJournal $journal $journalPath
        }
        $guestConfig=$config.Clone()
        $guestConfig.sshIdentityFile=''
        $stage='GuestConfig'
        Send-DemoPublicFile $journal $journalPath "$remote/config.json" ([Text.Encoding]::UTF8.GetBytes(($guestConfig|ConvertTo-Json -Depth 30)))
        if (-not $journal.receipts.ContainsKey('Guest')) {
            $stage='GuestPrepare'
            $script=Get-DemoGuestPrepareScript $journal
            $null=Invoke-DemoAgentScript $journal $journalPath $script
            $stage='GuestInspect'
            $journal.receipts.Guest=Invoke-DemoGuestStage $journal $journalPath Inspect
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('DomainBackup')) {
            $stage='DomainBackup'
            if (-not $journal.receipts.ContainsKey('DomainActivated')) {
                $stage='DomainActivate'
                Write-Host "Activating dedicated HSM $($config.hsmName) using this installation's public wrapping certificates (quorum 3). Wrapping private keys stay local."
                $journal.receipts.DomainActivated=Invoke-DemoGuestStage $journal $journalPath Activate
                Save-DemoJournal $journal $journalPath
            }
            $info=$journal.receipts.DomainActivated
            if (-not $journal.ContainsKey('domainChunks')) { $journal.domainChunks=@{} }
            $bytes=Receive-DemoEnvelope $info {
                param($index)
                $key="$index"
                if (-not $journal.domainChunks.ContainsKey($key)) {
                    $stage="DomainChunk/$index"
                    $journal.domainChunks[$key]=Invoke-DemoGuestStage $journal $journalPath DomainChunk $index
                    Save-DemoJournal $journal $journalPath
                }
                return $journal.domainChunks[$key]
            }
            $envelope=Join-Path $InstallPath 'security-domain.cms'
            [IO.File]::WriteAllBytes($envelope,$bytes)
            if ($null -eq $custodyPassword) { $custodyPassword=Read-DemoCustodyPassphrase $InstallPath }
            Test-DemoCustodyBackup $InstallPath $custodyPassword
            Test-DemoDomainEnvelope $InstallPath $custodyPassword $envelope
            $custody=Get-Content (Join-Path $InstallPath 'custody.json') -Raw | ConvertFrom-Json -AsHashtable
            $backup=Join-Path (Split-Path $custody.backupFile) "$($journal.installationId)-security-domain.cms"
            [IO.File]::WriteAllBytes($backup,$bytes); Assert-DemoPrivatePath $backup
            if ((Get-FileHash $backup).Hash -ne (Get-FileHash $envelope).Hash) { throw 'Encrypted domain backup copy mismatch.' }
            Write-Host 'Encrypted domain readability and backup-copy integrity verified. Retain the PFX and domain backups independently and the passphrase separately; folder separation does not prove offline custody.'
            $journal.receipts.DomainBackup=@{digest=$info.digest;path=$backup;hsmName=$config.hsmName}
            Save-DemoJournal $journal $journalPath
        }
        $stage='DomainBackupReceipt'
        Send-DemoPublicFile $journal $journalPath "$remote/domain-backup-verified.json" ([Text.Encoding]::UTF8.GetBytes(($journal.receipts.DomainBackup|ConvertTo-Json)))
        if (-not $journal.receipts.ContainsKey('Keys')) {
            $stage='Keys'
            if ($null -eq $custodyPassword) { $custodyPassword=Read-DemoCustodyPassphrase $InstallPath }
            Test-DemoCustodyBackup $InstallPath $custodyPassword
            $domainBackup=$journal.receipts.DomainBackup.path
            if (-not (Test-Path -LiteralPath $domainBackup -PathType Leaf -ErrorAction Stop)) {
                throw "Security-domain backup is unavailable at '$domainBackup'. Reconnect/restore that verified copy before creating CMKs; custody-package recovery does not recreate a security-domain backup."
            }
            Assert-DemoPrivatePath $domainBackup
            if ((Get-FileHash -LiteralPath $domainBackup).Hash -cne (Get-FileHash -LiteralPath (Join-Path $InstallPath 'security-domain.cms')).Hash) { throw 'Security-domain backup differs from the retained envelope. Preserve both; no CMKs created.' }
            Test-DemoDomainEnvelope $InstallPath $custodyPassword $domainBackup
            $keys=Invoke-DemoGuestStage $journal $journalPath Keys
            $config.targets=$keys.targets
            $journal.receipts.Keys=$keys
            Save-DemoJournal $journal $journalPath
        }
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath
        if (-not $journal.receipts.ContainsKey('Storage')) {
            $stage='StoragePreview'
            $template=Join-Path $script:Kit 'infra\main.bicep'
            $arguments=@('--subscription',$config.subscriptionId,'--location',$config.location,'--template-file',$template,
                '--parameters',"config=@$configPath",'stage=storage',"installationId=$($journal.installationId)")
            $preview=Invoke-AzJson (@('deployment','sub','what-if','--name',"demo2-storage-$($journal.installationId)",'--no-pretty-print','--validation-level','Provider')+$arguments)
            if ($preview.status -ne 'Succeeded') { throw 'Storage provider what-if did not succeed; no storage creation attempted.' }
            $preview | ConvertTo-Json -Depth 40 | Write-Host
            $stage='StorageCreate'
            $deployment=Invoke-AzJson (@('deployment','sub','create','--name',"demo2-storage-$($journal.installationId)")+$arguments)
            if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Storage deployment failed; no readiness implied.' }
            $journal.receipts.Storage=@{deployment=$deployment.id}
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('Content')) {
            $stage='ContentRoles'
            foreach ($target in 'Live','Twin') {
                $scope="/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($config.targets[$target].accountName)"
                if (-not $journal.receipts.ContainsKey("UploadRole$target")) {
                    $roleName=[guid]::new([byte[]]([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($journal.installationId)-upload-$target"))[0..15])).ToString()
                    $role=Invoke-AzJson @('role','assignment','create','--name',$roleName,'--assignee-object-id',$journal.resources.bootstrapPrincipalId,'--assignee-principal-type','ServicePrincipal',
                        '--role','Storage Blob Data Contributor','--scope',$scope)
                    $journal.receipts["UploadRole$target"]=@{id=$role.id}
                }
                Save-DemoJournal $journal $journalPath
            }
            $stage='Content'
            $journal.receipts.Content=Invoke-DemoGuestStage $journal $journalPath Content
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('Worker')) {
            $stage='Worker'
            $journal.receipts.Worker=Invoke-DemoGuestStage $journal $journalPath Worker
            Save-DemoJournal $journal $journalPath
        }
        if (-not $journal.receipts.ContainsKey('Reduced')) {
            $stage='PrivilegeReduction'
            $null=Invoke-DemoGuestStage $journal $journalPath Reduce
            foreach ($target in 'Live','Twin') {
                $null=Invoke-AzJson @('role','assignment','delete','--ids',$journal.receipts["UploadRole$target"].id)
            }
            $null=Invoke-AzJson @('vm','identity','remove','--ids',$journal.resources.vmId,'--identities',$journal.resources.bootstrapIdentityId)
            $null=Invoke-AzJson @('role','assignment','delete','--ids',$journal.resources.bootstrapReaderAssignmentId)
            $vm=Invoke-AzJson @('vm','show','--ids',$journal.resources.vmId)
            if ($vm.identity.userAssignedIdentities.ContainsKey($journal.resources.bootstrapIdentityId)) { throw 'Bootstrap identity is still attached.' }
            $left=@(Invoke-AzJson @('role','assignment','list','--scope',"/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroup)",'--all') |
                Where-Object principalId -eq $journal.resources.bootstrapPrincipalId)
            if ($left.Count) { throw 'Temporary bootstrap ARM grants remain; resume reduction before readiness.' }
            $journal.receipts.Reduced=@{verifiedUtc=[datetimeoffset]::UtcNow.ToString('o')}
            Save-DemoJournal $journal $journalPath
        }
        $stage='Baseline'
        $journal.receipts.Baseline=Invoke-DemoGuestStage $journal $journalPath Status
        $journal.status='ConfiguredNeedsRehearsal'
        Save-DemoJournal $journal $journalPath
        Write-Output "Configured, NOT demo-ready: $InstallPath. Next: -Mode Rehearse -InstallPath '$InstallPath' runs real policy tests and a bounded demo-key outage. Independent failure/alert/twin tests remain mandatory."
    } catch {
        $failure=$_
        if ($failure.Exception.Data.Contains('AzureCliExitCode') -or $failure.Exception.Data.Contains('GuestFailure')) {
            try { Write-Host "Protected sanitized diagnostic: $(Save-DemoSetupDiagnostic $failure $InstallPath $stage)" }
            catch { Write-Warning 'Diagnostic persistence failed; original CLI failure/intent retained. Check installation ACL/disk access; no raw output logged.' }
        }
        Write-Error "Setup/lifecycle stopped at $stage`: $($failure.Exception.Message) Resume path: $InstallPath. Resources and custody are preserved; no automatic deletion." -ErrorAction Continue
        throw
    } finally {
        if ($null -ne $custodyPassword) { $custodyPassword.Dispose() }
        if ($lock) { $lock.Dispose() }
    }
}

function Invoke-DemoFieldRun {
    param([hashtable]$Journal,[string]$InstallPath,[string]$Mode)
    $config=$Journal.config
    $port=[int]$config.sshPort
    if (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count) { throw 'Tunnel port already occupied; no unknown helper will be reused or stopped.' }
    $known=Join-Path $InstallPath 'known_hosts'
    $hostKey=$Journal.receipts.Guest.hostKey
    if ($hostKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Missing authenticated per-install host key; never disable host verification.' }
    "[127.0.0.1]:$port $hostKey" | Set-Content $known -Encoding ascii
    $info=[Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.Arguments="/d /s /c `"az network bastion tunnel --name demo2-$($config.nameSuffix)-bastion --resource-group $($config.resourceGroup) --subscription $($config.subscriptionId) --target-resource-id $($Journal.resources.vmId) --resource-port 22 --port $port`""
    $process=[Diagnostics.Process]::Start($info)
    $previousKnownHosts=$env:DEMO2_KNOWN_HOSTS
    try {
        $deadline=[datetimeoffset]::UtcNow.AddSeconds(120)
        do {
            Start-Sleep -Seconds 2
            if ($process.HasExited) { throw 'Bastion helper exited; operator route is blocked.' }
            $ready=@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0
        } until ($ready -or [datetimeoffset]::UtcNow -gt $deadline)
        if (-not $ready) { throw 'Bastion listener not ready.' }
        $env:DEMO2_KNOWN_HOSTS=$known
        $path=Join-Path $InstallPath 'config.local.json'
        $baseline=& (Join-Path $PSScriptRoot 'Invoke-DemoControl.ps1') -ConfigPath $path -Action Read -Target Live -RunId ([guid]::NewGuid())
        if ($baseline.read.status -ne 200) { throw 'Fresh Live read failed through the pinned restricted operator path; stage is not ready.' }
        if ($Mode -eq 'Rehearse') {
            Write-Host 'Rehearse runs real policy probes and bounded key disable/restore after independent recovery is armed. Positive control can create another billable private account. Propagation is not guaranteed; no automatic cleanup.'
            foreach ($example in 'positive','denied-region','platform-key') { & (Join-Path $PSScriptRoot 'Test-PolicyExamples.ps1') -ConfigPath $path -Example $example -AuthorizeLiveChanges -PolicyReviewConfirmed -Confirm:$false }
            & (Join-Path $PSScriptRoot 'Invoke-LiveRehearsal.ps1') -ConfigPath $path -EvidenceDirectory (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "BRK439\demo2-evidence\$($Journal.installationId)") -AuthorizeLiveChanges
            Write-Output 'Normal rehearsal completed only. Independent crash/reboot, manual recovery, alert delivery and finite Twin preparation remain separate gates; no universal DemoReady flag is set.'
        } else {
            & (Join-Path $PSScriptRoot 'Show-ControlPanel.ps1') -ConfigPath $path -AuthorizeLiveChanges
        }
    } finally {
        if ($null -ne $previousKnownHosts) { $env:DEMO2_KNOWN_HOSTS=$previousKnownHosts }
        else { Remove-Item Env:\DEMO2_KNOWN_HOSTS -ErrorAction SilentlyContinue }
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

Export-ModuleMember -Function Invoke-DemoSetup, Save-DemoJournal, Assert-DemoJournal, Get-DemoConfigFingerprint, Receive-DemoEnvelope
