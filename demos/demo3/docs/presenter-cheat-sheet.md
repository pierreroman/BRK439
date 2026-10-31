# Demo 3 - Presenter cheat sheet

**Duration: 6 minutes. Mode: laptop simulation, NOT a real Azure Local cluster.**

**The punchline:** "When did this cluster last receive a security update, and
how will the next one get here?" The cable pull is only the setup.

## 1. Prepare the laptop before the session

1. Open **PowerShell** and go to the repository:

   ```powershell
   Set-Location D:\git\BRK439
   ```

   If your copy is elsewhere, substitute its actual repository path.

2. Run the offline installation checks:

   ```powershell
   .\demos\demo3\tests\Invoke-OfflineChecks.ps1
   ```

   **Expect:** `PASS Offline installation checks completed.`
   If a check fails, resolve it before presenting.

3. Open the browser self-tests:

   ```powershell
   .\demos\demo3\Start-Demo.ps1 -SelfTest
   ```

   **Expect in the browser:** `SELF-TEST PASSED` and
   `16/16 passed; 0 failed.` This is a test page, not the presentation.

4. Open the actual presentation:

   ```powershell
   .\demos\demo3\Start-Demo.ps1
   ```

   **Expect:** the browser shows **Pull the plug**, with the simulation banner.
   The installed file is `%LOCALAPPDATA%\BRK439\Demo3\portal.html`.
   Use the same file location and normal browser profile for the whole demo.

5. In the presentation, click **Reset rehearsal**, then accept the confirmation.
   **Expect:** `Rehearsal reset. Baseline restored; unrelated browser data preserved.`

6. Confirm every baseline item:

   | On screen | Must show |
   | --- | --- |
   | Simulated identity | **Local administrator** |
   | Simulated uplink | **CONNECTED (simulated)** |
   | VM list | Only **existing-workload - Running (simulated)** |
   | Resource groups | Only **rg-demo3 - Owner=stage-operator** |
   | Policy | **Not assigned.** |
   | Reader role | **Not assigned.** |
   | Last applied | **2026-09-15T10:00:00.000Z (fictional)** |
   | Illustrative "edge approvals" | **Not imported** |

7. Rehearse the steps below once, including scrolling to the updates card.
   If permitted, test the page with the laptop's actual internet disconnected.
   Reload it and confirm saved records persist. Restore actual networking
   afterward if needed. The simulator never changes real networking.

8. **Reset rehearsal again immediately before going on stage.** Keep the
   simulation banner visible and use a readable browser zoom. Keep this cheat
   sheet on another screen or print it.

**If PowerShell scripts are blocked:** do not bypass organization policy.
Open [portal.html](../portal.html) directly in Edge or Chrome and use that same
source-file location/profile consistently. Reset there. Do not switch between
the source file and installed file during the performance.

## 2. Perform the demo - exact click sequence

### 0:00-0:45 | Establish what the audience is seeing

1. Show **Pull the plug** and the simulation banner.
2. Point to **Local control plane: Available in this browser**.
3. Point to the existing workload and advancing **Animation tick**.

**Say:**

> "This is a labelled laptop simulation of the operating model, not a running
> Azure Local cluster. A real disconnected deployment needs its local control
> plane installed beforehand. Unplugging a connected cluster does not create one."

The tick is a browser timer, not VM telemetry. Do not present it as a real guest
OS continuing to run.

### 0:45-1:20 | Pull the simulated uplink

4. In **1. Local cluster & uplink**, click **Pull simulated uplink** once.
   **Expect:** **DISCONNECTED (simulated)**. The button changes to
   **Reconnect simulated uplink**; do not click it again yet.
5. Click **Run simulated public ping**.
   **Expect:**

   ```text
   SIMULATED ping 1.1.1.1
   Request timed out. 100% loss (model output only)
   ```

6. Point to the existing workload still showing **Running (model only)**.

**Say:**

> "The model has lost its uplink, but local management continues. This ping is
> simulated, not a measurement of this laptop's connection."

If holding a tagged cable, identify it as a prop. Do not unplug shared stage,
management or production equipment.

### 1:20-2:40 | Deploy and govern locally

7. In **2. Deploy locally**, click **Deploy simulated VM** once.
   **Expect:** **demo-vm-1 - Running (simulated)** appears alongside
   **existing-workload**.

   **Say:** "The image is already staged locally. This creates a browser record,
   not a real VM."

8. In **3. Governance without the cloud**, click **Assign simulated policy**.
   **Expect:** **Assigned locally (simulated); enforced on new groups only.**
9. Click **Try untagged resource group**.
   **Expect:** the status message starts **POLICY MODEL DENIED**.
   No resource group is added. **This denial is intentional, not a demo failure.**
10. Click **Create tagged resource group**.
    **Expect:** **rg-demo3-1 - Owner=stage-operator** appears in the resource-group
    list in **2. Deploy locally**.
11. Click **Assign simulated Reader role**.
    **Expect:** **Reader assigned locally (simulated).**

**Say:**

> "We have illustrated local resource creation, a required-tag policy, and a
> Reader assignment. These are toy rules, not actual Azure security controls."

**Optional, only if time permits: prove the Reader denial**

12. At the top, open **Simulated identity** and select
    **demo-viewer (requires Reader assignment)**.
13. Click **Deploy simulated VM**.
    **Expect:** **RBAC MODEL DENIED**; the VM list still has only two entries.
14. Change **Simulated identity** back to **Local administrator**.
    **Do not skip this:** the mock update actions require administrator identity.

### 2:40-4:30 | Ask the question that turns the myth

15. Scroll to **4. Who brings the next security update?**
16. Point to **Last applied: 2026-09-15T10:00:00.000Z (fictional)**.
17. Pause and ask:

> **"When did this cluster last receive a security update, and how will the next
> one get here?"**

18. Point to the cloud-feed model being unavailable.

**Say:**

> "The workload not caring about the cable is the setup, not the punchline.
> Disconnection removes an easy update delivery path, not our maintenance
> obligation. Local protections can still operate, but someone must supply
> their updates and fresh threat intelligence."

19. Walk through the operator responsibilities:
    - Acquire trusted packages on an authorized connected system.
    - Transfer them through an approved path and validate integrity.
    - Review, approve and sign changes through the organization's process.
    - Plan backups, recovery keys, a maintenance window, rollback and health checks.
    - Maintain the control plane, hosts and guest operating systems separately.

The date is fictional; it is not the laptop's or a real cluster's patch level.
Automatic cloud patch delivery is **not implemented in this simulator**, even
when its uplink model says connected.

### 4:30-5:35 | Illustrate the approval path

**Say before clicking:**

> "The session calls this edge approvals. These four buttons are mock teaching
> stages, not a claim about a specific Azure Local product screen or signing API."

20. Click **1. Import (mock)**.
    **Expect:** stage becomes **Imported**.
21. Click **2. Review (mock)**.
    **Expect:** stage becomes **Reviewed**.
22. Click **3. Sign (mock)**.
    **Expect:** stage becomes **Signed**.
23. Point out that **Last applied** still shows the fictional September 15 date.
24. Click **4. Apply (mock)**.
    **Expect:** stage becomes **Applied** and **Last applied** changes to the
    current UTC timestamp, still labelled **(fictional)**.

**Say:**

> "Only the model's date changed. No package was downloaded, no cryptographic
> signature was produced, and no software was patched. On real hardware we show
> update history and the servicing process, not a multi-hour update on stage."

### 5:35-6:00 | Close

25. Leave the update card or local simulated audit trail visible.

**Say:**

> "Disconnected can be the right sovereignty decision. It does not mean
> maintenance-free. You own the supply line, approval process and recovery plan."

Do not add the connected-to-disconnected preview claim unless the product team
has confirmed the current status and exact wording. It is not demonstrated here.

## 3. After the demo

1. If desired, click **Export simulated evidence**.
2. Scroll below the audit trail to **Simulated evidence JSON**.
   The browser also receives a download request for
   `demo3-SIMULATED-evidence.json`. If downloads are blocked, copy the displayed
   JSON instead. These records are simulated, not audit evidence from Azure.
3. Click **Reset rehearsal** and accept the confirmation.
4. Close the tab. No server or background service was installed by this kit.
5. Restore actual laptop networking if you disabled it manually.

## 4. Quick recovery on stage

| What happened | Exact recovery |
| --- | --- |
| Reader cannot run an action | Select **Local administrator** in **Simulated identity**, then retry. |
| **POLICY MODEL DENIED** on an untagged group | Expected. Continue with **Create tagged resource group**. |
| Viewer selected before assignment | Select administrator, click **Assign simulated Reader role**, then select viewer. |
| **UPDATE MODEL BLOCKED** | Read the required stage in the status message. Follow **Import -> Review -> Sign -> Apply** without skipping. |
| Stage is already **Applied** | Do not click Apply repeatedly. Discuss the displayed result, or reset and replay from the beginning. |
| You clicked Deploy twice | An extra simulated VM is harmless. Continue without claiming the baseline names, or reset if there is time. |
| Uplink is accidentally connected | Click **Pull simulated uplink** once and rerun **Run simulated public ping**. |
| Reload shows saved state | Expected persistence. **Reset rehearsal** only if you intend to start over. |
| Storage error / disabled controls | Click **Reset rehearsal** and confirm. If it still fails, use an approved browser/profile with local storage enabled; do not claim success. |
| Time is running short | Skip the optional Reader identity test. Preserve the update question and close; do not rush past the punchline. |

**One-line memory aid:** Reset -> Pull uplink -> Ping -> Deploy -> Assign policy
-> Deny untagged / allow tagged -> Assign Reader -> Ask update question
-> Import / Review / Sign / Apply -> Close.
