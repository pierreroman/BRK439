# Demo 5 - Presenter cheat sheet

**Mode: real Azure Customer Lockbox request, manual portal Deny, actual audit log.**
This sheet covers a **subscription-scoped request**. Tenant-scoped requests use
Entra audit logs and a different approver path; see [the setup guide](../README.md).

**The moment:** click **Deny** on the agreed provider-access request, then show
the decision's audit trail. **There is no reset for a denied request.**

## 1. Arrange the demo before the event

1. Coordinate a sanctioned demo with your Microsoft account/support/product team.
   Ask whether a genuine request can be arranged and when it will be pending.
   A normal support ticket does not guarantee a Lockbox request.
2. Use a dedicated demo tenant/subscription and supported service. Confirm the
   current support-plan requirements and authorized Lockbox enablement.
3. Have the authorized Global Administrator enable Customer Lockbox through its
   Administration module if required. This is a tenant-wide governance change;
   the scripts do not perform it.
4. Ensure the presenter has subscription Owner or **Azure Customer Lockbox
   Approver for Subscription** at supported subscription scope. Assign/activate
   required PIM roles **before Microsoft processes the request**.
   Adding the role later does not fix that existing request's approver snapshot.
5. Confirm the presenter also has permission to read the subscription Activity
   Log. Do not assume approval permission alone grants every audit-read right.
6. Arrange a separate rehearsal request if possible. Capture an approved
   recording and its corresponding audit event for fallback.
7. Check the stage request's expiry. Pending requests expire after four days.
   **Do not deny the stage request during rehearsal.**

**Go/no-go:** without a genuine pending request and recognized approver, there
is no live Deny demonstration. Use an approved recording, explicitly labelled
recorded, or explain the workflow without claiming a live action.

## 2. Prepare the operator terminal

1. Open **PowerShell 7.5+** and authenticate:

   ```powershell
   Set-Location D:\git\BRK439
   az login
   $subscription = '<demo-subscription-GUID>'
   $tenant = '<demo-tenant-GUID>'
   ```

   Substitute the repository path if different. Replace placeholders before
   running commands. Keep this terminal off-projector until content is approved.

2. Run the offline checks:

   ```powershell
   .\demos\demo5\tests\Invoke-OfflineChecks.ps1
   ```

   **Expect:** passing tests and PowerShell analysis. These use fixtures/mocks;
   they do not create or deny real requests.

3. Run the read-only preparation:

   ```powershell
   .\demos\demo5\Start-Demo.ps1 -Mode Prepare `
     -SubscriptionId $subscription -TenantId $tenant
   ```

   **Expect:** correct target IDs/name, an advisory role list and readiness
   warnings. This does **not** prove enablement, eligibility or a pending request.

4. Open the real portal:

   ```powershell
   .\demos\demo5\Start-Demo.ps1 -Mode OpenPortal `
     -SubscriptionId $subscription -TenantId $tenant
   ```

   **Expect:** Customer Lockbox Administration opens.
   **Verify the browser account and directory separately from Azure CLI.**
   The launcher does not force the browser into the CLI's identity.

5. If you have a captured rehearsal bundle, record its actual path now:

   ```powershell
   $rehearsalEvidence = '<full-path-to-approved-rehearsal-evidence-directory>'
   ```

   Test replay off-projector:

   ```powershell
   .\demos\demo5\Start-Demo.ps1 -Mode ShowEvidence `
     -EvidenceDirectory $rehearsalEvidence
   ```

   **Expect:** `RECORDED EVIDENCE - NOT A LIVE DENIAL OR LIVE QUERY` followed by
   the recorded event. If no capture exists, this fallback is unavailable.

## 3. Prepare the portal without consuming the request

1. Select the intended demo directory and subscription.
2. Open **Pending Requests** and select the agreed demo request.
3. Verify with your coordinating team:

   | Field / check | Required result |
   | --- | --- |
   | Request ID | Exactly the agreed stage request |
   | Service request / support case | The authorized demo case |
   | Resource scope | Intended demo resources only |
   | Reason and requested duration | Expected and understood |
   | Status / expiry | Pending and not expired |
   | Approver | Presenter recognized; **Deny** available |

4. Keep that request open. **Do not click Deny yet.**
5. In another tab, open the target subscription's **Activity Log**.
   Set a time range covering the upcoming demo. Rehearse opening event details
   and JSON, but do not assume the eventual denial event already exists.
6. Prepare the approved Data Guardian slide. This is explanation only, not a
   demo or inspection of Microsoft's internal controls.
7. Review what may be projected. Raw audit JSON can contain caller identities,
   claims, resource names and support metadata. Use an approved redacted view
   if necessary; do not call redacted content an untouched raw export.

Portal layout may change. The reliable targets are the actual pending Lockbox
request and subscription Activity Log, **not the removed History tab**.

## 4. Perform the demo - exact sequence

### Show the pending request

1. Put the pending-request page on the audience screen.
2. Point to the reason, resource scope and requested duration. Show only approved
   request/case identifiers; avoid unnecessary personal or support information.

   **Say:**

   > "Microsoft support requested elevated access for this specific demo case.
   > We can inspect why, for which scope, and for how long. This is the customer
   > approval gate for this request, not a claim about every provider operation."

3. Verify once more that the selected request is the agreed **demo** request.
   If anything differs, stop. Do not select an unrelated request for the show.

### The Deny moment

4. On the operator terminal, record the start of the audit window:

   ```powershell
   $start = [DateTime]::UtcNow.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
   ```

   Keep this PowerShell session open for the later commands.

5. In the portal, click **Deny**.
6. Read and complete any confirmation for the **same request**.
7. Wait for the actual portal outcome. Confirm that it reports the request
   denied; do not treat clicking the button as proof of success.

   **Say only after the outcome is confirmed:**

   > "We denied this elevated support-access request. The support work requiring
   > that access cannot proceed through this request."

If the portal fails or the request has expired, explain the actual result.
Do not narrate a successful denial or attempt to recreate the request yourself.

### Show the decision audit trail

8. Switch to the prepared subscription **Activity Log** tab.
9. Refresh and locate **Deny Lockbox Request** within the demo's time window.
10. Open the actual event. Confirm:
    - Correct subscription/resource/request context.
    - Timestamp and **Succeeded** status.
    - Caller: the **customer decision maker**, not automatically the engineer.
    - Event ID, correlation ID and the relationship to the Lockbox/support case.
11. Show the approved event details or JSON.

   **Say:**

   > "An auditor can ask who decided, when, for what scope, and what the outcome
   > was. This is the denial's decision record, not a complete log of every
   > customer-data access or proof that nobody accessed anything."

Audit ingestion can lag. If the event has not arrived, say so and refresh
deliberately. Use the explicitly recorded rehearsal evidence if needed; do not
claim a different event belongs to this denial.

### Explain Data Guardian and close

12. Show the approved **Data Guardian** slide.
13. Explain only the approved distinction between customer-visible Lockbox
    decisions and Microsoft's internal controls. No internal control is being
    configured or inspected here.
14. Close:

   > "Ask who requested access, who decided, what scope and duration were involved,
   > and where the evidence lives. Sovereignty needs an operating process, not
   > just a location label."

Mention documented Lockbox exclusions, including certain emergencies. Do not
promise a universal customer veto over all Microsoft operations.

## 5. Capture the real denial evidence - preferably off-projector

1. Once the event is available, set the current end of the window:

   ```powershell
   $end = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
   .\demos\demo5\Start-Demo.ps1 -Mode ListEvents `
     -SubscriptionId $subscription -TenantId $tenant `
     -StartUtc $start -EndUtc $end
   ```

   **Expect:** Lockbox event fields, including operation, status, caller,
   **EventDataId**, **CorrelationId** and resource ID. No events is an error,
   not proof of no access.

2. In portal JSON, verify that the exact successful denial event belongs to your
   request/support case. Copy its IDs; **CorrelationId is not RequestId**.
3. Set the actual values and create a fresh evidence destination:

   ```powershell
   $requestId = '<actual-Lockbox-request-ID>'
   $eventId = '<exact-successful-denial-event-ID>'
   $correlationId = '<that-events-correlation-ID>'
   $evidence = Join-Path $env:LOCALAPPDATA `
     ('BRK439\Demo5\denial-' + [Guid]::NewGuid().ToString('N'))

   .\demos\demo5\Start-Demo.ps1 -Mode ExportEvidence `
     -SubscriptionId $subscription -TenantId $tenant `
     -StartUtc $start -EndUtc $end `
     -RequestId $requestId -EventDataId $eventId `
     -CorrelationId $correlationId -ConfirmRequestCorrelation `
     -EvidenceDirectory $evidence
   ```

   **Expect:** `Captured actual successful denial event` and a path to the
   JSON bundle. The request linkage is your attestation; the script does not
   independently correlate the supplied request ID.

4. Validate recorded replay:

   ```powershell
   .\demos\demo5\Start-Demo.ps1 -Mode ShowEvidence `
     -EvidenceDirectory $evidence
   ```

   **Expect:** the recorded-evidence banner and selected event. The sidecar
   checksum detects file changes; it is not a trusted signature or immutable
   archive. Protect the capture and preserve source logs under your audit policy.

If reopening PowerShell later, restore the actual IDs and window values;
variables from this session are not saved automatically. Keep captures out of
Git. Do not overwrite or casually delete an earlier audit capture.

## 6. Quick recovery and fallback

| What happened | Exact action |
| --- | --- |
| No genuine pending request | Use an approved recording or explain the workflow. Do not manufacture an incident or deny an unrelated request. |
| Request expired / already denied | It cannot be reset. Use the recording; coordinate a new authorized request separately. |
| Deny unavailable | Check actual account, scope and pre-existing approver eligibility. A new role assignment does not fix that request retroactively. |
| CLI target correct, portal target wrong | Switch the browser to the intended account/directory and reverify the request before any decision. |
| No audit event yet | Acknowledge ingestion delay, refresh and widen only the relevant time window if necessary. Use recorded evidence honestly. |
| Query reaches event cap | Narrow the UTC window or explicitly adjust `-MaxEvents`; do not present incomplete results as a complete audit. |
| Export rejects the event | Inspect actual operation/status/IDs. Do not relabel an approval, failed or unrelated event as a successful denial. |
| Evidence directory already exists | Choose a new destination. Earlier captures are intentionally not overwritten. |
| Checksum mismatch | Do not present the file as an intact capture. Recover from the approved original/source logs. |
| Request is tenant-scoped | Use the separate Entra audit workflow in [the setup guide](../README.md); this script exports subscription Activity Log only. |

**Recorded fallback command:**

```powershell
.\demos\demo5\Start-Demo.ps1 -Mode ShowEvidence `
  -EvidenceDirectory $rehearsalEvidence
```

**Say:** "This is recorded evidence from the earlier approved rehearsal, not a
live denial or live query." Show its approved recording if available. If no
recording/bundle exists, use the slide and explain the workflow.

Afterward, retain evidence according to policy. Do not disable tenant Lockbox or
remove roles automatically; any governance change needs its approved process.

**One-line memory aid:** Verify genuine pending request -> Verify approver/scope
-> Deny once -> Confirm outcome -> Find successful audit event -> Explain
Data Guardian on slide -> Preserve evidence.
