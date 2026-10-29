# Optional off-clock Secure Key Release specification

**Specification only. No SKR guest client, release policy, execution, attestation
proof or released key is produced by this kit.** `enableSkr` defaults false.
This extension does not belong in the five-minute slot.

## Security and setup gates

1. Obtain separate approval and verify current service availability and pricing.
2. Use a **different exportable RSA-HSM key** from either storage CMK. Never
   reuse, export or release a storage key to make the demonstration convenient.
3. Review a release policy bound to a validated attestation issuer and the
   expected confidential-VM claims. No permissive any-attestation policy.
4. Pin/review the supported guest attestation/SKR client and confidential image
   pairing; verify a confidential VM security type. An allowed SKU list or a
   Trusted Launch VM does not establish confidential attestation.
5. Give laptop and CVM callers equivalent release authorization and private
   HSM reachability. Keep caller tokens private.
6. On the laptop, prove rejection is for missing/unacceptable attestation, not
   RBAC, firewall, DNS or an unsupported API/client.
7. Inside the confidential guest, obtain and validate fresh attestation and
   complete release inside the TEE using the reviewed client.
8. Report sanitized success/error evidence only. Never display, save, log,
   record or attach released private key material/exportable payloads.

Do not borrow VM attestation for the laptop comparison. Do not weaken SLZ
controls to make the optional path pass. If equivalent authorization or route
cannot be established, do not claim attestation alone caused the comparison.

## Relationship to the core demo

Storage CMK revocation and recovery are independent of this example. The main
access VM is confidential even with SKR disabled; a VM screenshot does not
prove the optional release policy. No SCP preview access or portal recording
is implied by SKR preparation.
