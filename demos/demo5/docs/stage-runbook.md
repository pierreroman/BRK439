# Demo 5 - Who touched my system?

For exact commands and a numbered click-by-click sequence, use the
[presenter cheat sheet](presenter-cheat-sheet.md).

## Before the session

- Complete [setup](../README.md) with the Microsoft coordinating team.
- Confirm the genuine demo request is pending, not expired, and assigned to
  the stage operator. Approver roles/PIM must predate request processing.
- Verify the exact demo tenant, subscription, support case, request and expiry.
- Do not deny it in rehearsal. Arrange a separate rehearsal request/recording
  if available; a denial cannot be reset.
- Prepare an approved recording of a previous real denial and its audit evidence.
  Clearly label it as recorded. Without one, the fallback is explanation only.
- Confirm that projecting the request and its metadata is permitted. Hide email,
  personal information, support content and unrelated tenant resources as needed.
- Open the Azure Customer Lockbox pending request screen in the right directory.
  Have the subscription Activity Log ready on a separate tab with an appropriate
  UTC window. Do not rely on the removed History tab.

## Establish the boundary

> "A Microsoft support engineer has requested elevated access for this specific
> demo support case. We see the reason, resource scope and requested duration.
> This is the customer approval gate for this request, not a claim about every
> possible provider operation."

Point out request ID, case, reason, scope and expiry without exposing unnecessary
identities. Show pending status. Do not describe a normal ARM resource or a
generic approval ticket as a Customer Lockbox request.

## The moment

Verify again that the selected request is the agreed **demo** request.
Click **Deny** and complete any portal confirmation.

> "We denied this elevated support-access request. That also means the support
> work requiring it cannot proceed through this request."

Wait for the actual portal outcome. A click alone is not proof of success.
If the portal fails or the request expired, explain that honestly; do not narrate
a successful denial.

## Show what an auditor asks for

For a subscription-scoped request, open **Activity Log** and find the actual
**Deny Lockbox Request** event. Check:

- Timestamp and correct subscription/resource/request context.
- Caller (customer decision maker), operation and final **Succeeded** status.
- Event ID, correlation ID and request/support-case relationship.

Show actual JSON or an approved redacted view. Explain:

> "This is the decision audit trail. It is not a complete customer-data-access
> ledger or proof that every possible provider access is blocked."

Logs can arrive late. Refresh deliberately; if absent, say the decision's audit
record has not appeared yet and use the explicitly recorded rehearsal evidence.
Do not treat an empty search as evidence nobody touched data.

Use [the capture commands](../README.md) off-projector to preserve the real event
and context. Keep any raw export outside Git and protect it.

## Data Guardian (slide only)

Show the approved slide and describe only the approved distinction between
customer-visible Lockbox approval and Microsoft's internal Data Guardian controls.
This kit does not inspect or configure those internal controls.

## Close

> "Ask who requested access, who decided, what scope and duration were involved,
> and where the evidence lives. Sovereignty needs an operating process, not
> just a location label."

Mention that Customer Lockbox has documented exclusions, including certain
emergencies. Do not promise universal customer veto over all Microsoft operations.

## If no pending request is available

Say:

> "A real request depends on Microsoft's authorized support workflow; we cannot
> manufacture one by deploying a resource. This is a recording of an earlier
> approved demo, not a live denial."

Show the approved recording if available, then show its corresponding recorded
audit evidence using `ShowEvidence`. Never click an unrelated real request just
to preserve the stage moment. If no approved recording exists, use the slide
and explain the workflow without claiming a live demonstration.
