#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'OpenPortal', 'ListEvents', 'ExportEvidence', 'ShowEvidence')][string] $Mode,
    [string] $SubscriptionId,
    [string] $TenantId,
    [string] $StartUtc,
    [string] $EndUtc,
    [string] $RequestId,
    [string] $EventDataId,
    [string] $CorrelationId,
    [string] $EvidenceDirectory,
    [ValidateRange(1, 10000)][int] $MaxEvents = 1000,
    [switch] $ConfirmRequestCorrelation,
    [switch] $NoBrowser
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Demo5.psm1') -Force

if ($Mode -eq 'ShowEvidence') {
    if (-not $EvidenceDirectory) { throw 'Supply -EvidenceDirectory for the recorded evidence bundle.' }
    $bundle = Read-D5Evidence $EvidenceDirectory
    Write-Host 'RECORDED EVIDENCE - NOT A LIVE DENIAL OR LIVE QUERY' -ForegroundColor Yellow
    Write-Host 'Local checksum checked. This is not a signature, immutable archive or proof that the collector was trustworthy.'
    Write-Host "Captured: $($bundle.capturedAtUtc); request ID supplied/linked by operator: $($bundle.requestId)"
    Write-Output ($bundle.selectedEvent | ConvertTo-Json -Depth 60)
    return
}
foreach ($id in @($SubscriptionId, $TenantId)) {
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($id, [ref]$parsed)) { throw 'Supply explicit GUID values for -SubscriptionId and -TenantId.' }
}
$account = Assert-D5Context -SubscriptionId $SubscriptionId -TenantId $TenantId
Write-Host "Target tenant: $TenantId; subscription: $SubscriptionId ($($account.name))."

if ($Mode -in @('Prepare', 'OpenPortal')) {
    Write-Host 'Real Deny action is performed by you in the Azure portal. This script never approves, denies, enables Lockbox or creates a support request.'
    Write-Host 'Confirm Lockbox is enabled tenant-wide, supported service/support plan, and approver assignment/PIM activation BEFORE Microsoft processes a request.'
    Write-Host 'No customer-facing synthetic pending-request deployment is provided. Coordinate an authorized demo with Microsoft; an ordinary support ticket does not guarantee a request.'
    Write-Host 'Pending requests expire after four days. Deny only the agreed demo request; it cannot be reset for rehearsal.'
    if ($Mode -eq 'Prepare') {
        $user = Invoke-D5Az @('ad', 'signed-in-user', 'show', '--query', 'id')
        $roles = Invoke-D5Az @('role', 'assignment', 'list', '--subscription', $SubscriptionId, '--assignee', $user, '--include-groups', '--include-inherited', '--scope', "/subscriptions/$SubscriptionId")
        @($roles) | Select-Object roleDefinitionName, scope | Format-Table -AutoSize | Out-Host
        Write-Host 'Role list is advisory: current roles do not prove eligibility for an already-created request. Management-group-scoped assignments are not supported for Lockbox approval.'
        Write-Host 'This does NOT verify Lockbox enablement, support eligibility, pending requests, approver snapshot or permission to view all audit events. Verify these in the portal.'
    }
    $url = 'https://aka.ms/customerlockbox/administration'
    Write-Host "Portal: $url"
    Write-Host 'The browser can use a different account/directory from Azure CLI. Verify the tenant, subscription, support case, request ID, expiry and scope on screen before Deny.'
    if ($Mode -eq 'OpenPortal' -and -not $NoBrowser) { Start-Process -FilePath $url }
    return
}

$window = Get-D5Window -StartUtc $StartUtc -EndUtc $EndUtc
$events = @(Invoke-D5Az @('monitor', 'activity-log', 'list', '--subscription', $SubscriptionId, '--start-time', $window.start, '--end-time', $window.end, '--max-events', "$MaxEvents"))
if ($events.Count -ge $MaxEvents) {
    throw "Query reached its $MaxEvents event cap. Narrow the UTC window or increase -MaxEvents. A potentially incomplete query will not be exported."
}
$lockbox = @(Get-D5LockboxEvents $events)
if (-not $lockbox.Count) {
    throw 'No Lockbox Activity Log events found in this subscription/window. Audit ingestion can lag. Retry deliberately, check permissions/scope, or use Entra audit logs for a tenant-scoped request. This is NOT proof that nobody accessed data.'
}
$lockbox | ForEach-Object {
    [pscustomobject]@{
        TimeUtc = $_['eventTimestamp']; Operation = $_['operationName']['value']
        Status = $_['status']['value']; Caller = $_['caller']
        EventDataId = $_['eventDataId']; CorrelationId = $_['correlationId']
        ResourceId = $_['resourceId']
    }
} | Format-List | Out-Host
if ($Mode -eq 'ListEvents') { return }
if (-not $RequestId -or -not $EventDataId -or -not $CorrelationId -or -not $EvidenceDirectory -or -not $ConfirmRequestCorrelation) {
    throw 'Export requires -RequestId, -EventDataId, -CorrelationId, a new -EvidenceDirectory and -ConfirmRequestCorrelation after you verify the event/request link in the portal JSON. Nothing was exported.'
}
$selected = Select-D5DenialEvent -Events $lockbox -EventDataId $EventDataId -CorrelationId $CorrelationId -SubscriptionId $SubscriptionId
$bundle = @{
    schema = 1; provenance = 'Azure Activity Log capture'; capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    tenantId = $TenantId; subscriptionId = $SubscriptionId; requestId = $RequestId
    eventDataId = $EventDataId; correlationId = $CorrelationId
    requestLink = 'Operator verified in portal; the supplied request ID is not independently correlated by this script.'
    query = @{ startUtc = $window.start; endUtc = $window.end; maxEvents = $MaxEvents; returnedEvents = $events.Count }
    selectedEvent = $selected
    relatedLockboxEvents = $lockbox
    limitations = 'A successful denial audit event is a control-plane decision, not a complete customer-data-access log, a tenant-wide search, or proof of zero access. Local SHA-256 detects accidental file changes only; it is not signed or immutable.'
}
$path = Write-D5Evidence -Bundle $bundle -Directory $EvidenceDirectory
Write-Host "Captured actual successful denial event: $path"
Write-Host 'Contains raw caller/claims/properties and potentially sensitive support metadata. Keep outside Git, restrict filesystem access and review before projecting or sharing.'
