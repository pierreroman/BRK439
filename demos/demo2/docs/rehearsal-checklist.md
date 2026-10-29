# Rehearsal, recording and evidence checklist

Status: **checklist only; no live checks or recordings completed by this kit**.
Each item requires real evidence after separate authorization.

## Go/no-go gates

- [ ] Dedicated demo subscription/resource allowlist, tenant and approved regions.
- [ ] Current price/retention estimate approved, confidential image/SKU and quota verified.
- [ ] Approved private access, DNS, egress and trusted SSH host fingerprint.
- [ ] Separate deployment admin, restricted operator and manual recovery identity.
- [ ] HSM activated; three or more RSA wrapping key pairs/quorum approved and
      private material/security domain kept outside git and attachments.
- [ ] Demo exception explicitly labeled: four disposable pairs, 3-of-4 threshold,
      one operator (not separate custodians). Portable setup has a fresh local
      AES-encrypted PFX, separately retained backup, RSA restore challenges and
      additional CMS domain encryption/readability verification. Private wrapping
      keys never go to the guest. The legacy VM-held raw-key design is not reused.
- [ ] Persistent LUN-0 disk mapping/mount/permissions and reboot persistence
      verified; raw guest domain removed only after independent backup receipt.
- [ ] Temporary bootstrap local/ARM grants removed and identity detached;
      controller, storage and separate manual recovery scopes checked.
- [ ] Distinct pinned keys and storage bindings; both independent baseline reads.
- [ ] HSM local RBAC scopes and actual key read/write behavior verified.
- [ ] Real policy positive control and isolated Deny evidence for each negative case.
- [ ] Restricted operator cannot execute shell, SFTP, forwarding, arbitrary
      PowerShell arguments, service edits or state/config/response writes.
- [ ] Service has read-only code/config and required durable state/queue permissions.
- [ ] Healthy NTP, heartbeat in syslog tagged demo2 and AMA pipeline ingestion.
- [ ] Missing-heartbeat and overdue-recovery alerts reach the external operator.
- [ ] Arm persists fixed deadline before Disable, rejects replay/overlap/expired runs.
- [ ] Double click, malformed commands and unauthorized key versions rejected.
- [ ] Button termination, laptop/tunnel loss, watchdog restart and host reboot tested.
- [ ] Timeout/uncertain Disable retains intent; recovery reconciles late completion.
- [ ] Corrupt-state path blocks new disables and invokes manual recovery procedure.
- [ ] Key enabled acknowledgment distinguished from later fresh storage 200.
- [ ] Manual operator exact-version restore verified without deleting/rotating keys.
- [ ] Recovery continuous reconciliation and 60-second settling gate before Reset proven.
- [ ] Uncertain mutations remain ineligible for automatic Reset even after
      apparently restored reads; separate manual investigation is required.
- [ ] Twin prepared under its own finite deadline and genuinely denied at stage readiness.
- [ ] Genuine recording created, matching transcript, disclosures and offline playback verified.
- [ ] SCP access/tenant/preview messaging verified or closing cue explicitly omitted.

Host-outage limitation is accepted, not tested away. Never interrupt a recovery
host with an unresolved live run except in a separately approved fault exercise
with manual recovery already available.

## Sanitized evidence schema

Retain real UTC events and correlation IDs outside source control. Do not log
tokens, document plaintext, wrapping private keys/security domain or SKR payloads.

| Field | Meaning |
|---|---|
| `runId` | GUID shared by Arm/Disable/Restore/Reset for that run; fresh GUID for the next Arm. |
| `target`, `account`, pinned key identifier | Explicit Live/Twin and exact dedicated version; labels never change implicitly. |
| `phase`, `deadlineUtc`, `heartbeatUtc` | Observed worker state and fixed recovery deadline, not a maximum-outage promise. |
| `keyEnabled`, `readRestored` | Separate recovery observations; do not conflate API mutation success and real read success. |
| `read.status`, `errorCode` | Real HTTP status and Azure error; DNS/auth/transport exceptions remain exceptions, never a fabricated 403. |
| `requestId`, `clientRequestId`, `utc` | Actual storage service/caller correlation and fresh request timestamp. |
| `error`, native exit status | Explicit controller/SSH/CLI failure, including unknown outcomes/timeouts. |
| Policy definition/assignment/evaluated condition | Distinguishes intended Deny from unrelated validation or permission failures. |

The host JSON response is `ok/action/target/runId/state/read/heartbeatUtc/error`.
`read` can contain content for UI rendering; **do not persist the raw response
as telemetry**. The native panel projects evidence fields separately from
plaintext. A nonzero request does not establish that no mutation occurred.
The daemon removes response JSON files after five minutes; response queues
are not an evidence archive. Capture sanitized evidence externally before
depending on it for rehearsal/recording verification, and validate the
independent telemetry pipeline and its retention policy.

For the record, retain four distinct timings: Disable acknowledgment, first
genuine denied Get Blob, enable acknowledgment, first restored Get Blob.
Daily key-version polling/rotation overlap is not the same as propagation of
disabling or enabling a pinned version.

## Recording and retirement

Use synthetic content. Record genuine requests, not mocked outcomes. Disclose
edits/acceleration and retain an unedited sanitized evidence transcript. Verify
offline playback before promising a recording fallback.

After rehearsal, Restore and verify Live and Twin separately. The watchdog keeps
enabling/reconciling each recovered key until its run is eligible for Reset.
Require 60 seconds of continuous recovery and a fresh key/read verification.
An uncertain mutation blocks automatic Reset and requires manual investigation;
do not edit its flag/state to bypass that restriction. Do not automatically destroy
resources: obtain retirement approval and account for HSM soft-delete retention,
purge protection and continued billing.
