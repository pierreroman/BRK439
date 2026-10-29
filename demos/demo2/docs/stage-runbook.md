# Demo 2: Stage, rehearsal and recording runbook

Adapted from the approved session draft for the offline native control kit.
**No infrastructure, live outcomes, video recording or Sovereign Control Panel
access was created or verified during implementation.**

## Five-minute stage contract

Five minutes includes the requested **30-second SCP closing cue**. This is a
presentation budget, not a promise of Azure propagation or deployment speed.
Provisioning, HSM activation and initial policy propagation happen off-clock.
Optional SKR Q&A is outside this slot.

Always show selected account, Live/Twin label, latest real HTTP result/request
IDs, run ID, UTC recovery deadline and latest watchdog heartbeat. Never show
tokens, security-domain artifacts, private wrapping keys or released key material.

| Budget | Cue / operator action | Evidence / spoken point |
|---|---|---|
| 0:00–0:30 | Show approved region, policies, CMK bindings, confidential VM. | Say real SLZ or sandbox approximation. An allowed SKU screenshot alone is not attestation. |
| 0:30–1:10 | Run prepared disallowed-region and allowed-region platform-managed-key negative cases. | Show each `RequestDisallowedByPolicy` with the correct definition/assignment and evaluated condition, not generic errors. Platform-managed encryption is still encryption; the demo requires customer control. |
| 1:10–1:40 | Select Live; Refresh Document. | Fresh authenticated 200 renders synthetic text. Keep identity/network unchanged. |
| 1:40–2:00 | Arm new run; verify durable acknowledgment and deadline; press BIG RED BUTTON. | Independent VM recovery exists before Disable. Show exact dedicated version and accepted mutation. |
| 2:00–3:30 | Refresh Document and explain the actual result. | If 200 persists, say propagation is not yet effective. Do not change RBAC/network to manufacture failure. |
| 3:30–4:30 | Restore, or observe the already-fixed deadline; refresh. | Distinguish KEY_ENABLED from STORAGE_READ_RESTORED. No recovery claim without a fresh 200. If needed, explicitly choose genuine Twin fallback. |
| 4:30–5:00 | Verified SCP view, if genuinely available. | Say **“preview”** aloud. Show posture/gaps only. SCP is not the mechanism that disabled the key. |

Adjust narration in rehearsal, not safety deadlines on stage. The sample Live
180-second deadline may outlast a short cue; explicit Restore is available.
A fixed deadline can fire before a denied read; that is a valid no-go for the
live moment, not a reason to fake evidence.

When a fresh read actually fails, say: “The data is still in-region. Once the
key change takes effect, this service can no longer decrypt it at rest.”
CMK wraps the account encryption key. Previously downloaded plaintext is not
recalled; the native window clears old text before every Refresh.

## Rehearsal go/no-go

1. Obtain explicit deployment/live-change approval and review current prices,
   service availability, quota, confidential SKU/image and region choices.
2. Provision in stages, activate HSM under the approved custody arrangement and
   confirm protected security-domain custody without recording private material.
   Label this kit's approved single-operator online custody as a demo exception,
   not four-custodian control. Verify the persistent mount and the encrypted
   offline wrapping-key recovery copy before activation. The activation download
   produces the security-domain file; protect and back it up immediately afterward,
   before CMKs or demo data.
3. Verify inherited SLZ or sandbox assignments, Deny effects, enforcement,
   exemptions and propagation. Rehearse a compliant positive control.
4. Run isolated negative cases; naming/template/authentication/firewall errors
   are no-go evidence for the intended policy demonstrations.
5. Verify private DNS/tunnel, document identity and Storage-to-HSM trusted
   service configuration; hold them constant during key exercises.
6. Prove both baseline reads with independent pinned keys enabled. Confirm
   restoring one key does not restore the other account.
7. Verify durable intent, current heartbeat, fixed deadline, restart-on-failure,
   startup reconciliation, NTP, manual recovery and independent alerts.
   In a dedicated authorized rehearsal, terminate the laptop/button and tunnel,
   and prove the VM restores the key and a fresh read eventually works.
8. Measure real key acknowledgment, first denied read, restore acknowledgment
   and first restored read separately. Never infer propagation from a timer.
9. Prepare Twin separately: baseline 200, Arm its finite recovery, Disable its
   own key, observe real denial. Reconfirm denial, heartbeat and enough remaining
   deadline before stage use. Do not leave Twin indefinitely disabled.
10. Capture and verify a genuine recorded run, with offline playback and a
    matching evidence transcript. **No such recording ships with this kit.**
11. Verify SCP tenant authorization and current preview messaging. Requested
    Ignite opening/access dates are **unverified**, not confirmed product facts.

Use [the detailed checklist](rehearsal-checklist.md). Offline parsing/compilation
alone does not satisfy these gates.

## If Live does not produce the moment

Never extend a deadline silently or repeat Disable. Explicitly select Twin,
keep **PRE-REVOKED FALLBACK ACCOUNT** visible, and say:
“This is the pre-revoked fallback account; its key was disabled in advance.”
Refresh it and show its actual storage result.

Twin does not establish how quickly Live propagated. Restore Live independently
and report its actual state. If Twin is not genuinely denied, is already
restored, or has insufficient remaining validity, use a verified recording of
a real run **only if one has been made**. Otherwise explain the limitation and
skip the moment. Never substitute a synthetic 403 or stale screenshot.

## Recovery operations

The host shares the access VM; its boot disk/state/telemetry are independent of
both CMKs. The fixed timeout initiates recovery only while that host and its
dependencies remain healthy. It is not an absolute maximum-outage guarantee.

If heartbeat disappears or recovery is overdue:

1. Stop new disables. Keep recovery intent intact.
2. Use [separate manual recovery](operator-guide.md) over the approved route.
   Check tenant/subscription/HSM/key/version before enabling.
3. Confirm all disable requests are quiescent; reconcile any late mutation
   instead of trusting a one-shot enable response.
4. Verify enabled=true, then a new authenticated Get Blob. Report each separately.
5. Keep sanitized errors/request IDs and notify through independent monitoring.
   Not every 403 is CMK revocation.
6. If host/HSM/network/identity is unavailable, report recovery blocked.
   Use a verified recording if available; do not claim nonexistent evidence.

Never delete a key, weaken purge protection/SLZ controls, use production keys
or deallocate the recovery VM as part of this demonstration.

## Recording and SCP fallback

Record the same genuine sequence: isolated policy denials, baseline 200,
independent Arm, exact Disable, denied fresh read, exact enable and restored
fresh read. Disclose acceleration/edits; preserve an unedited sanitized
transcript with real propagation timestamps and correlation IDs.

Use synthetic content, hide tokens/private material/personal contacts, and
verify audio, legibility and offline playback. Do not claim a take exists
before recording and checking it.

For SCP, request private-preview access only if actually available. Capture
fallback after verifying entitlement. The requested Ignite days 1–2
rehearsal/recording path is conditional, not a confirmed opening date. If access
is absent, use a clearly labeled explanatory closing cue or omit it; do not
invent a portal recording, access entitlement or deployment.

## Optional off-clock SKR and final reset

Use the [separate specification](optional-skr.md), not a storage CMK export.
Both callers need equivalent authorization/reachability; prove attestation,
not a firewall difference. Never display or persist released private material.

Verify Live restored with a fresh read; restore Twin after its approved fallback
window/deadline and verify separately. Confirm no pending/uncertain mutations.
The watchdog keeps enabling/reconciling the recovered key until Reset. Reset
requires 60 seconds of continuous recovery plus fresh key/read verification.
An uncertain-mutation run is never automatically reset; investigate manually,
even if storage reads succeed. Do not edit state to bypass the restriction.
Do not clean up automatically:
HSM soft-delete retention/purge protection can continue billing. Resource
retirement is separately authorized.
