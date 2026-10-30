# Demo 3 - Six-minute stage runbook

**Mode: labelled laptop simulation throughout.** Never hide the top banner.
This is a teaching model, not an actual Azure Local deployment.

## Before the room opens

- Run [the launcher](../Start-Demo.ps1) and the self-tests described in
  [the setup guide](../README.md).
- Use the installed local file, a normal browser profile, readable zoom, and
  full-screen if desired. Keep the simulation banner visible.
- Reset rehearsal and confirm: connected model, one existing workload, no
  policy/role assignment, no package imported, fictional September 15 update.
- Test browser reload and state persistence at the exact installed path.
- Rehearse with actual internet disabled if allowed. No remote assets are used.
- If using a bright-tagged cable as a prop, say it is a prop. The toggle and
  ping are simulated. Do not disconnect unrelated stage or production equipment.
- Keep Updates visible or rehearse scrolling to it. Do not spend six minutes
  on the cable effect and miss the operational question.

## 0:00-0:45 - Establish the local control plane

Say:

> "This is a clearly labelled laptop simulation of the operating model, not a
> running Azure Local cluster. On real hardware this requires a pre-deployed
> disconnected control plane; unplugging a connected cluster does not create it."

Point to **Local control plane**, the existing workload record, and the labelled
animation tick. The tick is a browser timer, not guest telemetry.

## 0:45-1:20 - Pull the plug

Click **Pull simulated uplink**, then **Run simulated public ping**.

Show **DISCONNECTED (simulated)** and the simulated timeout.

> "The model has lost its uplink; local management continues. This is simulated
> output, not proof this laptop is physically isolated. A real demonstration
> also checks Wi-Fi, cellular, VPNs and every alternate uplink."

## 1:20-2:40 - Keep working locally

1. Click **Deploy simulated VM**. Show `demo-vm-1` running alongside the existing
   workload. Explain that images and dependencies must already be local.
2. Click **Assign simulated policy**.
3. Click **Try untagged resource group**. Read the visible **POLICY MODEL DENIED**
   message; show that no new group appeared.
4. Click **Create tagged resource group** to show the allowed path.
5. Click **Assign simulated Reader role**. Point to `demo-viewer`, Reader,
   `rg-demo3`.

Optional if time permits: select **demo-viewer**, click **Deploy simulated VM**,
show **RBAC MODEL DENIED**, then return to **Local administrator**. This role
selector is not real authentication.

> "These are working toy rules in a browser model, not Azure security controls.
> The point is that a pre-installed local control plane can own local operations."

## 2:40-4:30 - Turn the myth

Point to the update view. Pause before asking:

> **"When did this cluster last receive a security update, and how will the next
> one get here?"**

Point to the **fictional** last-applied date. Do not call it the laptop's or a real
cluster's patch level.

> "The workloads not caring about the cable is the setup, not the punchline.
> Disconnection removes an easy delivery path, not our patching obligation.
> Cloud-fed threat intelligence cannot refresh through a missing connection.
> Local protections can still operate, but someone must supply their updates."

Walk through what the operator must now own:

- Trusted package acquisition on an authorized connected system.
- Approved transfer into the isolated environment and malware/integrity checks.
- Change review, authorized approval/signing and auditable custody.
- Backup, recovery keys, maintenance windows, rollback and health verification.
- Separate responsibilities for the local control plane, hosts and guest OSes.

## 4:30-5:35 - Illustrate edge approvals

> "The session calls this edge approvals: cloud-to-edge changes must be reviewed
> and signed before application. These next buttons are illustrative mock stages,
> not a claim about a specific Azure Local product screen or signing API."

Click **1. Import (mock)**, **2. Review (mock)**, **3. Sign (mock)**.
Point out that the fictional last-applied date has not changed yet.

Click **4. Apply (mock)**; the model date changes to the current time.

> "No actual update was installed and no real signature was created here.
> On real hardware we show update history and the approved servicing process,
> not a live multi-hour update on stage."

## 5:35-6:00 - Close

> "Disconnected can be the right sovereignty decision. It does not mean
> maintenance-free. You own the supply line, approval process and recovery plan."

Optional migration statement: **omit unless the product team has confirmed the
current preview status**. If confirmed, explain it as a planned migration with
approval stages and backups, never as a switch or cable-pull conversion.

## Recovery during the demo

- Wrong identity: select **Local administrator**.
- Wrong sequence: read the visible denial; continue from the required stage.
- Already applied the mock package: reset and replay, or simply discuss the
  displayed history. Do not imply the package can be repeatedly applied.
- State/storage error: show the error honestly. Reset if safe; otherwise use the
  explanation above. Do not claim a successful deployment.
- Afterward: export simulated evidence if needed, reset, and close the tab.
