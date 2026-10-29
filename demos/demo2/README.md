# Demo 2: Guardrails and the kill switch

**Offline implementation kit, not a deployed or rehearsed demonstration.**
No Azure access, deployment, activation, key change, recording or Sovereign
Control Panel preview entitlement is established by these files. Compilation
and offline tests do not prove live recovery or service propagation.

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
- An approved **demo-only online custody exception** uses four disposable RSA
  wrapping pairs with a 3-of-4 threshold under one operator, not four separate
  custodians. A separate 32-GiB Standard SSD managed disk is attached at LUN 0
  for `/mnt/dispo-keys`. It uses platform-managed encryption independent of both
  demo CMKs and detaches rather than deletes with the VM. Administrators can
  access every pair; this is not multi-person control or offline custody.
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
The installer **does not download or install missing software**.
Azure CLI is needed only for separately authorized provisioning/manual recovery.

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

**Current demo decision:** the operator approved four disposable pairs with a
3-of-4 threshold and single-operator online custody on the Linux VM's persistent
managed disk. This replaces the earlier separate-custodian proposal only for
synthetic demo data. The templates attach an empty disk; they do not format,
mount, generate wrapping pairs or activate HSM. Follow the
[custody-disk gate](docs/operator-guide.md#persistent-demo-custody-disk-gate)
before any private material is generated. Do not copy it into Copilot artifacts.

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
