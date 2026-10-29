Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DemoPrivatePath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { throw 'Field custody currently requires Windows with PowerShell 7.4+.' }
    $item = Get-Item -LiteralPath $Path -Force
    for ($parent = $item; $null -ne $parent;) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Private paths must not traverse reparse points.' }
        $parent = if ($parent -is [IO.FileInfo]) { $parent.Directory } else { $parent.Parent }
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $rules = @($acl.Access)
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or
        $rules.Count -ne 1 -or $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or
        $rules[0].AccessControlType -ne 'Allow' -or
        ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
        throw "Private path requires current-user-only FullControl: $Path"
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

function New-DemoCustody {
    param([string]$Directory, [string]$BackupDirectory, [securestring]$Password, [string]$InstallationId)
    Assert-DemoPrivatePath $Directory
    New-DemoPrivateDirectory $BackupDirectory
    $local = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $backup = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
    if ($backup -eq $local -or $backup.StartsWith("$local\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Backup must be outside the installation directory.'
    }
    $archive = Join-Path $BackupDirectory "$InstallationId-custody.pfx"
    for ($parent = Get-Item -LiteralPath $BackupDirectory; $null -ne $parent; $parent = $parent.Parent) {
        if (Test-Path -LiteralPath (Join-Path $parent.FullName '.git')) { throw 'Independent recovery backups must not be stored in a Git checkout.' }
    }
    if ((Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath (Join-Path $Directory 'custody.json')) -or
        @(Get-ChildItem -LiteralPath $Directory -Filter '*.cer').Count -or
        (Test-Path -LiteralPath (Join-Path $Directory 'custody.pfx'))) {
        throw 'Custody already exists; restore/reconcile it rather than regenerating keys.'
    }
    $passwordText = ConvertFrom-DemoSecureString $Password
    if ($passwordText.Length -lt 16) { throw 'Use a backup passphrase of at least 16 characters, kept separately.' }
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
                [IO.File]::WriteAllText((Join-Path $Directory "$name.cer"), $certificate.ExportCertificatePem())
            } finally { $rsa.Dispose() }
        }
        $pbe = [Security.Cryptography.PbeParameters]::new(
            [Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc, [Security.Cryptography.HashAlgorithmName]::SHA256, 200000)
        [IO.File]::WriteAllBytes($archive, $certificates.ExportPkcs12($pbe,$passwordText))
        Assert-DemoPrivatePath $archive
        Copy-Item -LiteralPath $archive -Destination (Join-Path $Directory 'custody.pfx')
        $receipt = @{ schemaVersion=1; installationId=$InstallationId; quorum=3; backupFile=$archive; fingerprints=@($certificates | ForEach-Object Thumbprint) }
        $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory 'custody.json') -Encoding utf8
        Test-DemoCustodyBackup -Directory $Directory -Password $Password
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
    finally { $text = $null }
    return ,$collection
}

function Test-DemoCustodyBackup {
    param([string]$Directory,[securestring]$Password)
    $receipt = Get-Content -LiteralPath (Join-Path $Directory 'custody.json') -Raw | ConvertFrom-Json -AsHashtable
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

Export-ModuleMember -Function Assert-DemoPrivatePath, New-DemoPrivateDirectory, Protect-DemoPrivateFile, New-DemoCustody, Test-DemoCustodyBackup, Test-DemoDomainEnvelope
