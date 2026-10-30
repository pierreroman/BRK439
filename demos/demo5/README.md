# Demo 5 - Who touched my system?

Real **Azure Customer Lockbox**, a manual portal **Deny**, and actual denial
audit evidence. This kit does not invent a pending request, approve/deny via
automation, enable tenant settings, assign roles or provision billable resources.
The optional operations agent is omitted. Data Guardian remains an explanation,
not a demo of Microsoft's internal controls.

## The prerequisite you cannot deploy

A Microsoft engineer's support-access workflow initiates a Lockbox request when
direct access to customer data is required. A customer support ticket alone
does **not** guarantee this; routine support often does not need such access.
There is no synthetic request creation feature supplied by this kit.

For an authorized demo, coordinate with your Microsoft account/support/product
team well ahead of the event. Ask whether they can arrange a sanctioned demo
request and timing. Do not create a fake outage, induce a production incident,
submit a misleading support ticket or assume a request can be scheduled.
If no genuine request can be staged, use an approved recording, explicitly
labelled as recorded. Without a real request there is **no live Deny moment**.

Requests remain pending for four days before expiring with no access granted.
Do not deny the stage request in rehearsal: denial consumes that request and
there is no reset. Use a separate authorized rehearsal request if available.

## Scope and permissions

This implementation covers **subscription-scoped requests in Azure public
cloud**. Tenant-scoped requests use **Microsoft Entra audit logs**, not the
subscription Activity Log; see the separate path below.

- Use a dedicated demo tenant/subscription, no sensitive customer workload.
- Azure support plan: at least Developer according to the current documentation.
  Verify current prerequisites and that your particular service is supported.
- A Global Administrator must enable Customer Lockbox through its
  [Administration module](https://aka.ms/customerlockbox/administration).
  This is a **tenant-wide governance change**, not a resource deployment. Obtain
  approval; do not enable or disable it just to make this script pass.
- Subscription-scoped approvers: subscription Owner or **Azure Customer Lockbox
  Approver for Subscription** at the supported subscription scope. Prefer the
  purpose-specific role where appropriate. Management-group-scoped assignments
  are not supported for this approval workflow.
- Assignments must be in place **before** Lockbox starts processing the request.
  Activate required PIM-eligible roles before initiation. Adding a role afterward
  does not retroactively make the user an approver for that request.
- Ensure the operator can read Activity Log at subscription scope. A Lockbox
  approval role alone should not be assumed to provide every audit-read right.
- Install PowerShell **7.5+**, Azure CLI, and authenticate with `az login`.
  The interactive preflight expects a signed-in human user; it does not support
  a service-principal-only login for the portal performance.

PowerShell 7.5 is required for JSON `-DateKind String`, so Azure timestamp text
is preserved instead of being silently converted during parsing. Exports retain
the returned event fields/values but are JSON reserialization, not byte-for-byte
copies of the HTTP response.

No Azure changes are made by these scripts. They use read-only CLI queries and
open a portal URL. **You** perform the irreversible decision manually after
checking the actual request. No live tenant operations were performed while
authoring this kit.

## Setup and rehearsal

Run from the repository root in PowerShell 7:

```powershell
az login
$subscription = '<demo-subscription-GUID>'
$tenant = '<demo-tenant-GUID>'
.\demos\demo5\Start-Demo.ps1 -Mode Prepare `
  -SubscriptionId $subscription -TenantId $tenant
```

The script validates the CLI tenant/subscription, shows an advisory role list
and prints readiness warnings. It does **not** prove enablement, support
eligibility, a pending request or your eligibility for an existing request.
Inspect these manually in the portal.

```powershell
.\demos\demo5\Start-Demo.ps1 -Mode OpenPortal `
  -SubscriptionId $subscription -TenantId $tenant
```

The browser can be signed in to a **different account/directory** than the CLI.
Verify both contexts. `-NoBrowser` prints the portal URL without opening it.

In the portal, verify:

1. The correct demo directory/subscription.
2. Lockbox enablement, a supported service and the actual pending request.
3. Request ID, support case ID, resource scope, reason, requested access duration
   and expiry. Confirm with the coordinating team that this is the stage request.
4. Approver account recognized and **Deny** available. Do not click it yet.
5. Access to Activity Log and its JSON detail view; rehearse navigating there
   without consuming the request. Expect audit ingestion delay after the decision.

Follow the [stage runbook](docs/stage-runbook.md) for the live Deny.

## Audit capture after denial

For a subscription-scoped request, the documented operations include **Deny
Lockbox Request**, **Create Lockbox Request**, **Approve Lockbox Request** and
**Lockbox Request Expiry**. The old Lockbox **History** tab is not a reliable
runbook target; current documentation says it was removed.

Choose a recent, narrow UTC window around the actual decision:

```powershell
$start = '<yyyy-MM-ddTHH:mm:ssZ>'
$end = '<yyyy-MM-ddTHH:mm:ssZ>'
.\demos\demo5\Start-Demo.ps1 -Mode ListEvents `
  -SubscriptionId $subscription -TenantId $tenant `
  -StartUtc $start -EndUtc $end
```

The query reads Activity Log for that subscription/time window and prints the
raw operation name, status, caller, event ID, correlation ID and resource ID
for Lockbox events. The window is capped at 24 hours and must be recent.
If the query hits `-MaxEvents` (default 1000), narrow the window or raise that
explicit limit; the script refuses potentially truncated results. An empty
query is an error, **not evidence of no access**. Ingestion may lag; retry
deliberately rather than promising instant logs on stage.

In the portal JSON, identify the exact successful denial event for your request.
Verify its request/resource/support-case link yourself; a correlation ID can
join operations but is not automatically the Lockbox request ID.

```powershell
$evidence = Join-Path $env:LOCALAPPDATA ('BRK439\Demo5\denial-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
.\demos\demo5\Start-Demo.ps1 -Mode ExportEvidence `
  -SubscriptionId $subscription -TenantId $tenant `
  -StartUtc $start -EndUtc $end `
  -RequestId '<actual-lockbox-request-ID>' `
  -EventDataId '<exact-denial-event-ID>' `
  -CorrelationId '<that-events-correlation-ID>' `
  -ConfirmRequestCorrelation -EvidenceDirectory $evidence
```

Export repeats the live query, requires a unique successful Lockbox Deny event,
checks caller/subscription/correlation and writes **raw** event data plus
query metadata and a SHA-256 sidecar. The request ID linkage is explicitly
operator-attested, not automatically verified. No prior evidence directory is
overwritten. If a partial write occurs, retain/inspect that directory and retry
to a **new** destination.

The conservative operation matcher accepts a `deny` segment in the raw
Lockbox operation name or the documented English `Deny Lockbox Request`
label. If your service returns a different schema/name, inspect actual JSON;
do not relabel an unrelated event or treat a failed/pending event as success.

### Recorded fallback

After a genuine rehearsal denial capture:

```powershell
.\demos\demo5\Start-Demo.ps1 -Mode ShowEvidence -EvidenceDirectory $evidence
```

This works offline, validates the sidecar checksum and prints **RECORDED
EVIDENCE — NOT A LIVE DENIAL OR LIVE QUERY** before the selected raw event.
No sample is provided. A checksum stored next to the file is **not** a trusted
signature, independently verifiable provenance or immutable audit archive.
Preserve source events using your approved retention/export controls.

The console shows the complete raw JSON, which may contain caller IDs, claims,
support metadata or sensitive resource names. Protect the local directory with
OS permissions; do not commit exports or share/project them without review.
Use approved redacted screenshots for the audience if raw details are unsuitable.
Do not label redacted or edited content as an untouched raw export.

## What this log proves

A successful **Deny** event records the customer decision on that specific
elevated support-access request. It is not a trace of everything Microsoft
employees did, a customer-data read log, or proof that nobody accessed anything.
Distinguish the customer decision maker's identity from the engineer requesting
access. For a fuller audit, correlate the request/support record, scope, decision,
timestamps, outcome and relevant service logs under your audit policy.

Customer Lockbox has documented exclusions, including emergency/break-glass
scenarios and some cases not requiring direct customer-data access. Do not say
"Microsoft can never access data without this button." Denying a real request
can prevent the support work that needed that access.

## Tenant-scoped request path (manual; not exported by this script)

For requests to access the **Entra tenant**, the designated approver is a Global
Administrator, not just subscription Owner. Verify eligibility before request
initiation. Use Entra **Audit logs**, filter **Service = Access Reviews**, and
inspect **Create request**, **Request approved** or **Request denied** with the
actual target/request/correlation details. Export through your approved Entra
audit workflow. Do not use unrelated Access Reviews events as Lockbox proof.
The subscription script intentionally errors if no subscription Lockbox events
exist; it does not query Graph or silently switch scopes.

## Data Guardian explanation, not an internal-control demo

Use your approved session slide to distinguish a customer decision through
Customer Lockbox from the Microsoft-internal controls described as Data Guardian.
Do not imply this script configures, inspects or validates Microsoft's internal
processes, and do not invent internal architecture or coverage claims.
Confirm exact terminology and slide wording with the product team.

## Checks and cleanup

```powershell
.\demos\demo5\tests\Invoke-OfflineChecks.ps1
```

Requires existing Pester 5+ and PSScriptAnalyzer. Tests use explicitly labelled
fixtures/mocks, not real requests or real denial evidence.

Live acceptance still requires an authorized real pending request, the actual
portal denial and the resulting successful audit event. Test recording fallback
before the event. No tenant settings/roles should be removed automatically after
the show; follow approved governance change control. Remove only intended local
captures according to retention policy. No infrastructure was deployed to tear
down.

### Official reference

[Customer Lockbox for Microsoft Azure: prerequisites, workflow, auditing and exclusions](https://learn.microsoft.com/azure/security/fundamentals/customer-lockbox-overview)

Recheck the current document and service support list before the event.
