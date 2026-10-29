# Operator setup, restricted transport and recovery

**Commands here require a separately approved deployment/rehearsal. They were
not executed as part of offline preparation.**

## Reviewed Linux prerequisites and administrator boundary

Use the approved confidential Linux image. Through a separate, privileged
administrator route, review/install vendor-supported PowerShell **7.4+** at
`/usr/bin/pwsh`, Python 3 at `/usr/bin/python3`, OpenSSH/SFTP, systemd, syslog
(`logger`), sudo, coreutils/user-management tools and NTP synchronization.
Use the image/vendor's signed packages and your approved package repository;
the kit deliberately does not download arbitrary bootstrap packages.
Confirm `timedatectl show --property=NTPSynchronized --value` says `yes`.
Review outbound Entra/ARM/HSM/Storage/telemetry routes and private DNS.

Create a distinct administrator account/key for initial deployment and
maintenance. Runtime `config.sshUser` is **not** that account. The administrator needs
sudo to install root-owned code, configuration, users/groups and service/SSH
configuration. Keep admin access separate; do not make an existing privileged
account into the operator. The installer rejects an operator with unexpected
supplementary groups but is not an audit of every possible external sudo or
identity-provider rule. The administrator must verify no independent sudo,
shell, alternative key or directory-service grant bypasses these restrictions.

**Bootstrap/runtime configuration distinction:** the infrastructure host module
uses its input `sshUser` and `sshPublicKey` to create the initial VM administrator.
For that Foundation deployment input, choose the deployment administrator
(for example `demoadmin`) and its administrator public key. After provisioning,
prepare a separate private Runtime configuration with `sshUser` set to a **new
restricted operator** (for example `demooperator`) and `sshIdentityFile` pointing
to its different private key. Pass the original bootstrap administrator name as
`-AdminSshUser` and its key as `-AdminIdentityFile` to installation. Do not pass
the bootstrap administrator as the Runtime operator: installation deliberately
rejects that collision or unexpected privileged groups.

On Windows, obtain SSH host fingerprints through a trusted independent admin
channel. Verify them before populating `known_hosts` for the exact endpoint
(including `[127.0.0.1]:port` for a tunnel). Do not use unverified `ssh-keyscan`
output as proof of identity. All kit calls require `StrictHostKeyChecking=yes`
and batch authentication. No passwords or tokens are passed as command text.
Provision the operator key separately from the admin key; keep private keys
outside the repo and use an approved agent/key protection policy.

## Persistent demo custody disk gate

The approved **synthetic-demo-only exception** uses four disposable RSA wrapping
pairs, a 3-of-4 threshold and a single operator. It is not four-custodian control.
All private pairs and the security-domain backup will be online on the VM:
root or a sufficiently privileged Azure/disk administrator can obtain them.
The 32-GiB Standard SSD at LUN 0 uses platform-managed encryption, not either
revocable Storage CMK. `/mnt/dispo-keys` replaces the proposed Windows `D:` path.
Nothing is generated or mounted by the Bicep template.

Before generating wrapping pairs, a separately authorized administrator must:

1. Match the deployed `custodyDiskId` output, VM attachment LUN 0 and guest block
   device by Azure disk mapping. Inspect `lsblk`, filesystem signatures and
   `findmnt`; never select by `/dev/sdX` ordering alone.
2. Verify this is the new, empty, dedicated disk and approve initial formatting
   explicitly. Never format a disk with existing data or blindly rerun setup.
   Existing filesystems require inspection, not reinitialization.
3. Mount the dedicated filesystem at `/mnt/dispo-keys`, owned by root with
   mode 0700. Use a reviewed filesystem-UUID persistent mount, `nodev,nosuid,noexec`
   and `nofail`; the watchdog must boot independently of this disk. Prove the
   mounted source is the intended disk before every private-material operation:
   an empty directory on the OS disk is not an acceptable fallback.
4. Verify the restricted SSH operator and `demo2` service cannot read the mount.
   Use `umask 077` for generation, root-only private files (0600), no transcripts,
   command tracing, terminal printing or telemetry of private material. Only
   public wrapping certificates may be transferred for activation.
5. Approve where the separate encrypted offline recovery copy will be retained.
   Co-locating all keys and the security domain on one disk is not a resilient
   backup. Never put the recovery copy in Copilot Library, git, recordings or
   the revocable demo storage.
6. Verify persistence after a reboot before HSM activation. VM deletion detaches
   the managed disk, but disk/resource-group deletion still removes it. No
   automatic cleanup is authorized; track its ongoing charges and retirement.

After generating the wrapping pairs, retain their encrypted offline recovery
copy and verify readability before HSM activation. The security-domain file
does not exist before the activation download: protect and back it up immediately
after that download, before creating CMKs or demo data. Do not claim that a
not-yet-created security-domain file was backed up before activation.

This preparation is not HSM activation or permission to create billable resources.
Do not silently re-enable a production-style custody claim after the exception.

## Install only through an existing authenticated private tunnel

No tunnel is created automatically. The installer uses `sshHost` / `sshPort`
from the reviewed runtime config and a distinct `AdminSshUser`.

```powershell
.\scripts\Install-Watchdog.ps1 -ConfigPath .\config.local.json `
  -AdminSshUser demoadmin -AdminIdentityFile C:\Private\demo-admin `
  -OperatorPublicKeyPath C:\Private\demo-operator.pub `
  -AuthorizeHostChanges -WhatIf
# Remove -WhatIf only after review and explicit authorization.
```

`-AuthorizeHostChanges` and ShouldProcess are both required. Installation
**starts an authorized recovery service**, whose unit includes
`-AuthorizeLiveChanges`; it may reconcile existing durable recovery intent.
Never reinstall/update while an unresolved mutation or armed run exists.
The installer rejects an active service or a persisted non-Closed run. It also
requires a fresh service heartbeat before declaring installation responsive.
The installer stops on missing remote prerequisites rather than installing
packages. It packages reviewed common/host files and configuration via SCP,
includes the required root-owned, service-readable
`/opt/demo2/config.schema.json` beside the scripts/host directories, stages under
a random administrator-only `/var/lib/.demo2-install-*` directory,
and removes staging after the operation. It does not upload a whole repo.

Installed boundary:

| Path / identity | Access |
|---|---|
| `/opt/demo2/scripts`, `/opt/demo2/host`, `/opt/demo2/submit-operator` | Root-owned code, operator/service cannot modify. |
| `/opt/demo2/config.schema.json` | root:root, 0644; required by common-module configuration validation, readable but not writable by service/operator. |
| `/etc/demo2/config.json` | root:demo2, 0640; operator cannot read/write runtime config. |
| `/var/lib/demo2` | demo2:demo2, 0700; durable state and worker lock, inaccessible to operator. |
| `/var/spool/demo2/requests` | demo2:demo2-operators, 3770; operator creates own requests, sticky bit prevents deleting others' files; owning daemon can remove processed requests. |
| `/var/spool/demo2/responses` | demo2:demo2-operators, 2750; operator traverses/reads, not writes. Service UMask=0027 creates read-only-to-group responses/heartbeat. |
| `/etc/demo2/operator_authorized_keys` | root-owned public key file, `restrict` and fixed command. |
| `demo2` service account | No login shell; recovery managed identity is available to its worker, with bounded Azure REST requests. |
| Restricted SSH operator | Only fixed Submit commands; no arbitrary shell, forwarding, TTY or user rc. No service restart/config edits. |

The installer creates a root-owned SSH `Match User` drop-in with `ForceCommand`,
public-key-only authentication and forwarding/TTY restrictions, verifies
`sshd -t` and key effective options, then reloads SSH. It expects the image's
`/etc/ssh/sshd_config.d/*.conf` include and fails if absent/conflicting.
Retain an administrator session during installation and inspect the effective
configuration; validate refusal of shell, SFTP/SCP, forwarding and malformed
commands using the operator identity in an authorized rehearsal.

The forced Python wrapper accepts only this exact grammar:

```text
pwsh -NoProfile -File /opt/demo2/host/Submit-Request.ps1 -Action <Arm|Disable|Restore|Read|Status|Reset> -Target <Live|Twin> -RunId <nonempty GUID>
```

It does not invoke a shell to execute supplied text. Operators cannot supply
key URLs, queue paths or arbitrary PowerShell parameters. The queue is still
an authenticated **trusted operator** boundary, not a multi-tenant hostile-user
service: an operator can submit allowed demo actions and can disrupt availability
by flooding its own requests. Root/admin can override the whole boundary.
Do not add unrelated users to `demo2-operators`.

## Native control and explicit run lifecycle

Run `Show-ControlPanel.ps1` on Windows. Without `-AuthorizeLiveChanges`, only
Read and Status are available. The switch is required for Arm, Disable,
Restore and Reset in both UI and `Invoke-DemoControl.ps1`.

1. Select Live and **Refresh Document**. Check the actual account and real 200.
2. **Arm new run** creates a fresh GUID. Inspect acknowledged `Armed`, run ID,
   fixed UTC deadline and heartbeat. Arm performs a baseline read and confirms
   enabled=true/update authorization before durable acknowledgment.
3. **BIG RED BUTTON** sends Disable using that **same** run ID. There is no
   hidden Arm, deadline extension or automatic Twin switch.
4. **Refresh Document** makes a new request and clears previous plaintext first.
   Read status/errorCode/requestId/clientRequestId/UTC/account/target remain
   visible; content appears only for a real 200 from the selected account.
5. **Restore** begins recovery of that same pinned version. Observe
   `keyEnabled` separately from `readRestored` and perform a fresh read.
6. Let recovery reconcile continuously, then **Reset** only after the worker's
   required 60-second continuous recovery window and fresh enabled-key/read
   verification. A run with an **uncertain mutation is never eligible for
   automatic Reset**, even if reads recover; it requires manual investigation.
   Host rejects premature reset and conflicting/replayed runs. Do not clear
   `uncertainMutation` or edit durable state to bypass the gate. Reset is not
   cancellation.

The window displays host state, run/deadline/heartbeat and explicit errors.
Its heartbeat is the latest response snapshot, not a continuously proven
health signal; press Status and monitor independent alerts. An SSH wait can
make the window temporarily unresponsive; recovery remains on the VM.
Closing or killing the window/laptop does not cancel recovery.

After reopening, select the correct target and press **Status** to adopt its
persisted run ID for Restore/Reset. A fresh window does not enable Disable
merely by observing Armed; reconcile/restore the old run rather than inventing
a new ID. Nonzero SSH/controller responses and unknown timeouts are errors,
not successful acknowledgments. Never retry a timed-out Disable blindly.

## Independent recovery and monitoring

`demo2-watchdog.service` uses `Restart=always`; startup converts unresolved
state to recovery. Fixed UTC deadlines initiate restoration while the host
is healthy. The worker retains intent after uncertain disable completion,
continues enabled-state reconciliation and separately verifies Get Blob.
It keeps enabling/reconciling the key after reaching Recovered **until Reset
closes an eligible run**; a single good read does not stop that protection.
State is flushed with `Flush(true)`, atomically renamed and followed by
`sync -f` on its directory on the host disk, never behind the revocable storage key.
Request responses are transient: the daemon deletes response JSON files after
five minutes. They are not permanent evidence. Capture sanitized correlation,
state and read-result fields separately through the reviewed external evidence
and telemetry workflow; do not retain raw responses containing document text.

Watch systemd/journal and syslog tagged `demo2`. Recovery errors and heartbeat
must reach the separately provisioned AMA/Log Analytics path; validate ingestion
and alert delivery, not merely the presence of a DCR. Missing heartbeat and
overdue/failed recovery must alert outside the VM. Never log tokens, document
plaintext, private wrapping keys or SKR release payloads.

The timeout is **not an absolute maximum outage**: VM stop/disk loss,
unavailable HSM/Entra/network, stale clock or revoked rights can block recovery.
Do not deallocate the shared VM while any recovery intent is active.

## Separately authorized manual key enable

Use a separately authorized recovery login, correct tenant/subscription and
approved private route to Managed HSM. The helper checks `az account show`
before changing anything and constructs the exact pinned version URI from
the validated dedicated-demo config. No key is deleted or rotated.

```powershell
.\scripts\Restore-DemoKey.ps1 -ConfigPath .\config.local.json -Target Live `
  -AuthorizeKeyRestore -WhatIf
# After independent approval, invoke without -WhatIf and review confirmation.
```

The actual mutation is only:

```text
az keyvault key set-attributes --id <exact-allowlisted-version-URI> --enabled true
```

Each Azure CLI step checks its exit code. Readback verifies enabled=true on
the exact URI; this does **not** establish restored storage reads. Confirm
that no Disable is in flight; retain worker state and reconcile any late
mutation. Obtain a new authenticated Get Blob and inspect real evidence.
If recovery fails, preserve sanitized errors, use the independent alert route,
and report blocked recovery. Do not clear corrupt state or weaken policies
just to make the button usable.
