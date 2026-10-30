# Demo 4 - Four-minute operator runbook

## Pre-stage (not part of the four minutes)

Complete [setup and live acceptance](../README.md) on the actual laptop and
subscription. Keep the model/runtime/driver versions unchanged afterward.
Use fictional data. Keep the command terminal off the audience projector.

1. Online: prepare/warm Foundry Local and capture the regional cloud answer.
2. Airplane mode: disable wired/alternate uplinks and verify isolation.
3. Run local inference, rehearse A/B and save a real pre-captured fallback.
4. Reset the presentation by reopening/reloading the page (votes reset and
   sources hide again). Do not reveal the embedded source in developer tools.
5. Before this demo, refresh the cloud capture while connected if necessary.
   CaptureCloud is the only inference mode requiring Azure connectivity.

If staging directly after Demo 3, restore the laptop's actual connectivity
before refreshing cloud; the D3 simulator toggle does not change networking.
For D4 disconnect it again before the local request.

## 0:00-0:45 - One small task, two execution locations

Show the fictional report/prompt briefly, then put the device in airplane mode
with all other uplinks off. Say:

> "I captured one real cloud answer before disconnecting. Now I will request
> the same short summary from a pre-downloaded model on this laptop.
> The deployment on the cloud side uses regional Standard in Canada Central."

On the operator terminal:

```powershell
.\demos\demo4\Start-Demo.ps1 -Mode RunLocal -ConfirmAirplaneMode
```

The real request completes before the A/B page opens. The request has a
180-second safety timeout; do not wait that long on stage. If it is clearly
running beyond your rehearsed budget, cancel the command with Ctrl+C and use
fallback. Cancellation must not be presented as a successful capture.

## 0:45-1:35 - Blind answers, honest timings

Show A and B. Point out the measured **full-response request** times and any
truncation warning. Do not call either a live cloud request, TTFT measurement
or a model-quality benchmark. A faster answer is not proof of where it ran.

> "The question is not which answer sounds more polished. Which ran without
> internet? Think about the impact, the cause, and the unknown exported reports."

## 1:35-2:05 - Live audience vote

Take a show of hands for A, B and unsure; enter the counts. The page tallies
locally. There is no remote poll service or fabricated audience result.
Leave source labels hidden until voting is complete.

## 2:05-3:30 - Reveal and inspect governance

Click **Reveal source & governance** and reveal the randomized mapping.

For the cloud side, show:

- Canada Central **and regional Standard**, model/version and capture time.
- Configured blocking prompt/completion filters versus actual returned filter
  metadata; these are different kinds of evidence.
- Entra-only inference with key authentication disabled; role snapshots include
  inherited access and are not a complete effective-access audit.
- Client prompt logging: the fictional prompt and answer are saved locally.
  No Azure Monitor prompt-body sink is configured by the kit. Service-side
  handling/abuse monitoring must be assessed separately.

For the laptop side, show:

- A literal loopback endpoint and the actual API model ID.
- Operator-attested disconnection, not an automatically certified air gap.
- Client captures on local disk; separately inspect runtime logs if needed.
- No cloud-managed filters or per-user RBAC configured by this client.
  Model/runtime safeguards and OS/network access still matter.

## 3:30-4:00 - Close honestly

> "The cloud can offer newer or larger managed models. Local runs the supported
> open-weight models we bring, within hardware and licensing constraints.
> Neither the writing style nor airplane mode tells us who owns the logs,
> filtering and caller controls. We must inspect the operating model."

The default laptop model is intentionally small. A weak summary is a useful
reason to discuss capability tradeoffs, not a reason to silently substitute a
hand-written answer.

## Fallback

Cancel a failing/slow request and run:

```powershell
.\demos\demo4\Start-Demo.ps1 -Mode ShowFallback
```

Say **"These are previously captured real responses; the audience vote is
live."** Keep the pre-captured banner visible. Timings are historical.
If no successful capture exists, explain the architecture; do not invent one.

## Azure Local option

Not included in this laptop kit. The D3 environment is a simulation, not real
Azure Local hardware. Confirm supported product/version, current availability,
model sizing and safe endpoint access with the product team before adding a
real cluster variant; do not present the supplied GA statement as verified.
