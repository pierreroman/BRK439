# Demo 2: Guardrails and the kill switch

**Portable field setup tooling; clean-subscription live validation still required.**
No Azure access, deployment, activation, key change, recording or Sovereign
Control Panel preview entitlement is established by these files. Compilation
and offline tests do not prove live recovery or service propagation.

## Start from a clean checkout

For commands and portal actions only, use the [field cheat sheet](docs/field-cheat-sheet.md).

On Windows, install a current PowerShell 7 release (7.4 minimum; its .NET must
support AES PKCS#12 export), Azure CLI with Bicep, and OpenSSH client. Then:

```powershell
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Setup
```

**Selecting a mode is the instruction to perform it.** `Setup` creates billed
resources, activates the dedicated HSM, formats only its verified new blank disk
and configures the environment. `Rehearse` creates real policy probes and runs
a bounded key-disable/restore cycle. `Run` opens enabled operator controls;
Arm/Disable/Restore still require deliberate actions. There are no setup approval
phrases, repeated confirmation dialogs or mandatory price-quote inputs.
Plan, local Status and RetirementPlan do not deploy, change keys or delete resources.
Authentication/MFA and Azure permissions are still required; none are bypassed.

The command asks you to choose the actual subscription/tenant, deployment and
negative-test regions, confidential SKU, notification address, budget and
nonoverlapping network. It uses a pinned confidential Ubuntu 22.04 image and
creates new, isolated names. Quick setup explicitly uses **sandbox policy
approximations, not an SLZ**. For integration into an actual SLZ, use the
reviewed staged configuration path below; do not override inherited controls.

Subscription choices show the name, subscription GUID (`id`) and tenant GUID
(`tenantId`), so duplicate names remain distinguishable. Enter the listed number,
and the selected target is printed without a second confirmation. Blank, malformed or
out-of-range selections reprompt without choosing a default; `q` cancels.
Use an interactive PowerShell terminal: EOF or unavailable/noninteractive input
stops explicitly. Do not pipe Setup input; reuse the printed installation path
when retrying.

All custom lifecycle prompts explain invalid input and retry just that value.
Enter positive amounts such as `1234.56` without currency symbols or grouping,
a plain email address, and a network-aligned, nonoverlapping private `/24`.
Text prompts accept `q`/`cancel`; EOF or Ctrl+C stops the current operation.
Masked passphrase prompts also accept empty input to cancel;
new passphrases need at least 16 characters and a matching second entry.
Secure prompts refuse redirected input rather than hanging at EOF or reading
an unmasked/piped passphrase; use an interactive PowerShell terminal.
Unexpected Azure, disk or cryptographic failures stop for investigation rather
than being silently retried.

Suggestions are **manual-entry guidance, never Enter-to-accept defaults**.
Subscription/tenant and deployment geography still need your explicit choice.
A suggested VM must be catalog-eligible with enough reported family/regional
vCPU quota (`Standard_DC2as_v6` is preferred only when it qualifies); this does
not reserve capacity or prove permissions. The negative-test region suggestion
is outside this installation's allowed location. Suggested private `/24`s are
checked against discovered subscription VNets only, not peered/on-premises or
other-subscription networks. The budget example `100` is an alert threshold in
subscription billing currency, **not an estimate or a cap**. Costs and budget
approval are assumed to be handled outside the script; no quote amounts/source
are collected. Review regional prices separately. The kit never suggests or
guesses a retail rate. Secrets have requirements, not sample values.

Setup prints its private installation path. **Save that path.** On interruption,
rerun with `-Mode Setup -InstallPath '<printed path>'`; without that parameter
you are asking for a NEW installation and new billable HSM. Do not copy another
person's installation, keys or journal.

Fresh per-install SSH keys and passphrase-encrypted wrapping/recipient custody
are kept in ACL-restricted, Git-ignored `.private\demo2\installs\<id>`.
A separate encrypted PFX backup is created and its private keys verified with
RSA challenges **before billed provisioning**. Setup retains provider what-if,
ownership, permission, quota and private-connectivity checks without asking for
approval again. A passphrase is held only in memory for the current invocation,
reused for later backup verification and disposed on exit; it is never stored.
Back up the journal as sensitive configuration.

Choose a **new dedicated backup directory**, for example
`<your-drive>:\Demo2-Recovery\<installation-id>` on your approved recovery drive,
**not a drive root such as `D:\`**. No particular drive letter, encryption or
offline protection is assumed. Roots, repositories (including ignored folders), paths
inside/containing the installation, links and conflicting folders are rejected
before passphrase entry or ACL changes. Existing directories must already have
current-user-only FullControl; Setup never tightens a broad existing folder.
A separate directory is not proof of offline custody: you must independently
retain the encrypted PFX/domain copies and keep the passphrase separate. The
script verifies encryption/readability, matching keys/copies and protected paths,
not physical media separation or offline retention. No acknowledgment phrase
pretends to establish those facts.
Interrupted custody creation resumes the retained encrypted package and verifies
matching certificates without replacing keys. A malformed sole package or
legacy certificate-only state requires explicit recovery of its original
encrypted package; preserve all artifacts rather than regenerate them.

Resume reuses persisted target, region/SKU, network, notification budget and
backup location. It requests the existing passphrase only when encrypted-custody
work remains, not again at each stage. Configured resume needs no value prompts.
Before requesting that passphrase, resume displays and checks the recorded
encrypted backup path. If its medium is disconnected/remapped or its file is
missing, select reconnect/retry, locate the original encrypted `.pfx` file, or
copy the retained local encrypted package to a new dedicated backup directory.
The copy option exists only while a local package remains and authenticates it
first; it never creates replacement keys or overwrites another archive.
Relocated/copied backups must match the retained package and expected five keys,
pass private-key readability checks, and retain private ACLs outside Git and the
installation. Only then is `custody.json`'s backup path updated. The original
creation plan remains historical. Enter never chooses an action; `q`/EOF cancels
without changing the backup receipt. Access/device/crypto errors stop distinctly.
If neither original copy is accessible, setup remains blocked until you reconnect
or locate one; do not generate another custody package. A separate folder cannot
prove independent physical/offline custody. Keep the protected medium independent
and its passphrase separate. Custody recovery does not recreate a missing
security-domain backup; its recorded copy is rechecked before CMK creation.

The exact preceding custody-recovery and policy-isolation revisions can accept
the reviewed CLI transport update automatically only with known stages, unchanged
provisioning/guest-stage/worker files and the exact reviewed shared CLI module.
If a guest command is pending, Setup first checks the selected account and owned
group, then reads and reconciles that exact command before updating its source
receipt. The pending intent remains for the original stage to consume; no new
command is submitted during migration. Unknown source/runtime drift still stops.
Deployment names are stable on retry and isolated per installation. The
subscription-scoped policy deployment is `demo2-<nameSuffix>-sandbox-policy`,
not the shared `demo2-sandbox-policy`. Custom policy definitions already use the
installation suffix; their IDs remain unchanged, and assignments stay inside
the dedicated resource group. Foundation/storage what-if and create use matching
installation-ID names. Standalone deployment and policy-probe names are also
stable; repeated positive probes reuse their installation-specific candidate.
Existing earlier policy deployments and resources are not renamed or deleted.

The three recognized preceding source revisions can migrate this exact naming
patch only while preparing foundation, with custody/cost receipts only, no
journaled resource outputs and no pending guest operation. Setup first performs
read-only Azure checks: the selected account must match, any existing group must
carry this installation's ownership tags, retained foundation history must be
the matching terminal failure for the exact old policy name and original
configuration, and group deployment records must be terminal. The old policy
deployment must exist in the other region; both new custom-definition names must
be unused. A what-if failure before any group/history was created is also
supported. Only after these checks does Setup update its local source receipt
and retry the same installation, preserving custody and partial foundation.

Already provisioned installations, existing definitions of unproved ownership,
missing/mismatched history, missing groups with retained foundation history,
unknown source changes or active operations stop for explicit reconciliation.
The read-only facts needed are account identity, group ownership tags, exact
foundation parameters/state/error, old policy deployment location, deployment
states inside the dedicated group, and presence of the two suffix-scoped custom
definitions. Do not start a new installation, delete history/resources or edit a
fingerprint to bypass a stop. Status does not migrate or query Azure. The existing
installation's actual Azure state has to satisfy these checks; offline tests
cannot prove that it does.

Provisioning uses the Azure VM agent's Managed Run Command over the private
guest data paths, not a laptop Bastion tunnel. Only reviewed public source,
identifiers, public certificates and an additionally CMS-encrypted domain
envelope traverse command results. The guest never receives wrapping private
keys. After domain backup/readability verification, setup creates pinned CMKs,
private storage and content, installs the watchdog, and removes temporary
bootstrap grants/VM identity. It never uses Run Command as the stage button.

On Windows, the shared CLI helper runs the supported MSI launcher's own bundled
`python.exe -IBm azure.cli` directly with a native argument list. It does not send
REST URLs through `cmd.exe`: otherwise the literal `&$expand=instanceView` query
can become a second shell command. Native non-batch CLI applications use the same
argument-list transport. An unsupported batch layout without its bundled Python
stops explicitly; there is no shell fallback.

A nonzero local CLI exit after submission does **not** prove ARM rejected the
request. Resume the same installation. Setup retains operation ID, template
digest and start time, never resubmits pending intent, and observes the exact
command for at most 35 minutes of polling. Creating/running/unknown stays pending.
Only matching resource ID/location, installation/operation tags, normalized
source digest, successful ARM/guest states, exit code zero and a correlated
`ok: true` final receipt permit completion. A new stage cannot overwrite an
active or unrecorded command. Legacy commands without the new digest tag still
require the exact returned source digest; an absent/unreadable payload blocks.

Failure diagnostics retain the CLI exit/root error code and available safe
operation/state/request/correlation metadata in the console and exception `Data`, not raw
scripts, encoded payloads, ciphertext, server messages or malformed output.
Setup names the logical stage and command/method/resource, strips URL queries
and credentials, preserves nested structured Azure error codes and recognizes
bounded login/AADSTS, launcher and argument-validation diagnostics without
echoing argument values or arbitrary server text. A protected
`setup-diagnostic-<id>.local.json` inside the installation retains sanitized
ErrorRecord type/ID/category/stack, exit code and stdout/stderr classification.
It does not serialize target objects, bound parameters, ErrorDetails or raw
streams. Original errors are rethrown, and pending intent is unchanged. Keep
these local files private; do not attach them wholesale to chats or the Library.

Do not rerun mutating Setup blindly after an unexplained failure. Inspect local
progress, or explicitly request **read-only** Azure account and exact pending
managed-command metadata:

```powershell
pwsh -File .\demos\demo2\scripts\Get-SetupDiagnostic.ps1 -InstallPath '<existing path>'
pwsh -File .\demos\demo2\scripts\Get-SetupDiagnostic.ps1 -InstallPath '<existing path>' -ReadManagedCommand
```

The second command never submits, polls/retries, changes the source receipt,
clears intent, activates resources or changes keys. It checks the current
account, performs one exact command GET, and prints only correlated metadata
or a sanitized failure. It can write a protected diagnostic on CLI failure,
but never modifies installation/custody state. Share only its sanitized console
result. A successful read does not explain an earlier failed PUT; preserve
the operation/time and inspect matching Azure Activity Log evidence separately.
Connection-reset failures are identified separately, including a safe native
error number when present (Windows 10054 means a reset connection). They are not
proof that a submitted guest command failed. There is no automatic resubmission
or broad error retry. During payload preparation, resume processes an exactly
matching pending artifact first, before earlier files changed by a reviewed
tooling update; its original script/digest and correlated result still have to
match. An unknown or changed pending payload blocks instead of being replaced.

Guest failures also report allowlisted ARM/execution states, exit code, and
fixed phase/category metadata; arbitrary guest error text is never echoed.
The host preparer emits only phase, source line and exit number on failure,
not the failing command or its arguments.

The preceding field-host revision could add a Microsoft Ubuntu repository
already present in the image with a different `Signed-By`, causing APT to
reject its source list. The corrected preparer uses an installation-specific,
explicitly signed Ubuntu/Microsoft source list and separate APT lists. It does
not replace the image's existing repositories, disable signature checking,
or change trusted keys globally. Only byte-identical `demo2-powershell.list`
and `demo2-azure-cli.list` files from the old script are moved into the protected
installation staging directory; unknown contents or links stop recovery.

For the exact preceding source revision, Setup can reconcile only the terminal,
owned, source-matched, pre-activation GuestPrepare failure with exit 1 and the
specific APT `Signed-By` conflict. It archives the original operation/digest and
safe failure metadata before replacing that completed command, and permits only
the pinned public host-patch upload next. An interrupted patch upload retains
its own intent and is reconciled, not blindly replayed. The subsequent preparation
requires the existing disk receipt, matching UUID/ext4 filesystem, and expected
mounted volume; it cannot format or silently replace a disk. Missing or mismatched
custody state stops before package setup. No HSM activation or key creation is part
of this repair. Other source revisions, active/unknown operations, later-stage
installations and different failures remain blocked for explicit reconciliation.
Selecting Setup still authorizes its subsequent normal, potentially billed stages;
this is not a read-only diagnostic or proof of live readiness.

If reconciliation stops, preserve the journal and command. The required read-only
facts are the exact managed-command ID/location/tags, provisioning and execution
states, exit code, locally compared source/template digest, and correlated final
receipt. Do not paste the source/output wholesale, clear pending state, delete the
command, or start a replacement installation. Actual Azure ownership and retained
command evidence must satisfy these checks; offline tests cannot establish them.

```powershell
# These inspect local state only; no Azure call:
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Plan
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Status -InstallPath '<path>'
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode RetirementPlan -InstallPath '<path>'

# Requested actions: real probes/key outage, then deliberate operator controls:
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Rehearse -InstallPath '<path>'
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Run -InstallPath '<path>'
```

`-AuthorizeLiveChanges` remains accepted by the entry point for old commands but
is not required: the chosen mode supplies intent. It cannot turn Status or
RetirementPlan into a mutating mode. Standalone low-level scripts retain their
existing authorization switches and PowerShell confirmation behavior.

Rehearse/Run open their own temporary Bastion helper and verify the host key
obtained from the authenticated VM agent. The restricted operator route must
actually work: a listener alone is not readiness. The helper is stopped on exit;
the independent watchdog is not stopped. Do not reuse an occupied port or disable
SSH host verification to make a demonstration work.

**Minimum tenant/subscription access:** interactive Entra sign-in and permission
to read your own object ID; subscription Reader plus deployment/resource creation,
custom policy definition/assignment and role-assignment write permissions
(typically Owner, or carefully delegated equivalent with PIM activated).
Managed Run Command write is root-equivalent on this VM. The bootstrap identity
temporarily needs RG Reader, HSM local administrator, exact named-key create/read,
and per-account Blob contributor; runtime identities retain only scoped grants.
Provider registration is checked, never performed automatically. Unsupported
policies, telemetry-private-link mandates, quota, HSM availability or package
egress stop setup rather than weakening security.

**Timing and cost:** allow a substantial provisioning/activation window, not a
five-minute first install. Region capacity, agent readiness, package downloads
and role propagation can require retries. No clean-target duration has been
measured yet. Prepare and rehearse well before the session. Managed HSM is
continuously billed even unactivated and throughout protected soft-delete
retention (minimum seven days). Budget CVM, disks, Bastion, NAT/public IPs,
Private Link/DNS and Monitor too. A budget sends notifications; it is not a cap.
No automatic retirement, deletion or purge is performed.

**Readiness is deliberately conservative:** Setup ends at
`ConfiguredNeedsRehearsal`, not “ready.” Normal rehearsal is not crash/reboot,
manual-recovery, alert-delivery or pre-revoked-Twin evidence. Complete and
retain [all rehearsal gates](docs/rehearsal-checklist.md), including real
propagation measurements and the recorded fallback. Offline tests alone do not
establish that a clean subscription can be demoed.

## What this demonstrates

Use real policy Deny evidence, then a fresh read of a synthetic text document.
Arm independent recovery and disable the dedicated, pinned Managed HSM CMK
version for the selected storage account. Show the actual subsequent read
result and restore the same version. Do not manufacture a 403.

Azure Storage uses the CMK to wrap its account encryption key, not to encrypt
each document directly. Revocation does not recall previously downloaded
plaintext, erase data, defeat every privileged administrator or establish an
instantaneous revocation SLA. Diagnose real errors: not every 403 means CMK
revocation. Storage stays in the configured permitted region; this is not a
claim that every control-plane/diagnostic artifact stays there.

## Architecture and boundaries

- Bicep and PowerShell; no web UI, Terraform or landing-zone scaffold.
- Two initial storage accounts, Live and Twin, with different dedicated keys
  and pinned versions in one Managed HSM. Do not point this kit at production.
- Private endpoints and an authenticated private route/Bastion tunnel. No VM
  public IP. Storage service-side HSM use needs its reviewed trusted-service
  exception; do not describe all service traffic as traversing the VM endpoint.
- One shared Azure Linux **confidential** access/demo VM runs persistent systemd
  recovery independently of the laptop, tunnel and Windows Forms button.
  Boot disk, host state and telemetry must not depend on either revocable CMK.
- The shared VM is an accepted availability/security boundary: root or a
  privileged deployment administrator can affect its identities and service.
  VM outage, HSM/Entra/network outage or lost permissions can delay recovery.
- The legacy environment's **demo-only online custody exception** used four disposable RSA
  wrapping pairs with a 3-of-4 threshold under one operator, not four separate
  custodians. A separate 32-GiB Standard SSD managed disk is attached at LUN 0
  for `/mnt/dispo-keys`. It uses platform-managed encryption independent of both
  demo CMKs and detaches rather than deletes with the VM. Administrators can
  access every pair; this is not multi-person control or offline custody.
  **Portable installations instead generate fresh local wrapping pairs in
  an encrypted PFX with a separate backup; no wrapping private keys go to the
  guest.** Its independent data disk holds activation-time domain material and
  the encrypted transfer envelope; the raw domain is removed only after backup.
- Real-SLZ mode uses existing controls. Sandbox mode is an explicitly labeled
  approximation, not a deployed Sovereign Landing Zone.
- Optional SKR is a separate, off-clock specification; see [guide](docs/optional-skr.md).

The worker uses managed-identity IMDS tokens and bounded .NET HTTP Azure REST
requests, not Az modules. This is a small implementation deviation from the
planning proposal to use a Storage SDK: each Refresh still makes a fresh
authenticated Get Blob, without cached response reuse, automatic retry or
synthetic statuses. Tokens and document plaintext are not telemetry.

## Prerequisites and parameter contract

Review [operator setup](docs/operator-guide.md) before installing anything.
Windows needs PowerShell 7.4+, native Windows Forms, OpenSSH client and a trusted
`known_hosts` entry. Reviewed Linux prerequisites are PowerShell 7.4+ at
`/usr/bin/pwsh`, Python 3 at `/usr/bin/python3`, OpenSSH server/SFTP, systemd,
`logger`, sudo, coreutils/user management and synchronized NTP via timedatectl.
The low-level watchdog installer **does not download missing software**.
The portable guest-preparation stage separately installs Azure CLI/PowerShell
from fingerprint-checked signed Microsoft repositories as part of requested Setup.
Azure CLI is required for portable setup and separately authorized recovery.

Copy `config.example.json` to a private, ignored environment configuration.
The example is intentionally incomplete and is not deployment-ready.
`config.schema.json` describes its shape. `Import-DemoConfig -Phase Foundation`
already requires explicit region, network, budget/retention, alert, initial
administrator and core scope inputs; it is not a minimal empty bootstrap.
Runtime adds the controller/storage identity GUIDs and exact pinned versions.
Both phases retain the Foundation validation requirements.
Keep actual configuration, credentials, security-domain material and evidence
out of source control. The configuration contains nonsecret identifiers but
still deserves access control; never place access tokens/private keys in it.

| Inputs | Required meaning |
|---|---|
| `tenantId`, `subscriptionId`, `resourceGroup`, `purpose` | Explicit dedicated demo scope; `purpose` stays `demo2-only`. |
| `location`, `allowedLocations`, `deniedLocation`, `policyMode` | Reviewed region and existing-SLZ/sandbox choice; no inferred subscription or geography. |
| `vmSize`, `imageReference`, `allowedConfidentialVmSkus` | Region/quotas and confidential security/image compatibility must be checked. |
| `network` | Explicit nonoverlapping CIDRs, private access choice and approved egress. Native Bastion tunnel support is a priced prerequisite. |
| `hsmName`, `hsmRetentionDays`, `initialAdminObjectIds`, `manualRecoveryObjectId` | Dedicated HSM, explicit 7-90 day protected retention (example: 7), activation custodians, separate recovery operator. |
| `controllerIdentityClientId`, `controllerPrincipalId` | Host recovery UAMI identifiers, not secrets. |
| `liveStorageIdentityPrincipalId`, `twinStorageIdentityPrincipalId` | Separate storage CMK identities with per-key local HSM roles. |
| `targets.Live`, `targets.Twin` | Each has `accountName`, distinct `keyName`, exact 32-hex `keyVersion`, finite `recoveryTimeoutSeconds`. Defaults propose 180s Live / 1800s Twin, not SLAs. |
| `sshHost`, `sshPort`, `sshUser`, `sshIdentityFile` | Existing authenticated tunnel endpoint, restricted operator user, optional local private-key *path*. No private-key contents. |
| `container`, `blob`, `watchdogIntervalSeconds` | Synthetic document location and healthy-worker interval (default proposal 10s). |
| `alertEmail`, `budgetAmount`, `logRetentionDays` | Explicit operational/cost settings; keep real contacts private. |
| `enableSkr` | False initially; does not itself implement a guest SKR demonstration. |

## Staged preparation — not authorized by this README

1. Review current prices, availability, aliases, policy assignments, SKU/image,
   networking and quota. Obtain explicit deployment and live-change permission.
2. Provision network, identities, Managed HSM, confidential host/access and
   monitoring. Establish the separate administrator connection.
3. Activate the HSM; then provision exact keys and scoped HSM **local RBAC**.
   HSM activation precedes data-plane setup; ARM role assignments are not a
   substitute for local HSM roles.
4. Create both accounts with CMK configured at creation; upload only synthetic
   content; verify private routing, authentication and the pinned bindings.
5. Install the watchdog using the separate admin path; verify restricted
   operator SSH and external monitoring.
6. Complete [rehearsal gates](docs/rehearsal-checklist.md). Only then consider
   [the five-minute stage run](docs/stage-runbook.md).

Storage identities use only their own keys. Controller attribute read/write is
key-scoped and the worker enforces exact versions. HSM attribute-write rights
are **not enable-only permissions**. Never grant delete, purge, rotate, release,
export or role-management as a convenience for the button. A separately
authorized recovery operator remains essential.

## Native operator entry point

These examples describe future authorized operations; none were executed while
building this kit:

```powershell
.\scripts\Show-ControlPanel.ps1 -ConfigPath .\config.local.json
# Read/Status only by default. Explicitly authorize mutations for rehearsal:
.\scripts\Show-ControlPanel.ps1 -ConfigPath .\config.local.json -AuthorizeLiveChanges
```

Select Live or the prominently labeled **PRE-REVOKED FALLBACK ACCOUNT** Twin.
Press **Arm new run**, verify the acknowledged run/deadline, then the **BIG RED
BUTTON**. Disable does not silently Arm. Refresh clears old plaintext before a
new real read and only displays content for an actual HTTP 200 for that account.
No automatic fallback. Restore and Reset are also authorization-gated.
Closing the window does not stop/disarm the watchdog. See
[recovery and restricted SSH](docs/operator-guide.md).

## Activation, security-domain custody and cost

Azure CLI receives configuration and role definitions through JSON files rather
than inline JSON arguments, avoiding Windows command-line quote stripping.
Temporary role-definition files contain permissions, never key material, and
are removed after the CLI call.

A new HSM needs initial administrators, at least **three RSA wrapping
certificate/key pairs** (up to ten supported), and an explicitly approved
quorum. Normal security-domain guidance uses separate offline custodians;
the specific synthetic-demo exception is below. Keep all private wrapping keys
and the downloaded security domain **outside the repository, session attachments
and recordings**. Provisioning an HSM is not activation. No wrapping private
material is generated by the templates.

**Legacy deployment decision (not the portable default):** the operator approved four disposable pairs with a
3-of-4 threshold and single-operator online custody on the Linux VM's persistent
managed disk. This replaces the earlier separate-custodian proposal only for
synthetic demo data. The templates attach an empty disk; they do not format,
mount, generate wrapping pairs or activate HSM. Follow the
[custody-disk gate](docs/operator-guide.md#persistent-demo-custody-disk-gate)
before any private material is generated. Do not copy it into Copilot artifacts.
For NEW portable installs, the Setup command implements fresh local encrypted
custody instead. A domain readability/key-match test is not a full HSM-key
backup or disaster-recovery drill; CMKs created later need a separately reviewed
full HSM backup/recovery procedure if the synthetic data must survive HSM loss.

Managed HSM is dedicated, continuously billed infrastructure. Obtain a current
regional quote; no price is asserted here. A **soft-deleted HSM continues to
incur charges**, and purge protection prevents early purge during retention.
Deleting the resource group does not necessarily stop that bill. Also budget
confidential VM/disks, Bastion native access, private endpoints/DNS, outbound
networking, Log Analytics ingestion/retention, alerts and optional Attestation.
Do not substitute Key Vault Premium without explicit approval.

## Evidence and fallback status

- [Operator and manual recovery guide](docs/operator-guide.md)
- [Stage runbook](docs/stage-runbook.md)
- [Rehearsal, recording and evidence checklist](docs/rehearsal-checklist.md)
- [Optional off-clock SKR specification](docs/optional-skr.md)

No run recordings were created. The closing SCP **“preview”** cue is a
30-second presentation request with **unverified access/entitlement and opening
date**. Use it only after verification; it is not the key-disable mechanism.
No preview access or deployment success is claimed.

## Offline verification

From this directory, run `.\tests\Invoke-OfflineChecks.ps1` with PowerShell 7.4+,
Pester 5+ (including Pester 6), PSScriptAnalyzer, Azure CLI/Bicep and Checkov
available. This performs no Azure access or live key operation. Infrastructure
tests inspect compiled templates; transport and recovery tests use explicit mocks.
Windows CLI boundary tests also need a local Python 3 executable with the
standard-library `venv` module. They create a temporary fake Azure package and
real `.cmd`/native-process fixture without installing packages or contacting Azure.
If a Windows Checkov launcher selects the wrong Python, pass both
`-CheckovPython` (the actual virtual environment's `Scripts\python.exe`) and
`-CheckovScript` (its `Scripts\checkov` entry-point file) to the runner.
The native Forms smoke test constructs and disposes controls without opening a
window or sending an SSH request. Resource-scoped Checkov exceptions are
explained in [infrastructure notes](infra/README.md); skipped checks are not
claims of production certification.

The separately authorized `scripts\Invoke-LiveRehearsal.ps1` captures sanitized
JSONL evidence outside the repository. It refuses to call a generic 403 proof
of CMK revocation, distinguishes key enable from restored reads, and reports a
missing live denial as a failed rehearsal rather than faking the stage moment.
Normal success still does not prove crash recovery; use the failure-injection
checklist separately.
