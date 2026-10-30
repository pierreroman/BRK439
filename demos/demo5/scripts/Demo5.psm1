#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-D5Az {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Arguments)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required. Install it through your approved process, then run az login.'
    }
    $result = & az @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed with exit code $LASTEXITCODE. No sample evidence will be substituted." }
    if (-not $result) { throw 'Azure CLI returned no JSON.' }
    return ($result -join "`n" | ConvertFrom-Json -AsHashtable -DateKind String)
}

function Assert-D5Context {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SubscriptionId, [Parameter(Mandatory)][string] $TenantId)
    $account = Invoke-D5Az @('account', 'show', '--subscription', $SubscriptionId)
    if ($account['id'] -ne $SubscriptionId -or $account['tenantId'] -ne $TenantId -or
        $account['state'] -ne 'Enabled' -or $account['environmentName'] -ne 'AzureCloud') {
        throw 'Wrong tenant/subscription, disabled subscription or non-public Azure environment. This kit targets an explicitly selected Azure public-cloud demo subscription.'
    }
    return $account
}

function Get-D5Window {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $StartUtc, [Parameter(Mandatory)][string] $EndUtc)
    foreach ($value in @($StartUtc, $EndUtc)) {
        if ($value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
            throw 'Use an explicit UTC timestamp: yyyy-MM-ddTHH:mm:ssZ.'
        }
    }
    $start = [DateTimeOffset]::ParseExact($StartUtc, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    $end = [DateTimeOffset]::ParseExact($EndUtc, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    if ($end -le $start -or ($end - $start).TotalHours -gt 24) { throw 'Choose a positive audit window no longer than 24 hours.' }
    if ($start -lt [DateTimeOffset]::UtcNow.AddDays(-89)) { throw 'This query targets recent Activity Log history. Use your configured archive for older evidence.' }
    if ($end -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { throw 'Audit window end cannot be in the future.' }
    return @{ start = $StartUtc; end = $EndUtc }
}

function Get-D5LockboxEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Events)
    return @($Events | Where-Object {
        ($_['resourceProviderName'] -and $_['resourceProviderName']['value'] -eq 'Microsoft.CustomerLockbox') -or
        ($_['operationName'] -and $_['operationName']['value'] -like 'Microsoft.CustomerLockbox/*')
    })
}

function Select-D5DenialEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Events,
        [Parameter(Mandatory)][string] $EventDataId,
        [Parameter(Mandatory)][string] $CorrelationId,
        [Parameter(Mandatory)][string] $SubscriptionId
    )
    $selected = @(Get-D5LockboxEvents $Events | Where-Object { $_['eventDataId'] -eq $EventDataId })
    if ($selected.Count -ne 1) { throw 'The exact selected Lockbox event was not found uniquely. No evidence bundle was written.' }
    $event = $selected[0]
    if ($event['subscriptionId'] -ne $SubscriptionId -or $event['correlationId'] -ne $CorrelationId) {
        throw 'The selected event does not match the requested subscription and correlation ID.'
    }
    $operation = $event['operationName']
    if (-not $operation -or ($operation['value'] -notmatch '(?i)(^|[/._-])deny([/._-]|$)' -and
        $operation['localizedValue'] -ne 'Deny Lockbox Request')) {
        throw 'The selected event is not a recognized Deny Lockbox Request operation. Inspect the raw portal JSON; do not substitute a generic update or approval event.'
    }
    if (-not $event['status'] -or $event['status']['value'] -ne 'Succeeded' -or [string]::IsNullOrWhiteSpace($event['caller'])) {
        throw 'The selected denial event is not Succeeded or has no caller identity. Wait for the final event and inspect it in the portal.'
    }
    return $event
}

function Write-D5Evidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Bundle,
        [Parameter(Mandatory)][string] $Directory
    )
    if (Test-Path -LiteralPath $Directory) { throw 'Evidence destination already exists. Choose a new directory; previous captures are never overwritten.' }
    $fullPath = [IO.Path]::GetFullPath($Directory)
    [void][IO.Directory]::CreateDirectory($fullPath)
    $jsonPath = Join-Path $fullPath 'evidence.json'
    [IO.File]::WriteAllText($jsonPath, ($Bundle | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false))
    $hash = (Get-FileHash -LiteralPath $jsonPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText((Join-Path $fullPath 'evidence.sha256'), $hash, [Text.UTF8Encoding]::new($false))
    return $jsonPath
}

function Read-D5Evidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Directory)
    $jsonPath = Join-Path $Directory 'evidence.json'
    $hashPath = Join-Path $Directory 'evidence.sha256'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        throw 'Captured evidence or its checksum is missing. No synthetic fallback is available.'
    }
    $expected = (Get-Content -LiteralPath $hashPath -Raw).Trim()
    if ($expected -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $jsonPath -Algorithm SHA256).Hash -cne $expected.ToUpperInvariant()) {
        throw 'Evidence checksum mismatch. Do not present this file as an intact capture.'
    }
    $bundle = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    if ($bundle['schema'] -ne 1 -or $bundle['provenance'] -ne 'Azure Activity Log capture' -or -not $bundle['selectedEvent']) {
        throw 'Unsupported or incomplete evidence bundle.'
    }
    $null = Select-D5DenialEvent -Events @($bundle.selectedEvent) -EventDataId $bundle.eventDataId -CorrelationId $bundle.correlationId -SubscriptionId $bundle.subscriptionId
    return $bundle
}

Export-ModuleMember -Function Invoke-D5Az, Assert-D5Context, Get-D5Window, Get-D5LockboxEvents, Select-D5DenialEvent, Write-D5Evidence, Read-D5Evidence
