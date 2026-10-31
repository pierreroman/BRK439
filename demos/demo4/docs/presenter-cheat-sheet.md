# Demo 4 - Presenter cheat sheet

**Duration: 4 minutes. Mode: real regional cloud capture + real laptop inference.**

**The moment:** the audience votes on A/B, then you reveal which ran offline.
Cloud is captured **before** disconnecting. The presentation page displays saved
responses; it does not call either model.

## 1. Prepare before the session - online

1. Open **PowerShell 7.4+**, go to the repository and sign in:

   ```powershell
   Set-Location D:\git\BRK439
   az login
   $subscription = '<your-demo-subscription-GUID>'
   ```

   Substitute your actual repository path if different. Replace all angle-bracket
   placeholders before running commands.

2. Complete [the setup prerequisites](../README.md): Azure CLI/Bicep, approved
   permissions, Canada Central regional model quota, Foundry Local, hardware,
   model terms and budget. Do not install or update software on stage.

3. If the cloud side has not been deployed, discover supported versions:

   ```powershell
   .\demos\demo4\Deploy-Demo.ps1 -SubscriptionId $subscription
   ```

   **Expect:** a list of model/version pairs for **Standard / canadacentral**.
   Nothing is provisioned. If none are available, stop and resolve availability;
   do not substitute a Global or Data Zone deployment.

4. Choose a pair actually printed above and preflight:

   ```powershell
   $model = '<listed-model-name>'
   $version = '<listed-version>'
   .\demos\demo4\Deploy-Demo.ps1 -SubscriptionId $subscription `
     -ModelName $model -ModelVersion $version
   ```

   **Expect:** the intended subscription/group, **Canada Central**, **Standard**,
   capacity and `Preflight only`. Resolve quota/permission errors before proceeding.

5. After reviewing cost and the target, provision and confirm when prompted:

   ```powershell
   .\demos\demo4\Deploy-Demo.ps1 -SubscriptionId $subscription `
     -ModelName $model -ModelVersion $version -Apply
   ```

   **Expect:** `Deployment complete` and a non-secret configuration saved under
   `%LOCALAPPDATA%\BRK439\Demo4`. If already deployed, do not redeploy just for
   the performance. Inspect region, deployment type, filters and caller access.

6. Prepare the local model while online:

   ```powershell
   .\demos\demo4\Prepare-Local.ps1
   ```

   **Expect:** model download/load and `Local model loaded and warmup succeeded`.
   The default is `qwen2.5-0.5b`; the daemon is left running. Confirm the local
   service is loopback-only, not exposed to the LAN.

7. Run the offline code checks:

   ```powershell
   .\demos\demo4\tests\Invoke-OfflineChecks.ps1
   ```

   **Expect:** passing Pester tests and
   `PASS Offline tests and PowerShell error-level analysis`.
   These use fixtures/mocks; they do **not** prove real inference works.

8. Capture the real cloud answer while still connected:

   ```powershell
   .\demos\demo4\Start-Demo.ps1 -Mode CaptureCloud
   ```

   **Expect:** `REAL cloud answer saved` and a measured request time.
   This also captures governance evidence. If it fails, stop and resolve the
   actual error; do not silently substitute a sample answer.

Use the same `-StateDirectory` on every script if you chose a non-default
directory. This sheet assumes the default. Keep the terminal and capture files
off the audience screen: file names and metadata can spoil the reveal.

## 2. Rehearse offline and save a real fallback

1. Enable the laptop's actual **airplane mode**.
2. Disable/disconnect Ethernet and all alternate uplinks, including tethering.
   Verify isolation yourself. The scripts do not change adapters or prove an
   air gap. D3's simulated cable toggle does not disconnect this laptop.
3. Run:

   ```powershell
   .\demos\demo4\Start-Demo.ps1 -Mode RunLocal -ConfirmAirplaneMode
   ```

   **Expect:** `REAL local answer captured`, a measured request time, and an
   offline browser page showing **Answer A**, **Answer B**, and timings.
   The banner says cloud was captured before disconnect and the local request
   completed before the page opened.

4. Read both answers. Confirm they address the same fictional incident, retain
   uncertainty about exported reports, and are legible at stage zoom.
   A truncation warning is honest output, not something to hide.
5. Rehearse voting and reveal using the stage steps below.
6. Save a fallback from these successful real captures:

   ```powershell
   .\demos\demo4\Start-Demo.ps1 -Mode SaveFallback
   ```

   **Expect:** a page with
   **PRE-CAPTURED FALLBACK - recorded real outputs, live audience vote**.

7. Verify you can reopen it offline:

   ```powershell
   .\demos\demo4\Start-Demo.ps1 -Mode ShowFallback
   ```

8. Before the performance, refresh cloud while online if needed, then disconnect
   again. Keep the prepared local runtime running. Do not edit the prompt between
   captures. Have the `RunLocal` and `ShowFallback` commands ready off-projector.

## 3. Perform the demo - exact sequence

### 0:00-0:45 | Establish the test and run locally

1. Briefly show the fictional report or explain the task: three short bullets
   covering impact, cause/resolution and next actions.
2. Show that the laptop is in airplane mode, with alternate uplinks disconnected.

   **Say:**

   > "I captured one real cloud answer before disconnecting. Now the same prompt
   > goes to a pre-downloaded model on this laptop. The cloud deployment uses
   > regional Standard in Canada Central."

3. On the operator terminal, run:

   ```powershell
   .\demos\demo4\Start-Demo.ps1 -Mode RunLocal -ConfirmAirplaneMode
   ```

4. When inference finishes and the browser opens, put the comparison page on
   the audience screen. Do not open the template or raw capture JSON.

   **Expect:** A and B visible; source labels and governance hidden.
   Positions are randomized each time the page is built. Never assume B is local.

### 0:45-1:35 | Compare without revealing

5. Point to both answers and their **Measured request** times.
6. If needed, click **Show identical prompt**, then collapse it afterward.
7. Mention any output-token-limit warning rather than calling a partial answer
   complete.

   **Say:**

   > "These are full-response request times, not time-to-first-token. Downloads,
   > authentication and explicit loading are excluded. This is a small-task
   > comparison, not a quality or performance benchmark. Which ran offline?"

Do not click Reveal yet. Do not identify the model names or read source metadata
before the vote.

### 1:35-2:05 | Take the audience vote

8. Scroll to **Audience vote**.
9. Ask for a show of hands for **A ran offline**; enter the actual count.
10. Repeat for **B ran offline** and **Unsure**.
11. Point to the total. Use whole, non-negative counts. This tally is local, not
    a connected polling service.

### 2:05-3:30 | Reveal and inspect governance

12. Click **Reveal source & governance**.
    **Expect:** both source/model headings and governance JSON become visible.
13. Identify which letter says **Foundry Local - laptop** and which says
    **Foundry - Canada Central / regional Standard**.
14. On the **cloud** side, point to:
    - Actual model/version, capture time, region and regional SKU.
    - Configured prompt/completion policy and returned filter metadata.
    - Disabled key authentication, Entra caller authorization and role snapshot.
    - Logging explanation: client captures are local files; the kit configures
      no Azure Monitor prompt-body sink. Service-side handling is separate.
15. On the **local** side, point to:
    - Literal loopback endpoint and API model ID.
    - Operator-attested disconnection, not independent isolation certification.
    - Local capture files and separate runtime-log responsibilities.
    - No managed cloud filter or per-user RBAC configured by this client.

   **Say:**

   > "The answer's writing style does not tell us who can call the endpoint,
   > where prompts are recorded, or which filters applied. We inspect those
   > controls separately. Local does not mean inherently secure or ungoverned."

### 3:30-4:00 | Close honestly

16. Leave the revealed sources visible.

   **Say:**

   > "The cloud can offer newer or larger managed models. Local runs the
   > supported open-weight models we bring, within hardware and licensing
   > limits. The operating model matters as much as the answer."

Do not claim this is Foundry Local on an Azure Local cluster. This kit uses the
laptop; D3 does not provide real cluster hardware.

## 4. Fallback, reset and recovery

| What happened | Exact action |
| --- | --- |
| Local inference is failing or exceeds your rehearsed stage budget | Cancel with **Ctrl+C**; run the fallback command below. Do not wait for the full 180-second safety timeout on stage. |
| Page is already revealed or votes remain from rehearsal | Reload the same page. Votes reset and source/governance sections hide again. |
| Reveal is disabled | Correct vote fields to non-negative whole numbers. |
| Cloud request fails after disconnect | Expected connectivity constraint. Use the existing successful capture; refresh cloud only while online, before the demo. |
| Missing config, local model or runtime | Resolve preparation online before the show. On stage, use the saved fallback, not an unannounced reconnect/download. |
| Prompt hash mismatch | Rehearse again with matching captures. Do not edit the prompt on stage. |
| You opened the template | Open the generated comparison page, not [the template](../comparison.template.html). |
| No successful fallback exists | Explain the architecture. Do not invent model output or timing. |

**Fallback command:**

```powershell
.\demos\demo4\Start-Demo.ps1 -Mode ShowFallback
```

**Say:** "These are previously captured real responses; the audience vote is
live." Keep the fallback banner visible. Timings are historical. Run the same
vote/reveal steps; do not present this as a fresh inference.

Afterward, restore networking manually. If no other app needs the Foundry daemon,
stop it with `foundry server stop`. Do not delete Azure resources on stage;
follow [the setup guide's cleanup checks](../README.md).

**One-line memory aid:** Capture cloud online -> Disconnect actual uplinks
-> Run local -> Show A/B + timings -> Vote -> Reveal -> Explain governance.
