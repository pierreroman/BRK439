Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DemoPrivatePath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { throw 'Field custody currently requires Windows with PowerShell 7.4+.' }
    $item = Get-Item -LiteralPath $Path -Force
    for ($parent = $item; $null -ne $parent;) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw [ArgumentException]::new('Private paths must not traverse reparse points.') }
        $parent = if ($parent -is [IO.FileInfo]) { $parent.Directory } else { $parent.Parent }
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $rules = @($acl.Access)
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or
        $rules.Count -ne 1 -or $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or
        $rules[0].AccessControlType -ne 'Allow' -or
        ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
        throw [ArgumentException]::new("Private path requires current-user-only FullControl: $Path")
    }
}

function New-DemoPrivateDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { throw 'Field setup requires Windows.' }
    if (Test-Path -LiteralPath $Path) { Assert-DemoPrivatePath $Path; return }
    $parent = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-DemoPrivateDirectory $parent }
    if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked private parent.' }
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-DemoPrivatePath $Path
}

function Protect-DemoPrivateFile {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo] -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Expected a newly generated, nonlinked private file.' }
    Assert-DemoPrivatePath $item.DirectoryName
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $current = Get-Acl -LiteralPath $Path
    if ($current.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { throw 'Generated file owner is not the current user.' }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'))
    [IO.FileSystemAclExtensions]::SetAccessControl($item,$acl)
    Assert-DemoPrivatePath $Path
}

function ConvertFrom-DemoSecureString {
    param([Parameter(Mandatory)][securestring]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-DemoBackupPathError {
    param([string]$Path,[string]$Directory,[string]$InstallationId,[switch]$Resume,[string]$ArchiveName,[switch]$Recovery)
    if ($InstallationId -notmatch '^[a-f0-9]{32}$') { throw [ArgumentException]::new('Backup validation requires the exact installation GUID; do not guess a custody scope.') }
    if (-not $ArchiveName) { $ArchiveName="$InstallationId-custody.pfx" }
    if ($ArchiveName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._ -]*\.pfx$' -or $ArchiveName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\.' -or $ArchiveName.Length -gt 255) {
        return 'Choose an ordinary .pfx filename without links, reserved names, alternate streams or path separators.'
    }
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[*?"/<>|\x00-\x1f]' -or $Path.Substring(2).Contains(':')) {
        return 'Use a fully qualified local/removable-drive directory, for example E:\Demo2-Recovery\this-install. No wildcards, alternate streams, relative paths or provider paths.'
    }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { return 'A drive/filesystem root is not a backup directory. Choose a dedicated subdirectory, for example E:\Demo2-Recovery\this-install; root permissions will not be changed.' }
    foreach ($segment in $Path.Substring(3).TrimEnd('\').Split('\')) {
        if ($segment -in '.','..' -or $segment -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { return 'Use ordinary directory names without dot segments, trailing dots/spaces or Windows reserved device names.' }
    }
    $local=[IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if ($full -eq $local -or $full.StartsWith("$local\",[StringComparison]::OrdinalIgnoreCase) -or $local.StartsWith("$full\",[StringComparison]::OrdinalIgnoreCase)) {
        return 'Backup must be separate from the installation: not the installation, a child, or an ancestor of it.'
    }
    try {
        $nearest=$full
        while (-not (Test-Path -LiteralPath $nearest)) {
            $parent=Split-Path $nearest -Parent
            if (-not $parent -or $parent -eq $nearest) { return 'The backup drive is unavailable. Mount/unlock your approved drive and choose a dedicated directory.' }
            $nearest=$parent
        }
        for ($parent=Get-Item -LiteralPath $nearest -Force; $null -ne $parent; $parent=$parent.Parent) {
            if ($parent -isnot [IO.DirectoryInfo]) { return 'Choose a directory, not an existing file.' }
            if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'Backup paths must not traverse symlinks, junctions or other reparse points.' }
            if (Test-Path -LiteralPath (Join-Path $parent.FullName '.git')) { return 'Independent recovery backups must be outside every Git checkout, including ignored/private repository folders.' }
        }
        if (Test-Path -LiteralPath $full) {
            try { Assert-DemoPrivatePath $full }
            catch [ArgumentException] { return 'Existing backup directory must already have current-user-only FullControl and no reparse points. Choose a NEW dedicated directory instead; existing folder permissions will not be tightened.' }
            $allowed=if ($Resume) { @($ArchiveName) + $(if ($Recovery) { @("$InstallationId-security-domain.cms") } else { @() }) } else { @() }
            if (@(Get-ChildItem -LiteralPath $full -Force | Where-Object Name -notin $allowed).Count) { return 'Backup directory is not empty or contains conflicting files. Choose a separate dedicated empty/new directory; nothing will be overwritten.' }
            $archive=Join-Path $full $ArchiveName
            $local=Join-Path $Directory 'custody.pfx'
            if (-not (Test-Path -LiteralPath $local)) { $local=Join-Path $Directory 'custody.pfx.pending' }
            if ($Resume -and (Test-Path -LiteralPath $archive) -and (Test-Path -LiteralPath $local)) {
                Assert-DemoPrivatePath $archive
                Assert-DemoPrivatePath $local
                if ((Get-FileHash -LiteralPath $archive).Hash -cne (Get-FileHash -LiteralPath $local).Hash) { return 'Existing backup conflicts with the retained encrypted package. Choose another dedicated directory; neither package will be overwritten.' }
            }
        }
    } catch [UnauthorizedAccessException] { return 'Cannot inspect that backup location with the current user. Choose a new dedicated directory you control; no permissions will be changed.' }
}

function Write-DemoCustodyFile {
    param([string]$Path,[byte[]]$Bytes)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    Assert-DemoPrivatePath $Path
}

function Write-DemoCustodyMetadata {
    param([string]$Path,[hashtable]$Value,[switch]$Replace)
    $temporary="$Path.pending-$([guid]::NewGuid().ToString('N'))"
    Write-DemoCustodyFile $temporary ([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 5)))
    [IO.File]::Move($temporary,$Path,[bool]$Replace)
}

function Test-DemoCustodyPassword {
    param([string]$Directory,[securestring]$Password,[switch]$Pending,[string]$ArchivePath)
    if ($Pending) {
        $path=Join-Path $Directory 'custody.pfx'
        if (-not (Test-Path -LiteralPath $path)) { $path=Join-Path $Directory 'custody.pfx.pending' }
    } else {
        $receipt=Get-Content -LiteralPath (Join-Path $Directory 'custody.json') -Raw | ConvertFrom-Json -AsHashtable
        $path=$receipt.backupFile
    }
    if ($ArchivePath) { $path=$ArchivePath }
    if ($null -eq (Get-DemoCustodyPathItem $path)) { throw "Encrypted custody package is unavailable at '$path'. Reconnect/locate the original backup or use guided Setup recovery; no keys will be regenerated." }
    Assert-DemoPrivatePath $path
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs
    $bytes=[IO.File]::ReadAllBytes($path); $consumed=0
    $info=[Security.Cryptography.Pkcs.Pkcs12Info]::Decode([ReadOnlyMemory[byte]]::new($bytes),[ref]$consumed,$false)
    if ($consumed -ne $bytes.Length -or $info.IntegrityMode -ne 'Password') { throw 'Retained custody archive is malformed or lacks password integrity. Preserve it for explicit reconciliation; no regeneration.' }
    $text=ConvertFrom-DemoSecureString $Password
    try { return $info.VerifyMac($text) } finally { $text=$null }
}

function Resume-DemoCustody {
    param([string]$Directory,[string]$BackupDirectory,[securestring]$Password,[string]$InstallationId)
    Assert-DemoPrivatePath $Directory
    $problem=Get-DemoBackupPathError $BackupDirectory $Directory $InstallationId -Resume
    if ($problem) { throw [ArgumentException]::new($problem) }
    $plan=Get-Content -LiteralPath (Join-Path $Directory 'custody-plan.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($plan.schemaVersion -ne 1 -or $plan.installationId -cne $InstallationId) { throw 'Custody plan belongs to another installation. No keys will be generated or replaced.' }
    if (Test-Path -LiteralPath (Join-Path $Directory 'custody.json')) { throw 'Custody already exists; validate it rather than replaying creation.' }
    $local=Join-Path $Directory 'custody.pfx'
    $pending=Join-Path $Directory 'custody.pfx.pending'
    if ((Test-Path -LiteralPath $local) -and (Test-Path -LiteralPath $pending)) { throw 'Conflicting retained custody packages; preserve both and reconcile explicitly.' }
    $source=if (Test-Path -LiteralPath $local) { $local } else { $pending }
    Assert-DemoPrivatePath $source
    $certificates=Import-DemoCustodyCertificates $source $Password
    try {
        $names=@('wrapping-01','wrapping-02','wrapping-03','wrapping-04','recipient')
        if ($certificates.Count -ne 5 -or @($certificates.Thumbprint | Sort-Object -Unique).Count -ne 5) { throw 'Retained package must contain exactly five distinct custody keys.' }
        $publicFiles=@{}
        foreach ($name in $names) {
            $matching=@($certificates | Where-Object { $_.Subject -ceq "CN=demo2-$InstallationId-$name" -and $_.HasPrivateKey })
            if ($matching.Count -ne 1) { throw 'Retained custody package does not match this installation and its five private keys.' }
            $path=Join-Path $Directory "$name.cer"
            if (Test-Path -LiteralPath $path) {
                Assert-DemoPrivatePath $path
                $existing=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText($path))
                try { if ($existing.Thumbprint -cne $matching[0].Thumbprint) { throw 'Retained public certificate conflicts with the encrypted package. No overwrites or new keys.' } }
                finally { $existing.Dispose() }
            } else { $publicFiles[$path]=$matching[0].ExportCertificatePem() }
        }
        $archive=Join-Path $BackupDirectory "$InstallationId-custody.pfx"
        if (Test-Path -LiteralPath $archive) {
            Assert-DemoPrivatePath $archive
            if ((Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath $archive).Hash) { throw 'Existing backup conflicts with retained keys. Preserve both; choose another dedicated directory on resume.' }
        }
        New-DemoPrivateDirectory $BackupDirectory
        if ($source -eq $pending) { [IO.File]::Move($pending,$local) }
        if (-not (Test-Path -LiteralPath $archive)) { [IO.File]::Copy($local,$archive,$false) }
        Assert-DemoPrivatePath $archive
        foreach ($path in $publicFiles.Keys) {
            $temporary="$path.pending-$([guid]::NewGuid().ToString('N'))"
            Write-DemoCustodyFile $temporary ([Text.Encoding]::UTF8.GetBytes($publicFiles[$path]))
            [IO.File]::Move($temporary,$path)
        }
        $receipt=@{schemaVersion=1;installationId=$InstallationId;quorum=3;backupFile=$archive;fingerprints=@($certificates | ForEach-Object Thumbprint)}
        Write-DemoCustodyMetadata (Join-Path $Directory 'custody.json') $receipt
        Test-DemoCustodyBackup $Directory $Password
    } finally { foreach ($certificate in $certificates) { $certificate.Dispose() } }
}

function New-DemoCustody {
    param([string]$Directory, [string]$BackupDirectory, [securestring]$Password, [string]$InstallationId)
    Assert-DemoPrivatePath $Directory
    if ((Test-Path -LiteralPath (Join-Path $Directory 'custody.json')) -or
        @(Get-ChildItem -LiteralPath $Directory -Filter '*.cer').Count -or
        (Test-Path -LiteralPath (Join-Path $Directory 'custody.pfx')) -or
        (Test-Path -LiteralPath (Join-Path $Directory 'custody.pfx.pending'))) {
        throw 'Custody already exists; restore/reconcile it rather than regenerating keys.'
    }
    $problem=Get-DemoBackupPathError $BackupDirectory $Directory $InstallationId
    if ($problem) { throw [ArgumentException]::new($problem) }
    if ($Password.Length -lt 16) { throw [ArgumentException]::new('Use a backup passphrase of at least 16 characters, kept separately.') }
    $planPath=Join-Path $Directory 'custody-plan.json'
    if (Test-Path -LiteralPath $planPath) {
        $plan=Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -AsHashtable
        if ($plan.schemaVersion -ne 1 -or $plan.installationId -cne $InstallationId) { throw 'Retained custody plan differs. Reconcile it explicitly; no new keys.' }
        if ($plan.backupDirectory -cne $BackupDirectory) {
            $plan.backupDirectory=$BackupDirectory
            Write-DemoCustodyMetadata $planPath $plan -Replace
        }
    } else {
        Write-DemoCustodyMetadata $planPath @{schemaVersion=1;installationId=$InstallationId;backupDirectory=$BackupDirectory}
    }
    $passwordText = ConvertFrom-DemoSecureString $Password
    if (-not [Security.Cryptography.X509Certificates.X509Certificate2Collection].GetMethod('ExportPkcs12', [type[]]@([Security.Cryptography.PbeParameters],[string]))) {
        throw 'This PowerShell/.NET build lacks explicit AES PKCS#12 export; upgrade PowerShell. No weak export fallback is used.'
    }
    $certificates = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    try {
        foreach ($name in @('wrapping-01','wrapping-02','wrapping-03','wrapping-04','recipient')) {
            $rsa = [Security.Cryptography.RSA]::Create(4096)
            try {
                $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    "CN=demo2-$InstallationId-$name", $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                    [Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyEncipherment,DataEncipherment', $true))
                if ($name -eq 'recipient') {
                    $oids = [Security.Cryptography.OidCollection]::new()
                    [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.4.1.311.80.1'))
                    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$false))
                }
                $certificate = $request.CreateSelfSigned([datetimeoffset]::UtcNow.AddMinutes(-5),[datetimeoffset]::UtcNow.AddYears(1))
                [void]$certificates.Add($certificate)
            } finally { $rsa.Dispose() }
        }
        $pbe = [Security.Cryptography.PbeParameters]::new(
            [Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc, [Security.Cryptography.HashAlgorithmName]::SHA256, 200000)
        Write-DemoCustodyFile (Join-Path $Directory 'custody.pfx.pending') ($certificates.ExportPkcs12($pbe,$passwordText))
        Resume-DemoCustody $Directory $BackupDirectory $Password $InstallationId
    } finally {
        $passwordText = $null
        foreach ($certificate in $certificates) { $certificate.Dispose() }
    }
}

function Import-DemoCustodyCertificates {
    param([string]$Path,[securestring]$Password)
    $collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $text = ConvertFrom-DemoSecureString $Password
    try { $collection.Import($Path,$text,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]'EphemeralKeySet,Exportable') }
    catch { foreach ($certificate in $collection) { $certificate.Dispose() }; throw }
    finally { $text = $null }
    return ,$collection
}

function Test-DemoCustodyBackup {
    param([string]$Directory,[securestring]$Password,[string]$ArchivePath)
    $receipt = Get-Content -LiteralPath (Join-Path $Directory 'custody.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($ArchivePath) { $receipt.backupFile=$ArchivePath }
    if ($null -eq (Get-DemoCustodyPathItem $receipt.backupFile)) { throw "Encrypted custody backup is unavailable at '$($receipt.backupFile)'. Reconnect/locate it or use guided Setup recovery; no keys will be regenerated." }
    Assert-DemoPrivatePath $receipt.backupFile
    $certificates = Import-DemoCustodyCertificates -Path $receipt.backupFile -Password $Password
    try {
        if ($certificates.Count -ne 5 -or (Compare-Object @($receipt.fingerprints | Sort-Object) @($certificates.Thumbprint | Sort-Object))) {
            throw 'Backup does not contain the exact five expected certificates.'
        }
        foreach ($certificate in $certificates) {
            if (-not $certificate.HasPrivateKey) { throw 'Backup is missing a private key.' }
            $private = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
            $public = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
            try {
                $challenge = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
                $restored = $private.Decrypt($public.Encrypt($challenge,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
                if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($challenge,$restored)) { throw 'Custody restore challenge failed.' }
            } finally { $private.Dispose(); $public.Dispose() }
        }
    } finally { foreach ($certificate in $certificates) { $certificate.Dispose() } }
}

function Get-DemoCustodyPathItem {
    param([string]$Path)
    try { Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { return $null }
    catch [Management.Automation.DriveNotFoundException] { return $null }
}

function Get-DemoCustodyRecoveryState {
    param([string]$Directory)
    Assert-DemoPrivatePath $Directory
    $receiptPath=Join-Path $Directory 'custody.json'
    Assert-DemoPrivatePath $receiptPath
    $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
    if ($receipt.schemaVersion -ne 1 -or $receipt.installationId -notmatch '^[a-f0-9]{32}$' -or $receipt.quorum -ne 3 -or
        @($receipt.fingerprints).Count -ne 5 -or @($receipt.fingerprints | Sort-Object -Unique).Count -ne 5) { throw 'Custody receipt is invalid; preserve it for explicit reconciliation. No replacement keys.' }
    if ($receipt.backupFile -notmatch '^[A-Za-z]:\\' -or $receipt.backupFile -match '[*?"/<>|\x00-\x1f]' -or $receipt.backupFile.Substring(2).Contains(':')) { throw 'Custody receipt backup path is invalid; preserve it for reconciliation.' }
    $local=Join-Path $Directory 'custody.pfx'
    if ($null -ne (Get-DemoCustodyPathItem (Join-Path $Directory 'custody.pfx.pending'))) { throw 'Conflicting pending custody with a committed receipt; preserve packages for reconciliation.' }
    $localItem=Get-DemoCustodyPathItem $local
    $backupItem=Get-DemoCustodyPathItem $receipt.backupFile
    foreach ($item in @($localItem,$backupItem)) {
        if ($null -eq $item) { continue }
        if ($item -isnot [IO.FileInfo]) { throw 'Expected an encrypted custody file, not a directory.' }
        Assert-DemoPrivatePath $item.FullName
    }
    if ($backupItem) {
        $problem=Get-DemoBackupPathError (Split-Path $receipt.backupFile -Parent) $Directory $receipt.installationId -Resume -Recovery -ArchiveName (Split-Path $receipt.backupFile -Leaf)
        if ($problem) { throw [ArgumentException]::new("Recorded backup location is unsafe or conflicting: $problem") }
    }
    $driveAvailable=if ($null -eq $backupItem) { $null -ne (Get-DemoCustodyPathItem ([IO.Path]::GetPathRoot($receipt.backupFile))) } else { $true }
    return @{receipt=$receipt;localPath=$local;localAvailable=($null -ne $localItem);backupAvailable=($null -ne $backupItem);driveAvailable=$driveAvailable}
}

function Restore-DemoCustodyBackup {
    param([string]$Directory,[string]$SourcePath,[string]$BackupFile,[securestring]$Password)
    $state=Get-DemoCustodyRecoveryState $Directory
    if ($BackupFile -notmatch '^[A-Za-z]:\\' -or $BackupFile -match '[*?"/<>|\x00-\x1f]' -or $BackupFile.Substring(2).Contains(':')) { throw [ArgumentException]::new('Use a full drive-qualified encrypted .pfx backup path.') }
    $parent=Split-Path $BackupFile -Parent
    $problem=Get-DemoBackupPathError $parent $Directory $state.receipt.installationId -Resume -Recovery -ArchiveName (Split-Path $BackupFile -Leaf)
    if ($problem) { throw [ArgumentException]::new($problem) }
    Test-DemoCustodyBackup $Directory $Password -ArchivePath $SourcePath
    $sourceHash=(Get-FileHash -LiteralPath $SourcePath).Hash
    if ($state.localAvailable -and (Get-FileHash -LiteralPath $state.localPath).Hash -cne $sourceHash) { throw 'Selected archive differs from the retained encrypted package. Preserve both; no overwrite or replacement.' }
    if ($null -eq (Get-DemoCustodyPathItem $BackupFile)) {
        New-DemoPrivateDirectory $parent
        [IO.File]::Copy($SourcePath,$BackupFile,$false)
    }
    Assert-DemoPrivatePath $BackupFile
    if ((Get-FileHash -LiteralPath $BackupFile).Hash -cne $sourceHash) { throw 'Backup copy differs from the authenticated encrypted package. Receipt unchanged; preserve all files.' }
    Test-DemoCustodyBackup $Directory $Password -ArchivePath $BackupFile
    if (-not $state.localAvailable) {
        [IO.File]::Copy($BackupFile,$state.localPath,$false)
        Assert-DemoPrivatePath $state.localPath
        Test-DemoCustodyBackup $Directory $Password -ArchivePath $state.localPath
        if ((Get-FileHash -LiteralPath $state.localPath).Hash -cne $sourceHash) { throw 'Restored local encrypted copy differs; receipt unchanged.' }
    }
    if ($state.receipt.backupFile -cne $BackupFile) {
        $state.receipt.backupFile=$BackupFile
        Write-DemoCustodyMetadata (Join-Path $Directory 'custody.json') $state.receipt -Replace
    }
}

function Test-DemoDomainEnvelope {
    param([string]$Directory,[securestring]$Password,[string]$EnvelopePath)
    $certificates = Import-DemoCustodyCertificates (Join-Path $Directory 'custody.pfx') $Password
    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
        $cms = [Security.Cryptography.Pkcs.EnvelopedCms]::new()
        $cms.Decode([IO.File]::ReadAllBytes($EnvelopePath))
        $cms.Decrypt($certificates)
        $domain = [Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content) | ConvertFrom-Json -AsHashtable
        if (-not $domain -or -not $domain.ContainsKey('EncData')) { throw 'Decrypted result is not a security-domain document; keep guest copy and inspect privately.' }
    } finally { foreach ($certificate in $certificates) { $certificate.Dispose() } }
}

Export-ModuleMember -Function Assert-DemoPrivatePath, New-DemoPrivateDirectory, Protect-DemoPrivateFile, Get-DemoBackupPathError, New-DemoCustody, Resume-DemoCustody, Test-DemoCustodyPassword, Test-DemoCustodyBackup, Get-DemoCustodyRecoveryState, Restore-DemoCustodyBackup, Test-DemoDomainEnvelope
