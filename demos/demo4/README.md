# Demo 4 - The AI taste test

Real Foundry cloud inference in **Canada Central**, real Foundry Local inference
on the presenter's laptop, an offline blind A/B reveal, and a fallback built
**only from your own successful captures**. No sample answer, invented latency or
silent mock fallback is included.

**Presenting the demo:** follow the [step-by-step presenter cheat sheet](docs/presenter-cheat-sheet.md)
for exact commands, audience voting, reveal cues and recovery actions.

The authenticated SharePoint plan was unavailable. This kit follows the pasted
D4 script and the requested real cloud + laptop setup. It does not depend on
Demo 3, which is currently a laptop simulator, not an Azure Local cluster.

## Requirements and costs

- Windows, **PowerShell 7.4+**, a browser with JavaScript, and Azure CLI.
- Azure CLI Bicep support (`az bicep version`; install using `az bicep install`
  if your approved Azure CLI installation lacks it).
- An Azure subscription with the selected model/version available as **regional
  Standard in Canada Central**, and sufficient Standard quota. Availability and
  quota do not guarantee capacity. The script refuses Global/Data Zone SKUs and
  never substitutes another region.
- Permission to create Foundry resources and role assignments in a dedicated
  resource group: for example Contributor plus RBAC Administrator at appropriate
  scope. Contributor alone cannot grant the inference role.
- Foundry Local installed (`winget install Microsoft.FoundryLocal`, subject to
  your organization's installation policy). Current CLI with `foundry server`
  commands is required. Review model licenses and hardware/driver requirements.
  The tiny default `qwen2.5-0.5b` is documented in the catalog examples; verify
  current availability and choose a supported alternative if necessary.
- Internet for initial model/execution-provider downloads and cloud capture.
  Allow sufficient disk/RAM and rehearse inference speed on the actual laptop.

Nothing is provisioned merely by downloading this kit. Model inference is
billable; account resources/usage may also incur charges. Check your pricing and
budget. Provisioning requires explicit `-Apply` and confirmation. No paid
resources were provisioned or real model inference verified when authoring this
kit; run the live acceptance checklist below on your subscription and laptop.

## 1. Deploy the regional cloud side (online, before the event)

Open PowerShell 7 at the repository root and authenticate:

```powershell
az login
$subscription = '<your-subscription-GUID>'

# Discover supported model/version pairs; this provisions nothing.
.\demos\demo4\Deploy-Demo.ps1 -SubscriptionId $subscription
```

Choose a pair **actually printed by that command**, then preflight:

```powershell
$model = 'gpt-4.1-mini'             # Only if listed as regional Standard.
$version = '<exact-version-from-the-list>'
.\demos\demo4\Deploy-Demo.ps1 -SubscriptionId $subscription `
  -ModelName $model -ModelVersion $version
```

After checking the printed target, quota and cost:

```powershell
.\demos\demo4\Deploy-Demo.ps1 -SubscriptionId $subscription `
  -ModelName $model -ModelVersion $version -Apply
```

The dedicated group defaults to `rg-brk439-demo4`; use `-ResourceGroupName` to
choose another. An existing group must have this kit's `demo=BRK439-Demo4` tag;
untagged/unrelated groups are refused. Do not tag an unrelated group to bypass
that protection. Deployment is incremental and can be retried after resolving
an error; no automatic cleanup deletes partially created resources.

The template creates:

- A Foundry `AIServices` account and child project in Canada Central.
- A `taste-test` OpenAI deployment using regional `Standard`, capacity 1 by
  default, an explicit model version, and no automatic version upgrade.
- Blocking Medium-severity Hate/Sexual/Violence/Selfharm filters for prompts
  **and** completions, based on `Microsoft.Default`.
- Disabled key authentication; a Cognitive Services OpenAI User assignment at
  account scope for the signed-in user. For automated identities, specify the
  **Entra object ID** with `-PrincipalObjectId` and
  `-PrincipalType ServicePrincipal`, not the application/client ID.

The endpoint is **public**, protected by Entra authorization, not a private
endpoint. Inherited roles can also permit inference. This is a demo deployment,
not a production sovereign landing zone or a certification of legal compliance.
Resource location alone is insufficient: deployment type controls processing
scope. Review current service data handling, residency and abuse-monitoring
terms for the exact model and configuration.

Non-secret configuration is saved outside the repository to
`%LOCALAPPDATA%\BRK439\Demo4`. Use the same `-StateDirectory` on **all scripts**
if choosing another location. Protect that directory with OS permissions.

## 2. Prepare and warm the local side (online)

```powershell
.\demos\demo4\Prepare-Local.ps1
```

This checks the CLI, starts the Foundry daemon with a fixed requested port and
no idle timeout, downloads execution providers/catalog/model, loads the model,
verifies the local OpenAI-compatible API and performs an unscored warmup.
It does not install Foundry automatically or accept model terms on your behalf.

The script defaults to `http://127.0.0.1:39839/v1`. It never restarts a shared
daemon. If the daemon already uses another port, inspect `foundry server status`
and rerun with `-Port`. If API model resolution is ambiguous, use the displayed
model ID with `-ModelId`. To choose another catalog model:

```powershell
foundry model list
.\demos\demo4\Prepare-Local.ps1 -Model '<available-chat-model-alias>'
```

Verify the daemon is bound to loopback and not exposed on the LAN. Do not
add firewall exceptions, port forwarding or a reverse proxy for this demo.

## 3. Capture cloud, then prove local operation offline

While connected:

```powershell
.\demos\demo4\Start-Demo.ps1 -Mode CaptureCloud
```

This rechecks the account region, regional SKU, disabled keys, filter attachment
and eight filter settings, records current role assignments, authenticates with
Entra, calls the real endpoint and saves the measured answer. Tokens are never
saved. If RBAC has not propagated, resolve the visible 401/403 and retry;
do not enable API keys. Quota/rate-limit/filter errors surface as failures.

Now enable airplane mode and disable Ethernet, VPN and alternate uplinks.
Verify actual disconnection yourself; a failed ping alone is not proof.
The scripts **do not change network adapters**.

```powershell
.\demos\demo4\Start-Demo.ps1 -Mode RunLocal -ConfirmAirplaneMode
```

Only the literal loopback API is permitted, with proxy bypass and redirects
rejected. No Azure CLI, catalog download or cloud request occurs in this mode.
The switch records **operator attestation**, not automatic isolation evidence.

The script makes a real local request, saves its answer/timing, checks the exact
prompt hash and fixed generation settings against cloud, randomizes A/B, and
opens a self-contained comparison page. Answers are rendered after inference,
not streamed. Neither the HTML page nor poll makes network requests.

Both use the exact same fictional incident prompt, 180 output tokens,
temperature 0 and non-streaming responses. A token-limit finish is labelled
truncated. Latencies cover the request through the full response, not
time-to-first-token; setup, auth, downloads and explicit loading are excluded.
CPU/GPU/NPU differences and model warmth are not controlled. This is not a
benchmark. Read both answers beforehand; a small model may make mistakes.

## 4. Save the fallback after a successful rehearsal

Still offline:

```powershell
.\demos\demo4\Start-Demo.ps1 -Mode SaveFallback
```

This freezes real captured outputs into `fallback.html`, prominently labelled
**PRE-CAPTURED FALLBACK**. Then return the laptop to your intended rehearsal
state. On stage, after a failed local request:

```powershell
.\demos\demo4\Start-Demo.ps1 -Mode ShowFallback
```

It does not call either model, invent responses or replace the fallback.
Use `-NoBrowser` to print the page location without opening it. Every generated
page embeds the reveal; blinding is presentational, not tamper-proof. Avoid
opening files named `cloud.json` or `local.json` on the audience screen.

## Governance reveal: what is evidence, and what is not

- **Prompt logging:** this client intentionally persists the full fictional
  prompt/answer in `cloud.json`, `local.json` and generated HTML. No prompt-body
  Application Insights/Azure Monitor sink is configured. Service-side abuse
  monitoring/retention is separate; do not claim Azure keeps no copy. For
  Foundry Local runtime log location/contents, inspect `foundry server status`
  and `foundry server logs`; the kit does not audit those logs.
- **Filters:** the reveal includes the cloud policy configuration and filtering
  metadata actually returned by the response. Missing response metadata is not
  evidence of no filtering. Local requests have no cloud-managed content-filter
  policy configured by this client; model/runtime safeguards may still exist.
- **Callers:** the cloud requires Entra and shows a direct/inherited role
  snapshot, not an effective-access audit. Local requests carry no token and
  have no per-user RBAC configured by this kit; OS access and runtime binding
  matter. Local does not mean inherently secure or ungoverned.

The default report is fictional. Do not replace it with sensitive material
without reviewing cloud data handling, local log retention, filesystem access
and the fact that the entire prompt is embedded in the presentation HTML.

## Acceptance, troubleshooting and cleanup

Run the offline checks (requires existing Pester 5+ and PSScriptAnalyzer):

```powershell
.\demos\demo4\tests\Invoke-OfflineChecks.ps1
```

Then complete **live** acceptance:

1. Deploy in your subscription; inspect region, SKU, pinned version, filter
   policy, key authentication and caller roles in Azure/Foundry.
2. Verify a real cloud capture after role propagation.
3. Warm/download locally, disconnect all uplinks and run a real local capture.
4. Confirm both prompts match, answers are legible, timing/truncation labels
   are honest, and A/B sources remain hidden until reveal.
5. Tally a vote, reveal both governance records, save and open fallback offline.
6. Repeat after any reboot/runtime/model change. Refresh stale cloud captures
   and governance evidence before the event.

Current CLI docs use `foundry server`, not legacy `foundry service` commands.
If the local CLI lacks these commands, update it through your approved process
and rerun preparation while online. Do not upgrade on stage.

Follow the [four-minute runbook](docs/stage-runbook.md). The optional Foundry
Local on Azure Local variant is **not deployed here**. Demo 3 has no cluster.
Do not repeat a GA claim without current product-team confirmation; the CLI
reference currently carries a preview notice. A cluster variant needs its own
supported architecture, hardware, local networking and authenticated endpoint.

After the event, restore laptop networking manually. If no other app needs the
daemon, stop it with `foundry server stop`; it was deliberately left running.
Model cache persists; use `foundry cache --help` to inspect supported cleanup
commands and remove only the intended model. No daemon is started by the tests.

For Azure cleanup, verify the **exact dedicated group** and its tag first:

```powershell
az group show --subscription $subscription --name rg-brk439-demo4
# ONLY after checking this group contains exclusively this demo's resources:
az group delete --subscription $subscription --name rg-brk439-demo4
```

This deletes **everything** in that group. Do not use it on a shared group.
Captured local files remain until you remove them; delete specific captures/
pages if no longer needed, according to your retention policy.

### Official references (recheck before the event)

- [Foundry Local CLI, installation, downloads and fixed-port server](https://learn.microsoft.com/azure/foundry-local/reference/reference-cli)
- [Foundry Local overview and hardware considerations](https://learn.microsoft.com/azure/foundry-local/overview)
- [Azure OpenAI deployment types and processing scope](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/deployment-types)
- [Azure OpenAI content filtering](https://learn.microsoft.com/azure/ai-foundry/openai/concepts/content-filter)
- [Azure OpenAI data privacy](https://learn.microsoft.com/legal/cognitive-services/openai/data-privacy)
- [Azure OpenAI role-based access](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/role-based-access-control)
