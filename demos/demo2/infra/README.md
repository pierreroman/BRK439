# Offline infrastructure contract

`main.bicep` is subscription-scoped. `foundation.bicep` and `storage.bicep`
orchestrate the dedicated resource group; `policy-example.bicep` is an explicitly
authorized, separate policy probe. Configuration must pass `Demo.Common.psm1`.
The parameters example is deliberately incomplete, not a deployment shortcut.

## Mandatory order and approvals

1. Fill a private copy of `config.example.json`: real names/region, confidential
   image and available SKU, administrators, SSH **public** key, recipient and a
   positive monthly budget. Review current regional pricing including continuous
   HSM charges during its explicitly configured protected soft-delete retention
   (`hsmRetentionDays`, 7-90 days; example: 7). A budget is notification, not a
   spending cap. Do not deploy until the retention-inclusive price is approved.
2. Run `Test-AzurePrerequisites.ps1` offline. Its explicit
   `-AuthorizeAzureReads` mode checks current CLI context, policy aliases,
   effective assignments/exemptions, confidential capability/image and reports
   quota. Review all results, quotas, service capacity, inherited policies and
   exemptions before deployment. No provider auto-registration or SLZ changes.
3. `Deploy-Demo.ps1 -Stage foundation` defaults to an offline plan. Later
   `-AuthorizeDeployment -PreflightReviewed` permits a billable deployment after
   `ShouldProcess`. This creates identities, HSM, confidential VM, networking,
   AMA/DCR, alerts and a budget. It does **not** install the host worker or create
   keys. Record the returned principal/client IDs in private configuration.
4. Custodians manually activate the HSM **over approved private connectivity**
   using their approved quorum and wrapping certificates. At least three RSA
   wrapping key pairs and an approved quorum are separate prerequisites. Keep
   private wrapping keys/security-domain backups outside the repository, output,
   transcripts and recordings. No script here handles those materials.
5. From approved private connectivity, `Initialize-Hsm.ps1` defaults offline.
   Later `-AuthorizeLiveChanges -ActivationConfirmed -ResolvedConfigPath <protected-path>`
   creates/resolves non-exportable RSA-HSM wrapping keys and HSM **local** RBAC,
   not ARM role assignments. The separate provisioning operator needs explicit
   HSM-local key-list/read/create and role-management authorization; being an
   initial HSM Administrator alone does not grant key creation. Arrange these
   approved provisioning rights manually, not on the recovery identity.
   It never rotates an existing key implicitly.
   Storage gets Crypto Service Encryption User at its own `/keys/name`;
   controller and manual recovery get only key attribute read/write at each
   dedicated key. The grant is key-, not version-scoped. The controller must
   enforce the pinned version. Verify role/identity propagation.
6. `Deploy-Demo.ps1 -Stage storage -AuthorizeDeployment -PreflightReviewed -HsmBootstrapVerified`
   requires complete runtime config and checks enabled pinned RSA-HSM keys and
   encryption-user assignments first. StorageV2 LRS accounts have their UAMIs and
   distinct pinned CMKs **at creation**, private endpoints/DNS, TLS 1.2, no shared
   key/anonymous/public access. Controller has account-scoped Reader for binding
   checks and Blob Data Reader. The provisioning operator separately needs Blob
   Data Contributor for `Initialize-Content.ps1 -AuthorizeLiveChanges`; no script
   grants that broad data-write right automatically.
7. Install the independent host worker, prove telemetry/recovery and upload
   synthetic content using the same private route. Run policy probes and
   rehearsal only with their separate live-change approvals.

## Network and monitoring boundaries

The VM has no public IP and no implicit default outbound access. Provisioned
Bastion is Standard with native-client tunneling. The only public IPs are Bastion
and optional NAT. `existing-private-connection` requires explicit
`-ExistingPrivateConnectivityApproved`: the operator must establish approved
routes, VNet peering/VPN as applicable, and private DNS resolution; these scripts
do not scaffold or modify the SLZ. With `provisionNatGateway=false`, pass
`-ExistingEgressApproved` only after supplying approved routed egress for Entra,
ARM, AMA and package installation. This module does not invent that connectivity.
Private DNS zones assume Azure public cloud and default Azure DNS or an approved
forwarder to those linked zones.

Managed HSM has public access disabled, default deny, purge/soft-delete protection
and the **explicit AzureServices trusted-service bypass** needed for Storage's
service-side CMK operation. The VM's private endpoint alone is not that path.
An SLZ restriction blocking this service scenario must block deployment, never
be weakened. Test DNS and the actual Storage-to-HSM service path during rehearsal.

The VM boots from a TPM-bound confidential OS disk encrypted with
platform-managed keys (`DiskWithVMGuestState`), independent of both demo CMKs.
Keep watchdog durable state on this OS disk,
not the custody disk or a local temporary disk. The confidential image/SKU and OS disk encryption
pairing must be verified before deployment; disk size is 64 GiB (below the
documented confidential-encryption size limit). Confidential OS disk encryption
is selected at creation and cannot be toggled later. Do not substitute
`VMGuestStateOnly`, which does not enable confidential OS disk encryption.
System-assigned identity serves AMA; the controller UAMI serves the worker.
AMA collects `user` and `local0` syslog into Log Analytics; watchdog JSON must
include `event=Heartbeat`, `RecoveryArmed`, `RecoveryConfirmed`,
`RecoveryOverdue`, `RecoveryFailed` or `StateCorrupt`, and nested `data.runId`
and `data.deadlineUtc` for arm/confirmation events.
Scheduled query rules evaluate every five minutes and page the action group for
a heartbeat older than five minutes or overdue/failed recovery. A separate
external query correlates armed runs and confirmed recovery; an unconfirmed run
becomes eligible two minutes past its persisted deadline, even when no worker
overdue event arrives (one-day query horizon). Notification also depends on the
next five-minute evaluation and telemetry ingestion; it is not guaranteed two
minutes after the deadline. The one-minute alert tier does not support these
queries and the one-day window. None of these alert timings changes the watchdog
deadlines or establishes an outage SLA.
Test alert ingestion and delivery, including VM
outage and recovery. The accepted shared-VM outage limitation still applies:
external alerts are notification, not an independent key-recovery worker.
The initial alert deployment skips KQL validation because a new workspace may
not yet contain the Syslog table. This is not acceptance of an invalid query:
validate all three rules against actual ingested events, missing heartbeats and
overdue recovery before arming. Compilation cannot validate those live queries.

The approved demo-only custody amendment adds a separate 32-GiB
`StandardSSD_LRS` managed disk at LUN 0. `EncryptionAtRestWithPlatformKey`
is independent of the revocable storage CMKs; confidential OS disk encryption
does **not** describe this data disk. Disk import/export public access is disabled
and network access is denied. VM deletion detaches the disk; deleting its resource
group can still delete it. Retention adds ongoing cost, not a backup guarantee.
No automatic formatting, mounting or private-key generation occurs. Follow the
operator mount/permissions gate before using `/mnt/dispo-keys`. Recovery must
boot and work even when this custody disk cannot mount.

Sandbox definitions are subscription resources assigned only to the dedicated
demo RG: allowed locations, Storage CMK Deny, confidential security type **and**
approved VM SKU Deny. `existing-slz` emits no definitions or assignments and never
recreates/enables an existing SLZ control. It requires existing assignment IDs
and reviewed effective policies/exemptions. Policy aliases are deployment gates,
not facts inferred from compilation.

`Test-PolicyExamples.ps1` defaults offline and executes each unique real candidate
only with explicit authorization. Run the compliant positive control separately.
Negative success requires actual Azure CLI error or deployment-operation JSON proving
`RequestDisallowedByPolicy`, intended assignment/definition and evaluated
conditions. A preflight denial may leave no root/child deployment history:
unavailable operation queries are explicitly warned and recorded, and the
captured CLI error must still provide the same exact proof. Other failures
never count. Candidates are retained for explicit
operator review/cleanup; no script automatically deletes resources. Cross-region
CMK provider validation may precede policy evaluation and needs rehearsal.

Optional SKR is not provisioned by the base kit. Keep `enableSkr=false` until a
separately reviewed attestation issuer/claim policy and confidential guest client
are supplied; never reuse either Storage CMK or output private released material.

APIs are pinned. Diagnostic settings use `2021-05-01-preview` because that
resource family has no stable API; this explicit exception is not a claim that
the other resources use preview APIs. Local compilation/security scans are not
Azure validation or evidence of policy/recovery effectiveness.

## Explicit, resource-scoped scanner exceptions

No scan finding is silently ignored. Bicep resource annotations document:

| Check | Resource | Justification / compensating control |
| --- | --- | --- |
| CKV_AZURE_50 | Confidential VM | AMA is the single explicitly declared extension required for watchdog syslog telemetry; globally disabling VM extensions would disable this monitoring path. |
| CKV_AZURE_97 | Confidential VM | The OS uses TPM-bound confidential disk encryption; the separate data disk has platform-managed encryption at rest. No unvalidated encryption-at-host combination is added merely to satisfy a scanner. No temp/data disk holds watchdog recovery state. |
| CKV_AZURE_151 | Confidential VM | The generic ADE/EncryptionAtHost rule does not recognize confidential OS disk encryption. `DiskWithVMGuestState` with platform-managed keys protects boot/recovery independently of revocable CMKs; do not add deprecated ADE or a demo-CMK DES. |
| CKV_AZURE_36 | Storage account module | `bypass=None` is deliberate: public blob access and shared keys remain disabled, private endpoints provide data access. AzureServices bypass is explicitly configured on **HSM** for the Storage service-side CMK path. |
| CKV_AZURE_206 | Storage account module | Approved low-cost, synthetic-data, same-region LRS durability trade-off. No geo-replication; a production topology would need its own durability/cost decision. |
| CKV_AZURE_93 | Custody managed disk | Platform-managed encryption deliberately avoids dependency on either revocable demo CMK. Single-operator online wrapping-key custody is an explicitly accepted synthetic-demo exception, not production key-custody guidance. Public disk access/export is disabled; administrator mount/permissions checks remain required. |

Microsoft's [confidential VM ARM guide](https://learn.microsoft.com/en-us/azure/confidential-computing/quick-create-confidential-vm-arm#define-custom-parameter-file)
explicitly documents `DiskWithVMGuestState` as confidential OS disk encryption
with a platform-managed key. The
[disk encryption comparison](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-overview)
distinguishes confidential disk encryption from generic ADE/encryption-at-host
recommendations, whose detection does not cover confidential OS disk encryption.
It allows encryption at host for **other disks** on a CVM; the kit does not
assert a universal incompatibility, nor enable an unvalidated combination on a
required confidential SKU. These annotations cover only the listed resources
and check IDs, not future resources or all security checks.
