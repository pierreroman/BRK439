Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DemoGuid {
    param([string]$Value, [string]$Name)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Name must be an explicit nonempty GUID."
    }
}

function Import-DemoConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Foundation', 'Runtime')][string]$Phase = 'Runtime'
    )
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($config.schemaVersion -ne 1 -or $config.purpose -cne 'demo2-only') {
        throw 'Only schemaVersion 1 and purpose demo2-only are accepted.'
    }
    foreach ($name in 'tenantId', 'subscriptionId', 'manualRecoveryObjectId') {
        Assert-DemoGuid -Value $config[$name] -Name $name
    }
    foreach ($name in 'location', 'deniedLocation') {
        if ($config[$name] -notmatch '^[a-z][a-z0-9]+$') { throw "$name must be a real explicit Azure location name." }
    }
    if ($config.resourceGroup -notmatch '^rg-demo2-[a-z0-9-]{1,60}$' -or
        $config.hsmName -notmatch '^hsm-demo2-[a-z0-9-]{1,14}$' -or
        $config.nameSuffix -notmatch '^[a-z0-9]{3,10}$') {
        throw 'Use a dedicated rg-demo2-* group, hsm-demo2-* HSM (maximum 24 characters), and 3-10 character nameSuffix.'
    }
    if ($config.allowedLocations.Count -eq 0 -or $config.location -notin $config.allowedLocations -or
        $config.deniedLocation -in $config.allowedLocations) {
        throw 'Primary location must be allowed and deniedLocation must not be allowed.'
    }
    if ($config.policyMode -notin @('sandbox', 'existing-slz')) { throw 'Choose sandbox or existing-slz explicitly.' }
    if ($config.policyMode -eq 'existing-slz' -and $config.existingPolicyAssignmentIds.Count -eq 0) {
        throw 'Existing SLZ mode requires effective policy assignment IDs; it never creates substitute assignments.'
    }
    if ($config.vmSize -notmatch '^Standard_[A-Za-z0-9_]+$' -or
        $config.vmSize -notin $config.allowedConfidentialVmSkus) {
        throw 'Select an available confidential VM SKU from the explicit allowed list.'
    }
    foreach ($name in 'publisher', 'offer', 'sku', 'version') {
        if ([string]::IsNullOrWhiteSpace($config.imageReference[$name])) { throw "imageReference.$name is required." }
    }
    if ($config.initialAdminObjectIds.Count -eq 0) { throw 'Initial HSM administrator object IDs are required.' }
    foreach ($id in $config.initialAdminObjectIds) { Assert-DemoGuid $id 'initialAdminObjectIds' }
    if ($config.budgetAmount -le 0 -or $config.logRetentionDays -lt 30 -or $config.logRetentionDays -gt 730) {
        throw 'Set a positive budgetAmount and logRetentionDays between 30 and 730 before deployment.'
    }
    if ($config.alertEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'An explicit recovery alert recipient is required.' }
    if ($config.network.accessMode -notin @('bastion', 'existing-private-connection')) { throw 'Invalid accessMode.' }
    $networks = @()
    $cidrNames = @('vnetCidr', 'computeSubnetCidr', 'endpointSubnetCidr')
    if ($config.network.accessMode -eq 'bastion') { $cidrNames += 'bastionSubnetCidr' }
    foreach ($name in $cidrNames) {
        $cidr = $config.network[$name]
        if ($cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d|[12]\d|3[0-2])$') { throw "network.$name must be an explicit IPv4 CIDR." }
        $ip, $bits = $cidr.Split('/')
        $address = [System.Net.IPAddress]::Parse($ip)
        if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Only IPv4 demo CIDRs are supported.' }
        $bytes = $address.GetAddressBytes()
        $number = ([uint64]$bytes[0] -shl 24) + ([uint64]$bytes[1] -shl 16) + ([uint64]$bytes[2] -shl 8) + $bytes[3]
        $size = [uint64][math]::Pow(2, (32 - [int]$bits))
        if ($name -eq 'bastionSubnetCidr' -and [int]$bits -gt 26) { throw 'Bastion requires a /26 or larger subnet.' }
        if ($number % $size -ne 0) { throw "network.$name must use its network address." }
        $networks += @{ start = $number; end = $number + $size - 1; name = $name }
    }
    foreach ($subnet in $networks[1..($networks.Count - 1)]) {
        if ($subnet.start -lt $networks[0].start -or $subnet.end -gt $networks[0].end) { throw 'Subnets must be contained in vnetCidr.' }
    }
    for ($i = 1; $i -lt $networks.Count; $i++) {
        for ($j = $i + 1; $j -lt $networks.Count; $j++) {
            if ($networks[$i].start -le $networks[$j].end -and $networks[$j].start -le $networks[$i].end) { throw 'Demo subnets must not overlap.' }
        }
    }
    if ($config.sshUser -notmatch '^[a-z_][a-z0-9_-]{0,30}$' -or
        $config.sshHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$' -or
        $config.sshPort -lt 1 -or $config.sshPort -gt 65535) { throw 'Invalid SSH user, host or port.' }
    if ($config.sshPublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+(?: .*)?$') {
        throw 'Supply a reviewed SSH public key, never a private key.'
    }
    if ($config.container -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]$' -or
        $config.container.Contains('--') -or $config.blob -notmatch '^[a-zA-Z0-9._-]{1,100}\.txt$') {
        throw 'Use a valid private container and a simple synthetic .txt blob name.'
    }
    if ($config.watchdogIntervalSeconds -lt 1 -or $config.watchdogIntervalSeconds -gt 10) { throw 'Watchdog interval must be 1-10 seconds.' }
    foreach ($target in 'Live', 'Twin') {
        $item = $config.targets[$target]
        if ($item.accountName -notmatch '^demo2[a-z0-9]{1,19}$' -or
            $item.keyName -notmatch '^demo2-[a-z0-9-]{1,100}$' -or
            $item.recoveryTimeoutSeconds -lt 30 -or $item.recoveryTimeoutSeconds -gt 3600) {
            throw "$target requires a dedicated demo2 storage/key name and fixed timeout of 30-3600 seconds."
        }
        if ($Phase -eq 'Runtime' -and $item.keyVersion -notmatch '^[a-fA-F0-9]{32}$') { throw "$target must pin an actual key version." }
    }
    if ($config.targets.Live.accountName -eq $config.targets.Twin.accountName -or
        $config.targets.Live.keyName -eq $config.targets.Twin.keyName) { throw 'Live and Twin must use different accounts and key names.' }
    if ($Phase -eq 'Runtime') {
        foreach ($name in 'controllerIdentityClientId', 'controllerPrincipalId', 'liveStorageIdentityPrincipalId', 'twinStorageIdentityPrincipalId') {
            Assert-DemoGuid $config[$name] $name
        }
    }
    if ($config.enableSkr) { throw 'SKR is an optional separately reviewed extension; this base kit must use enableSkr=false.' }
    $schemaPath = Join-Path $PSScriptRoot '../config.schema.json'
    if (-not (Test-Json -Json ($config | ConvertTo-Json -Depth 20) -SchemaFile $schemaPath -ErrorAction Stop)) {
        throw 'Configuration does not match the Demo 2 schema.'
    }
    return $config
}

function Get-DemoCliContext {
    param([string[]]$Arguments)
    $words=@(foreach ($value in $Arguments) { if ($value.StartsWith('-')) { break }; if ($value -cmatch '^[a-z][a-z-]{0,40}$') { $value } else { break } })
    $context=($words | Select-Object -First 4) -join ' '
    if (-not $context) { $context='az' }
    if ($words.Count -and $words[0] -eq 'rest') {
        $method=[array]::IndexOf($Arguments,'--method')
        if ($method -ge 0 -and $method+1 -lt $Arguments.Count -and $Arguments[$method+1] -imatch '^(get|put|post|patch|delete|head)$') { $context+=' '+$Arguments[$method+1].ToUpperInvariant() }
        $url=[array]::IndexOf($Arguments,'--url')
        $uri=$null
        if ($url -ge 0 -and $url+1 -lt $Arguments.Count -and [uri]::TryCreate($Arguments[$url+1],[UriKind]::Absolute,[ref]$uri) -and
            $uri.Scheme -eq 'https' -and -not $uri.UserInfo -and $uri.Host -eq 'management.azure.com' -and $uri.AbsolutePath -cmatch '^/[a-zA-Z0-9/._()-]{1,2048}$') {
            $context+=' '+$uri.GetLeftPart([UriPartial]::Path)
        }
    } else {
        foreach ($name in '--resource-group','--name','--ids') {
            $index=[array]::IndexOf($Arguments,$name)
            if ($index -ge 0 -and $index+1 -lt $Arguments.Count -and $Arguments[$index+1] -cmatch '^[a-zA-Z0-9/._()-]{1,512}$') { $context+=" $name $($Arguments[$index+1])" }
        }
    }
    return $context
}

function New-DemoCliException {
    param([int]$ExitCode,[string]$Stdout,[string]$Stderr,[string]$Context)
    $details=@{AzureCliExitCode=$ExitCode;Command=$Context;StderrClassification='UnrecognizedText';StdoutClassification='Empty'}
    if ([string]::IsNullOrWhiteSpace($Stderr)) { $details.StderrClassification='Empty' }
    if (-not [string]::IsNullOrWhiteSpace($Stdout)) { $details.StdoutClassification='NonJson' }
    foreach ($stream in @(@{name='Stdout';text=$Stdout},@{name='Stderr';text=$Stderr})) {
        foreach ($candidate in @($stream.text)+@($stream.text -split '(?m)^ERROR:\s*' | Select-Object -Skip 1)) {
            $index=$candidate.IndexOf('{')
            if ($index -lt 0) { continue }
            $reader=[Newtonsoft.Json.JsonTextReader]::new([IO.StringReader]::new($candidate.Substring($index)))
            try {
                try { $root=[Newtonsoft.Json.Linq.JObject]::Load($reader).ToString() | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
                catch { continue }
                $details["$($stream.name)Classification"]='Json'
                $errorRoot=if ($root['error'] -is [Collections.IDictionary]) { $root['error'] } else { $root }
                if ([string]$errorRoot['code'] -match '^[A-Za-z][A-Za-z0-9._-]{0,127}$') { $details.AzureCliCode=[string]$errorRoot['code'] }
                $errors=[Collections.Generic.Queue[object]]::new()
                $errors.Enqueue($errorRoot)
                $codes=@()
                for ($i=0; $errors.Count -and $i -lt 32; $i++) {
                    $node=$errors.Dequeue()
                    if ($node -isnot [Collections.IDictionary]) { continue }
                    if ([string]$node['code'] -match '^[A-Za-z][A-Za-z0-9._-]{0,127}$') { $codes+=[string]$node['code'] }
                    foreach ($key in 'error','innererror','details') {
                        foreach ($child in @($node[$key])) { if ($child -is [Collections.IDictionary]) { $errors.Enqueue($child) } }
                    }
                }
                if ($codes.Count) { $details.AzureErrorCodes=($codes | Select-Object -Unique) -join ',' }
                if ($root['tags'] -is [Collections.IDictionary] -and [string]$root['tags']['operationId'] -match '^[a-fA-F0-9-]{36}$') { $details.OperationId=$root['tags']['operationId'] }
                if ($root['properties'] -is [Collections.IDictionary] -and $root['properties']['provisioningState'] -in 'Accepted','Creating','Updating','Succeeded','Failed','Canceled','Deleting') { $details.ProvisioningState=$root['properties']['provisioningState'] }
                foreach ($name in 'requestId','correlationId') {
                    if ([string]$errorRoot[$name] -match '^[a-fA-F0-9-]{36}$') { $details[$name]=$errorRoot[$name] }
                }
                foreach ($name in 'status','statusCode') {
                    if ([string]$errorRoot[$name] -match '^[1-5][0-9]{2}$') { $details.HttpStatus=[int]$errorRoot[$name] }
                }
            } finally { $reader.Dispose() }
        }
    }
    $hints=@()
    foreach ($line in ($Stderr -split '\r?\n')) {
        if ($line -match '^ERROR:\s*\((?<Code>[A-Za-z][A-Za-z0-9._-]{0,127})\)' -or $line -match '^Code:\s*(?<Code>[A-Za-z][A-Za-z0-9._-]{0,127})\s*$') {
            if (-not $details.ContainsKey('AzureCliCode')) { $details.AzureCliCode=$Matches.Code }
            $details.StderrClassification='AzureErrorCode'
        } elseif ($line -match '^ERROR:\s*Please run [''"]az login[''"] to (?:setup|set up) account\.?\s*$') {
            $details.StderrClassification='Authentication'; $hints+='Azure CLI requires az login.'
        } elseif ($line -match '^ERROR:.*\b(?<Code>AADSTS[0-9]{4,8})\b') {
            if (-not $details.ContainsKey('AzureCliCode')) { $details.AzureCliCode=$Matches.Code }
            $details.StderrClassification='Authentication'; $hints+="Authentication diagnostic $($Matches.Code); account details omitted."
        } elseif ($line -match '(?:^|: )No module named [''"]?(?:azure(?:\.cli)?|knack)[''"]?\s*$') {
            $details.StderrClassification='Launcher'; $hints+='Bundled Python cannot import Azure CLI/knack.'
        } elseif ($line -match '^(?:Fatal Python error:|ImportError: DLL load failed)') {
            $details.StderrClassification='Launcher'; $hints+='Bundled Python runtime/DLL initialization failed; details omitted.'
        } elseif ($line -match '^ERROR:\s*(?:unrecognized arguments|the following arguments are required):') {
            $details.StderrClassification='Usage'; $hints+='Azure CLI argument validation failed; argument values omitted.'
            if ($line -match '(?<Option>--[a-z][a-z0-9-]{0,47})(?:\s|,|$)') { $hints+="Argument: $($Matches.Option)." }
        } elseif ($line -match '^ERROR:\s*(?:Failed to parse string as json|Failed to load|Unable to read).*$') {
            $details.StderrClassification='InputFile'; $hints+='Azure CLI could not parse/read its input; paths and content omitted.'
        } elseif ($line -match '^ERROR: The command failed with an unexpected error') {
            $details.StderrClassification='CliTraceback'; $hints+='Azure CLI reported an internal traceback; raw traceback omitted.'
        } elseif ($line -match '\bConnectionResetError\b|\bConnection reset by peer\b') {
            $details.StderrClassification='ConnectionReset'
            $hints+='The CLI HTTP connection was reset; this does not prove a submitted operation failed. Preserve and reconcile pending intent.'
            if ($line -match '(?:WinError\s+|ConnectionResetError\()(?<Native>[0-9]{1,6})') { $details.NativeErrorCode=[int]$Matches.Native }
        } elseif ($line -match '^Status(?: Code)?:\s*(?<Status>[1-5][0-9]{2})\s*$') {
            $details.HttpStatus=[int]$Matches.Status
        }
    }
    $code=if ($details.ContainsKey('AzureCliCode')) { $details.AzureCliCode } else { 'AzureCliFailure' }
    $metadata=@(foreach ($name in 'OperationId','ProvisioningState','HttpStatus','requestId','correlationId','AzureErrorCodes','NativeErrorCode','StderrClassification') {
        if ($details.ContainsKey($name)) { "$name=$($details[$name])" }
    }) -join '; '
    $hint=(@($hints | Select-Object -Unique -First 3) -join ' ')
    $exception=[InvalidOperationException]::new("Azure CLI failed (exit $ExitCode): {`"code`":`"$code`"}. Command: $Context. $metadata. $hint Response omitted to protect scripts/content; reconcile any pending operation before retrying.")
    foreach ($name in $details.get_Keys()) { $exception.Data[$name]=$details[$name] }
    return $exception
}

function Invoke-AzJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $command=Get-Command az -ErrorAction Stop
    $values=@($Arguments)+@('--only-show-errors','--output','json')
    if ($command.CommandType -eq 'Application') {
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$command.Source
        $start.UseShellExecute=$false
        $start.RedirectStandardOutput=$true
        $start.RedirectStandardError=$true
        $start.CreateNoWindow=$true
        if ($IsWindows -and [IO.Path]::GetExtension($command.Source) -in '.cmd','.bat') {
            $python=Join-Path (Split-Path (Split-Path $command.Source -Parent) -Parent) 'python.exe'
            if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Windows Azure CLI batch launcher requires its bundled sibling python.exe. Use the supported MSI layout; no cmd.exe fallback is allowed.' }
            $start.FileName=$python
            $start.Environment['AZ_INSTALLER']='MSI'
            foreach ($value in @('-IBm','azure.cli')) { $start.ArgumentList.Add($value) }
        }
        foreach ($value in $values) { $start.ArgumentList.Add($value) }
        $process=[Diagnostics.Process]::new()
        try {
            $process.StartInfo=$start
            [void]$process.Start()
            $stdout=$process.StandardOutput.ReadToEndAsync()
            $stderr=$process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $exitCode=$process.ExitCode
            $outText=$stdout.GetAwaiter().GetResult()
            $errText=$stderr.GetAwaiter().GetResult()
        } finally { $process.Dispose() }
    } else {
        $PSNativeCommandUseErrorActionPreference=$false
        $lines=& az @values 2>&1
        $exitCode=$LASTEXITCODE
        $outText=@($lines | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
        $errText=@($lines | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
    }
    if ($exitCode -ne 0) {
        throw (New-DemoCliException $exitCode $outText $errText (Get-DemoCliContext $Arguments))
    }
    if (-not [string]::IsNullOrWhiteSpace($outText)) {
        try { return ($outText | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
        catch { throw [InvalidOperationException]::new('Azure CLI returned malformed JSON. Response omitted to protect scripts/content; no success assumed.') }
    }
}

function Assert-DemoAzureContext {
    param([Parameter(Mandatory)][hashtable]$Config)
    $context = Invoke-AzJson -Arguments @('account', 'show')
    if ($context.id -ne $Config.subscriptionId -or $context.tenantId -ne $Config.tenantId -or
        $context.environmentName -ne 'AzureCloud') { throw 'Azure CLI context must match the explicit tenant, subscription and Azure public cloud.' }
}

function Get-DemoKeyUri {
    param([Parameter(Mandatory)][hashtable]$Config, [ValidateSet('Live', 'Twin')][string]$Target)
    $item = $Config.targets[$Target]
    return "https://$($Config.hsmName).managedhsm.azure.net/keys/$($item.keyName)/$($item.keyVersion)"
}

function Test-IntendedPolicyDenial {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$AssignmentId,
        [Parameter(Mandatory)][string]$DefinitionId,
        [bool]$WithinDeniedError = $false
    )
    if ($Node -is [string]) {
        if ($Node.TrimStart().StartsWith('{') -or $Node.TrimStart().StartsWith('[')) {
            try { $parsed = ConvertFrom-Json -InputObject $Node -AsHashtable -ErrorAction Stop }
            catch { return $false }
            return (Test-IntendedPolicyDenial $parsed $AssignmentId $DefinitionId $WithinDeniedError)
        }
        return $false
    }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('code') -and $Node['code'] -eq 'RequestDisallowedByPolicy') { $WithinDeniedError = $true }
        if ($WithinDeniedError -and $Node['policyAssignmentId'] -eq $AssignmentId -and
            $Node['policyDefinitionId'] -eq $DefinitionId -and
            $Node['evaluationDetails'] -is [System.Collections.IDictionary] -and
            @($Node['evaluationDetails']['evaluatedExpressions']).Count -gt 0) { return $true }
        foreach ($value in $Node.Values) {
            if ($null -ne $value -and (Test-IntendedPolicyDenial $value $AssignmentId $DefinitionId $WithinDeniedError)) { return $true }
        }
    } elseif ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) {
            if ($null -ne $item -and (Test-IntendedPolicyDenial $item $AssignmentId $DefinitionId $WithinDeniedError)) { return $true }
        }
    }
    return $false
}

Export-ModuleMember -Function Import-DemoConfig, Invoke-AzJson, Assert-DemoAzureContext, Get-DemoKeyUri, Assert-DemoGuid, Test-IntendedPolicyDenial
