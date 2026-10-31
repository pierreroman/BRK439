# Demo 3 - Pull the plug (laptop simulation)

**SIMULATION ONLY. This kit does not deploy Azure Local, a hypervisor, a real VM,
Azure Policy, RBAC, an update service, or a disconnected control plane.**
It models the six-minute story on an ordinary laptop, as requested. Keep the
simulation banner visible throughout. Do not present it as product validation.

**Presenting the demo:** follow the [step-by-step presenter cheat sheet](docs/presenter-cheat-sheet.md)
for exact commands, clicks, expected results, speaking cues and recovery actions.

## What anyone running it needs

- A Windows laptop with Windows PowerShell 5.1 or PowerShell 7.
- A current Edge or Chrome browser with JavaScript and local file browser storage
  enabled. Use a normal, dedicated demo profile rather than private browsing.
- This entire directory. No Azure account, administrator privileges, modules,
  package installation, subscription, internet access or paid services.

The PowerShell launcher copies one self-contained HTML file to
`%LOCALAPPDATA%\BRK439\Demo3`, verifies its SHA-256 hash and opens it. It does not
change execution policy, install software, change adapters or create a server.
Inspect the script and follow your organization's script-execution policy; do
not bypass it. If scripts are blocked, open [portal.html](portal.html) directly
in the browser instead.

## Setup

From the repository root:

```powershell
.\demos\demo3\Start-Demo.ps1
```

Or install without opening the browser:

```powershell
.\demos\demo3\Start-Demo.ps1 -NoBrowser
```

The command prints the local file URL. To choose another installation location:

```powershell
.\demos\demo3\Start-Demo.ps1 -DestinationDirectory C:\Demos\Demo3
```

Re-running the launcher updates the HTML, not the saved rehearsal. Browser state
is associated with the file location and profile; always use the same installed
path and profile during a performance. Do not install over unrelated files: the
launcher replaces `portal.html` in the specified destination.

### Rehearse and verify

1. Run the install/PowerShell checks:

   ```powershell
   .\demos\demo3\tests\Invoke-OfflineChecks.ps1
   ```

2. Open the isolated model self-tests:

   ```powershell
   .\demos\demo3\Start-Demo.ps1 -SelfTest
   ```

   Expect **16/16 passed; 0 failed**. These tests use in-memory storage, not your
   saved rehearsal, and require no network. They verify offline model operations,
   toy policy/RBAC denials, approval ordering, persistence, reset, invalid-state
   handling and storage-write failures. They do not validate Azure Local.

3. Open the normal portal with the launcher. Select **Reset rehearsal**, confirm,
   and perform the full [stage runbook](docs/stage-runbook.md).
4. Reload the page after deploying a simulated VM. Confirm the VM record,
   disconnected state and assignments persist.
5. Disable the laptop's actual internet connection manually, if permitted, and
   reload the local file. Confirm the same controls still work. Restore actual
   networking yourself afterward. The simulator never changes it.
6. Select **Export simulated evidence**. Confirm the JSON shown below the audit
   trail is labelled simulation and contains the expected records. The browser
   also receives a download request; if downloads are blocked (for example in an
   embedded browser), copy the displayed JSON instead. Reset again before
   taking the stage.

If browser storage is blocked, corrupt or incompatible, the page displays an
explicit error and disables model operations. Reset replaces only this demo's
storage entry; it does not clear unrelated browser data. If reset also fails,
enable storage or use an approved browser/profile. There is no silent,
non-persistent fallback.

## What the simulator demonstrates

| Beat | Implementation | What it does NOT prove |
| --- | --- | --- |
| Local portal | One local HTML file, no external assets or requests | Real Azure Local portal/control-plane availability |
| Cable pull | A saved boolean, plus explicitly simulated ping output | Physical isolation or actual ICMP failure |
| Existing workload | A running record and a labelled browser timer | A real guest OS continuing to serve traffic |
| VM deployment | Adds a running VM record from a fictional pre-staged image | Hypervisor provisioning, guest networking or image availability |
| Policy | Toy rule denies **new resource groups** without an Owner tag | Actual Azure Policy evaluation or its supported policy catalog |
| RBAC | Toy Reader assignment at rg-demo3; viewer cannot mutate the model | Real identity integration, authorization or a security boundary |
| Updates | Fictional date and sequential mock import/review/sign/apply | Package integrity, cryptographic signatures or patch installation |

The identity selector is an educational role switch, not authentication.
The baseline date is **2026-09-15**, deliberately fictional. The date changes to
the current clock time only on mock Apply. Reconnecting does not apply updates.
The "edge approvals" sequence illustrates operator responsibility from the
supplied session script; it is **not** a claim that Azure Local exposes these
four stages or uses this signing mechanism. Simulated successful changes appear
in the local audit trail; rejected actions appear in the visible status area.
The audit retains only the latest 100 successful actions and is not tamper-proof.

There are no automatic cloud feeds or patch mechanisms in this kit, even while
its model says connected. In a real disconnected environment, operators must
design an approved path for updates and intelligence refresh; do not imply that
all local security controls stop working or that connected systems require no
change control.

## Moving to real Azure Local hardware

This laptop kit is **not** a deployment script for the real product. A normal
connected cluster does not gain disconnected operations when its cable is
unplugged. A real version needs a separately planned, supported installation:

1. Confirm eligibility, product access/approval, agreements, support and current
   availability with Microsoft.
2. Procure supported Azure Local hardware and a dedicated management cluster;
   budget capacity for the disconnected control-plane appliance.
3. Plan the isolated management/workload network, local identity, DNS, time
   services, PKI/trust, addressing, recovery and operator access.
4. Acquire and deploy the supported disconnected operations release through
   Microsoft's documented process. Pre-stage VM images and all prerequisites.
5. Validate VM creation and the exact supported policy and RBAC scopes on that
   release. The documented policy walkthrough requires a tag on resource groups;
   do not substitute a fictional VM policy.
6. Rehearse on actual hardware with alternate WAN paths disabled. Keep local
   management, storage, cluster and workload networking connected. Measure
   public reachability separately and verify a real guest workload response.
7. Collect actual update history; establish secure package acquisition,
   transfer, integrity/signature validation, approvals, backups, recovery keys,
   maintenance windows, monitoring and recovery. Separate control-plane updates
   from Azure Local host and guest patch responsibilities. Real update operations
   can take hours and reboot the control plane; do not apply one on stage.

Official references, reviewed for this kit on 2026-10-30:

- [Disconnected operations overview, eligibility and supported services](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-overview)
- [Acquire disconnected operations](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-acquire)
- [Deploy disconnected operations](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-deploy)
- [Local policy and the resource-group tag example](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-policy)
- [Apply updates and get update history](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-update)

Recheck release-specific documentation before the event. The supplied optional
connected-to-disconnected preview claim has **not** been verified by this kit.
Omit it unless the product team confirms current status and exact wording;
never portray migration as a cable pull or a live switch.

## Reset and cleanup

- **Reset rehearsal** restores the fictional baseline and clears this demo's
  records only. Reset before each performance.
- Close the portal to stop its browser timer. No service or background process
  is installed.
- Remove only the installed `portal.html` if you no longer need it. Browser
  storage remains profile-managed; reset first if you want its demo data removed.
- Exports are optional, local JSON files containing only simulated data. Delete
  those specific downloads yourself if no longer needed.

The linked SharePoint session plan required authentication, so this kit is based
on the pasted Demo 3 script and the laptop-simulation choice, not on unseen
document content.
