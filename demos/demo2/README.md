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

The command asks you to choose the actual subscription/tenant, deployment and
negative-test regions, confidential SKU, notification address, budget and
nonoverlapping network. It uses a pinned confidential Ubuntu 22.04 image and
creates new, isolated names. Quick setup explicitly uses **sandbox policy
approximations, not an SLZ**. For integration into an actual SLZ, use the
reviewed staged configuration path below; do not override inherited controls.

Setup prints its private installation path. **Save that path.** On interruption,
rerun with `-Mode Setup -InstallPath '<printed path>'`; without that parameter
you are asking for a NEW installation and new billable HSM. Do not copy another
person's installation, keys or journal.

Fresh per-install SSH keys and passphrase-encrypted wrapping/recipient custody
are kept in ACL-restricted, Git-ignored `.private\demo2\installs\<id>`.
An independently retained encrypted PFX backup is mandatory **before billed
provisioning**. Setup verifies its private keys with RSA challenges, then
requires a current quote, private/egress approval, complete what-if review and
an explicit risk acknowledgment. No `-Yes`, stored passphrase or unattended
activation bypass exists. Back up the journal as sensitive configuration.

Provisioning uses the Azure VM agent's Managed Run Command over the private
guest data paths, not a laptop Bastion tunnel. Only reviewed public source,
identifiers, public certificates and an additionally CMS-encrypted domain
envelope traverse command results. The guest never receives wrapping private
keys. After domain backup/readability verification, setup creates pinned CMKs,
private storage and content, installs the watchdog, and removes temporary
bootstrap grants/VM identity. It never uses Run Command as the stage button.

```powershell
# These inspect local state only; no Azure call:
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Plan
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Status -InstallPath '<path>'
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode RetirementPlan -InstallPath '<path>'

# Separately authorize actual policy probes and bounded demo-key changes:
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Rehearse -InstallPath '<path>' -AuthorizeLiveChanges
pwsh -File .\demos\demo2\Start-Demo.ps1 -Mode Run -InstallPath '<path>' -AuthorizeLiveChanges
```

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
from fingerprint-checked signed Microsoft repositories after explicit consent.
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
