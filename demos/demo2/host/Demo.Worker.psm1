Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-DurableJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress))
    try {
        $stream = [System.IO.FileStream]::new($temporary, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        [System.IO.File]::Move($temporary, $Path, $true)
        if ($IsLinux) {
            & sync -f -- ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path)))
            if ($LASTEXITCODE -ne 0) { throw 'Could not flush renamed state directory; refusing to acknowledge durability.' }
        }
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Write-DemoEvent {
    param([Parameter(Mandatory)][string]$EventName, [hashtable]$Data = @{})
    $record = @{ utc = [datetimeoffset]::UtcNow.ToString('o'); event = $EventName; data = $Data }
    $line = $record | ConvertTo-Json -Depth 8 -Compress
    Write-Information $line -InformationAction Continue
    if ($IsLinux) {
        & logger -p user.notice -t demo2 -- $line
        if ($LASTEXITCODE -ne 0) { throw 'Could not send watchdog event to syslog; new disable operations must stop.' }
    }
}

function Invoke-DemoHttp {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'PATCH')][string]$Method = 'GET',
        [hashtable]$Headers = @{}, [string]$Body = '', [int]$TimeoutSeconds = 15
    )
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [timespan]::FromSeconds($TimeoutSeconds)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    try {
        foreach ($name in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) }
        if ($Body) { $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json') }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $resultHeaders = @{}
            foreach ($header in $response.Headers) { $resultHeaders[$header.Key.ToLowerInvariant()] = $header.Value -join ',' }
            return @{ status = [int]$response.StatusCode; headers = $resultHeaders; body = $bodyText }
        } finally { $response.Dispose() }
    } finally { $request.Dispose(); $client.Dispose(); $handler.Dispose() }
}

function Get-DemoToken {
    param([hashtable]$Config, [ValidateSet('https://storage.azure.com/', 'https://managedhsm.azure.net', 'https://management.azure.com/')][string]$Resource)
    $encodedResource = [uri]::EscapeDataString($Resource)
    $clientId = [uri]::EscapeDataString($Config.controllerIdentityClientId)
    $result = Invoke-DemoHttp -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encodedResource&client_id=$clientId" -Headers @{ Metadata = 'true' } -TimeoutSeconds 5
    if ($result.status -ne 200) { throw "Managed identity token acquisition failed: HTTP $($result.status)." }
    $token = ($result.body | ConvertFrom-Json -AsHashtable).access_token
    $parts = $token.Split('.')
    if ($parts.Count -ne 3) { throw 'IMDS returned an invalid access token.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
    $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
    if ($claims.tid -ne $Config.tenantId -or $claims.oid -ne $Config.controllerPrincipalId -or
        [long]$claims.exp -le [datetimeoffset]::UtcNow.ToUnixTimeSeconds()) {
        throw 'Managed identity token does not match configured tenant/principal or has expired.'
    }
    return $token
}

function Get-KeyAttributes {
    param([hashtable]$Config, [string]$Target)
    $uri = Get-DemoKeyUri -Config $Config -Target $Target
    $token = Get-DemoToken -Config $Config -Resource 'https://managedhsm.azure.net'
    $result = Invoke-DemoHttp -Uri "${uri}?api-version=7.4" -Headers @{ Authorization = "Bearer $token" }
    if ($result.status -ne 200) { throw "HSM key inspection failed: HTTP $($result.status)." }
    $key = $result.body | ConvertFrom-Json -AsHashtable
    if ($key.key.kid -cne $uri) { throw 'HSM returned a key outside the exact version allowlist.' }
    return $key.attributes
}

function Set-KeyEnabled {
    param([hashtable]$Config, [string]$Target, [bool]$Enabled)
    $uri = Get-DemoKeyUri -Config $Config -Target $Target
    $token = Get-DemoToken -Config $Config -Resource 'https://managedhsm.azure.net'
    $body = @{ attributes = @{ enabled = $Enabled } } | ConvertTo-Json -Compress
    $result = Invoke-DemoHttp -Uri "${uri}?api-version=7.4" -Method PATCH -Body $body -Headers @{ Authorization = "Bearer $token" }
    if ($result.status -ne 200) { throw "HSM attribute update failed or is uncertain: HTTP $($result.status)." }
    $key = $result.body | ConvertFrom-Json -AsHashtable
    if ($key.key.kid -cne $uri -or $key.attributes.enabled -ne $Enabled) { throw 'HSM update acknowledgment did not match the allowlisted key and requested state.' }
}

function Assert-StorageKeyBinding {
    param([hashtable]$Config, [string]$Target)
    $account = $Config.targets[$Target].accountName
    $path = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$account"
    $token = Get-DemoToken -Config $Config -Resource 'https://management.azure.com/'
    $result = Invoke-DemoHttp -Uri "https://management.azure.com${path}?api-version=2023-05-01" -Headers @{ Authorization = "Bearer $token" }
    if ($result.status -ne 200) { throw "Storage binding inspection failed: HTTP $($result.status)." }
    $resource = $result.body | ConvertFrom-Json -AsHashtable
    $expected = $Config.targets[$Target]
    $encryption = $resource.properties.encryption
    if ($resource.location -ne $Config.location -or $encryption.keySource -ne 'Microsoft.Keyvault' -or
        $encryption.keyvaultproperties.keyname -ne $expected.keyName -or
        $encryption.keyvaultproperties.keyversion -ne $expected.keyVersion -or
        $encryption.keyvaultproperties.keyvaulturi.TrimEnd('/') -ne "https://$($Config.hsmName).managedhsm.azure.net") {
        throw 'Storage configuration does not match the allowlisted region and pinned CMK.'
    }
}

function Read-DemoBlob {
    param([hashtable]$Config, [string]$Target)
    $account = $Config.targets[$Target].accountName
    $clientId = [guid]::NewGuid().ToString()
    $uri = "https://$account.blob.core.windows.net/$($Config.container)/$([uri]::EscapeDataString($Config.blob))"
    $token = Get-DemoToken -Config $Config -Resource 'https://storage.azure.com/'
    $result = Invoke-DemoHttp -Uri $uri -Headers @{
        Authorization = "Bearer $token"
        'x-ms-version' = '2023-11-03'
        'x-ms-date' = [datetime]::UtcNow.ToString('R', [cultureinfo]::InvariantCulture)
        'x-ms-client-request-id' = $clientId
        'Cache-Control' = 'no-cache, no-store'
    }
    $read = @{
        utc = [datetimeoffset]::UtcNow.ToString('o'); target = $Target; account = $account
        status = $result.status; errorCode = $result.headers['x-ms-error-code']
        requestId = $result.headers['x-ms-request-id']; clientRequestId = $clientId
        content = ''; transport = 'Azure Storage REST Get Blob; no retries'
    }
    if ($result.status -eq 200) { $read.content = $result.body }
    $evidence = $read.Clone()
    [void]$evidence.Remove('content')
    Write-DemoEvent -EventName 'BlobRead' -Data $evidence
    return $read
}

function New-RecoveryState {
    param([hashtable]$Config, [string]$Target, [string]$RunId, [datetimeoffset]$Now)
    return @{
        schemaVersion = 1; target = $Target; runId = $RunId
        keyUri = Get-DemoKeyUri -Config $Config -Target $Target
        phase = 'Armed'; armedUtc = $Now.ToString('o')
        deadlineUtc = $Now.AddSeconds($Config.targets[$Target].recoveryTimeoutSeconds).ToString('o')
        keyEnabled = $true; readRestored = $true; uncertainMutation = $false
        lastError = ''; recoveredSinceUtc = $null; lastObservedUtc = $Now.ToString('o')
        closedRunIds = @()
    }
}

function Assert-RunMatches {
    param([hashtable]$State, [hashtable]$Request, [hashtable]$Config)
    if (-not $State -or $State.runId -ne $Request.runId -or $State.target -ne $Request.target -or
        $State.keyUri -cne (Get-DemoKeyUri $Config $Request.target)) { throw 'Request does not match the persisted run and exact allowlisted version.' }
}

function Initialize-RecoveryState {
    param([hashtable]$Config, [hashtable]$State, [string]$Target)
    if ($State.schemaVersion -ne 1 -or $State.target -ne $Target -or
        $State.phase -notin @('Armed', 'Disabling', 'Disabled', 'Recovering', 'Recovered', 'Closed') -or
        $State.keyUri -cne (Get-DemoKeyUri $Config $Target)) { throw "Invalid $Target recovery state; manual recovery is required." }
    Assert-DemoGuid $State.runId 'persisted runId'
    [void][datetimeoffset]::Parse($State.deadlineUtc)
    [void][datetimeoffset]::Parse($State.lastObservedUtc)
    if ($State.phase -ne 'Closed') { $State.phase = 'Recovering' }
    return $State
}

function Invoke-RecoveryTick {
    param([hashtable]$Config, [hashtable]$State, [string]$StatePath, [datetimeoffset]$Now)
    if (-not $State -or $State.phase -eq 'Closed') { return $State }
    if ($State.keyUri -cne (Get-DemoKeyUri $Config $State.target)) {
        throw 'Recovery state/configuration key mismatch: restore original config and use manual recovery; new operations are blocked.'
    }
    if ($Now -lt [datetimeoffset]::Parse($State.lastObservedUtc)) {
        $State.phase = 'Recovering'
        $State.lastError = 'Clock moved backward; restoring instead of extending outage.'
    }
    $State.lastObservedUtc = $Now.ToString('o')
    if ($Now -ge [datetimeoffset]::Parse($State.deadlineUtc) -or $State.phase -in @('Recovering', 'Recovered')) {
        $State.phase = 'Recovering'
        Write-DurableJson $StatePath $State
        try {
            Set-KeyEnabled $Config $State.target $true
            $State.keyEnabled = (Get-KeyAttributes $Config $State.target).enabled -eq $true
            $read = Read-DemoBlob $Config $State.target
            $State.readRestored = $read.status -eq 200
            if ($State.keyEnabled -and $State.readRestored) {
                $State.phase = 'Recovered'
                if (-not $State.recoveredSinceUtc) { $State.recoveredSinceUtc = $Now.ToString('o') }
                $State.lastError = ''
                Write-DemoEvent 'RecoveryConfirmed' @{ target = $State.target; runId = $State.runId; deadlineUtc = $State.deadlineUtc }
            } else {
                $State.recoveredSinceUtc = $null
                $State.lastError = "Key enabled=$($State.keyEnabled); Get Blob HTTP $($read.status), error $($read.errorCode), request $($read.requestId)."
                Write-DemoEvent 'RecoveryOverdue' @{ target = $State.target; runId = $State.runId; error = $State.lastError }
            }
        } catch {
            $State.recoveredSinceUtc = $null
            $State.lastError = $_.Exception.Message
            Write-DemoEvent 'RecoveryOverdue' @{ target = $State.target; runId = $State.runId; error = $State.lastError }
        }
        Write-DurableJson $StatePath $State
    }
    return $State
}

function Invoke-WorkerRequest {
    param(
        [hashtable]$Config, [hashtable]$Request, [hashtable]$State,
        [string]$StatePath, [datetimeoffset]$Now, [datetimeoffset]$Heartbeat
    )
    if ($Request.action -notin @('Arm', 'Disable', 'Restore', 'Read', 'Status', 'Reset') -or
        $Request.target -notin @('Live', 'Twin')) { throw 'Invalid controller action or target.' }
    Assert-DemoGuid $Request.runId 'runId'
    $read = $null
    switch ($Request.action) {
        'Arm' {
            if ($State -and $State.phase -ne 'Closed') { throw 'Existing run must be restored, verified and explicitly Reset before arming.' }
            if ($State -and ($State.runId -eq $Request.runId -or $Request.runId -in $State.closedRunIds)) { throw 'Run ID replay is forbidden.' }
            if (($Now - $Heartbeat).TotalSeconds -gt 20 -or $Heartbeat -gt $Now) { throw 'A fresh independent watchdog heartbeat is required.' }
            Assert-StorageKeyBinding $Config $Request.target
            if ((Get-KeyAttributes $Config $Request.target).enabled -ne $true) { throw 'Refusing to arm an already-disabled key.' }
            $read = Read-DemoBlob $Config $Request.target
            if ($read.status -ne 200) { throw "Baseline Get Blob failed: HTTP $($read.status), error $($read.errorCode), request $($read.requestId)." }
            Set-KeyEnabled $Config $Request.target $true
            $history = if ($State) { @($State.closedRunIds) + @($State.runId) } else { @() }
            $State = New-RecoveryState $Config $Request.target $Request.runId $Now
            $State.closedRunIds = @($history)
            Write-DurableJson $StatePath $State
            Write-DemoEvent 'RecoveryArmed' @{ target = $Request.target; runId = $Request.runId; deadlineUtc = $State.deadlineUtc }
        }
        'Disable' {
            Assert-RunMatches $State $Request $Config
            if ($State.phase -ne 'Armed' -or $Now -ge [datetimeoffset]::Parse($State.deadlineUtc)) { throw 'Only an unexpired, independently armed run can disable once.' }
            if (($Now - $Heartbeat).TotalSeconds -gt 20) { throw 'Watchdog heartbeat is stale; refusing disable.' }
            $State.phase = 'Disabling'
            $State.uncertainMutation = $true
            $State.readRestored = $false
            Write-DurableJson $StatePath $State
            try {
                Set-KeyEnabled $Config $Request.target $false
                $State.phase = 'Disabled'
                $State.keyEnabled = $false
                $State.uncertainMutation = $false
                Write-DemoEvent 'KeyDisabled' @{ target = $Request.target; runId = $Request.runId; deadlineUtc = $State.deadlineUtc }
            } catch {
                $State.phase = 'Recovering'
                $State.lastError = $_.Exception.Message
                Write-DurableJson $StatePath $State
                throw
            }
            Write-DurableJson $StatePath $State
        }
        'Restore' {
            Assert-RunMatches $State $Request $Config
            if ($State.phase -eq 'Closed') { throw 'Closed runs cannot be changed.' }
            $State.phase = 'Recovering'
            Write-DurableJson $StatePath $State
            $State = Invoke-RecoveryTick $Config $State $StatePath $Now
        }
        'Read' { $read = Read-DemoBlob $Config $Request.target }
        'Reset' {
            Assert-RunMatches $State $Request $Config
            if ($State.phase -ne 'Recovered' -or $State.uncertainMutation -or -not $State.recoveredSinceUtc -or
                ($Now - [datetimeoffset]::Parse($State.recoveredSinceUtc)).TotalSeconds -lt 60) {
                throw 'Reset requires 60 seconds of confirmed recovery and no uncertain mutation. An uncertain run requires manual investigation, not an automatic reset.'
            }
            if ((Get-KeyAttributes $Config $Request.target).enabled -ne $true -or
                (Read-DemoBlob $Config $Request.target).status -ne 200) { throw 'Reset refused: fresh key/read verification failed.' }
            $State.phase = 'Closed'
            Write-DurableJson $StatePath $State
        }
        'Status' { }
    }
    return @{ state = $State; read = $read }
}

Export-ModuleMember -Function Write-DurableJson, Write-DemoEvent, Invoke-DemoHttp, Get-DemoToken,
    Get-KeyAttributes, Set-KeyEnabled, Assert-StorageKeyBinding, Read-DemoBlob, New-RecoveryState,
    Assert-RunMatches, Initialize-RecoveryState, Invoke-RecoveryTick, Invoke-WorkerRequest
