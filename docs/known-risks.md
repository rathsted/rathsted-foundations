# Known Risks and Mitigations

This document lists accepted security risks in Rathsted Foundations, the mitigations in place, and when to re-evaluate. It is intended for internal review, auditors, and security-conscious operators.

Last reviewed: 2026-10-06

## 1. k3s Installer Trust Model

**Risk:** The k3s installer script is downloaded from the k3s release tag on GitHub
(`raw.githubusercontent.com/k3s-io/k3s/<version>/install.sh`) over HTTPS and verified
against a sha256 checksum pinned in `bootstrap/install.sh` before execution. The installer
then verifies the k3s binary against the official release sha256 file.

**Mitigations:**
- The installer script is verified against a sha256 pinned in `install.sh` (`RATHSTED_K3S_INSTALLER_SHA256`) before it runs
- Downloads use `--proto '=https' --tlsv1.2` to enforce HTTPS-only, TLS 1.2 minimum
- GitHub SSH host keys are pinned; no `ssh-keyscan`
- The installer verifies the k3s binary against the official release sha256 file
- `INSTALL_K3S_VERSION` pins the k3s binary version to prevent silent upgrades
- Flux, Cosign, Syft, and Grype are downloaded as release archives and verified against the checksums file published in the same GitHub release

**Residual risk:**
- The sha256 checksums for Flux, Cosign, Syft, and Grype verify integrity against the same GitHub release — a compromised release could ship matching checksums. This proves integrity but not independent provenance.
- Cosign, Syft, and Grype release archives are not additionally signature-verified (no cosign-on-cosign). Pins must be updated deliberately when bumping versions.
- The pinned installer sha256 is only as trustworthy as the moment it was recorded: a change to the upstream script fails verification, but a pin recomputed from an already-compromised upstream when bumping `K3S_VERSION` would be accepted. Re-pin deliberately and compare against more than one source.

**Re-evaluate:** When the project adopts release artifact signing (e.g., SLSA provenance or a sigstore bundle for the installer script), or when moving to a fully vendored offline bootstrap model.

---

## 2. Namespace Exclusions (Policy Trust Boundary)

**Risk:** All Kyverno policies exclude `kube-system`, `flux-system`, and `kyverno` namespaces. Workloads in these namespaces bypass all security policies including image signing, registry restrictions, and privilege controls.

**Mitigations:**
- System components are installed via `bootstrap/install.sh` with pinned versions
- Only cluster administrators can deploy to system namespaces (RBAC)
- The signing trust boundary is documented in the policy YAML itself (`policies/require-signed-images.yaml`)
- Network policies in `flux-system` restrict egress and ingress

**Residual risk:** A compromised system component or a cluster admin deploying an unapproved workload to a system namespace would bypass all policies.

**Re-evaluate:** If multi-tenant deployment models are supported, or if Kyverno adds support for system-namespace policy tiers.

---

## 3. Cosign Private Key in Repository

**Risk:** The encrypted cosign private key (`supply-chain/cosign/cosign.key`) is stored in the private repository. While encrypted with scrypt KDF, it is not in a hardware security module or cloud KMS.

**Mitigations:**
- The key is encrypted and requires a passphrase to use
- The key is excluded from the public repo via `.gitignore` and the publish safety checks
- The public key (`cosign.pub`) is the only key that ships publicly
- Key rotation procedure is documented in `supply-chain/cosign/README.md`

**Residual risk:** An attacker with access to the private repo and the passphrase could sign arbitrary images.

**Re-evaluate:** Before production deployment to customer environments. Production deployments should use KMS-backed keys (AWS KMS, GCP KMS, Azure Key Vault, or HashiCorp Vault).

---

## 4. Signed-Image Test Uses Tag, Not Digest

**Risk:** The positive admission test for `require-signed-images` (`tests/good-manifests/signed-rathsted-image-pod.yaml`) references the demo image by tag (`ghcr.io/rathsted/foundations-demo:1.0.0`), not by content digest. The test proves "a currently-signed image is admitted" — it does not prove "the image bytes admitted are the bytes that were signed at release time."

**Mitigations:**
- The cosign signature on the demo image binds to the digest, not the tag, so a tag-shifted image without the matching signature is still rejected by the policy at admission time
- Production deployments should pin to digests in their own manifests; the test fixture is an internal admission check, not a customer-facing artifact

**Residual risk:** If the `1.0.0` tag is shifted to a re-signed image (legitimate re-release with a new digest), the test continues to pass and reflects the new signed content rather than the original. A registry-side compromise that shifts the tag without re-signing would be caught by the policy (signature check fails). A compromise that shifts the tag AND re-signs with the project key implies the signing key is already compromised, which is out of scope for an admission test to detect.

**Re-evaluate:** When the test surface is hardened to digest-pinned fixtures alongside a key-rotation-aware test cosign key, or when the signed-image positive test moves from a single shared demo image to a per-test ephemeral signed artifact.

---

## 5. PolicyExceptions: Scoped to `kyverno` Namespace, Residual Risks Remain

**Current state:** Kyverno runs with `--enablePolicyException=true --exceptionNamespace=kyverno`
on all controllers (`cluster/policies/kyverno-install.yaml`). Only `PolicyException`
objects placed in the `kyverno` namespace take effect. A tenant cannot exempt their
own workloads by creating exceptions in their own namespace.

`--protectManagedResources=false` (unchanged) leaves Kyverno-generated default-deny
NetworkPolicies editable by anyone with write access to NetworkPolicy resources. The
`default` namespace is excluded from the generated default-deny.

**Mitigations:**
- `--exceptionNamespace=kyverno` restricts exception creation to cluster-admin
  (no delegated Role grants `create` on `policyexceptions.kyverno.io`).
- Generated default-deny NetworkPolicies use `synchronize: true`, so drift is
  reconciled on the next Kyverno background scan (leaving only a short window).
- The only shipped exception (`profiles/app-runtime/policy-exception.yaml`) is
  narrowly scoped by workload name and namespace.

**Residual risk:**
- Any principal who can write to the `kyverno` namespace (cluster-admin) can
  create arbitrary PolicyExceptions. Keep tight RBAC on the `kyverno` namespace.
- `--protectManagedResources=false` means Kyverno-generated NetworkPolicies can
  be manually edited or deleted between reconcile cycles.
- The `default` namespace has no generated default-deny NetworkPolicy.

**Planned hardening:**
- Set `--protectManagedResources=true` — validate against Kyverno v1.19.1 on a
  live cluster first; an invalid flag crashloops the controller, and with
  `--forceFailurePolicyIgnore=false` that fails admission *closed* cluster-wide.
- Add a policy denying pods in the `default` namespace.
- RBAC: never grant `create/update` on `policyexceptions.kyverno.io` in any
  delegated Role; keep it cluster-admin-only.

**Re-evaluate:** Before any multi-tenant / delegated-namespace-admin deployment.

---

## Summary

| # | Risk | Severity | Status | Mitigation |
|---|------|----------|--------|------------|
| 1 | k3s installer trust model | Medium | Accepted | Installer script sha256-pinned before run; binary verified by installer; checksums prove integrity not provenance; no Cosign/Syft/Grype signature verification |
| 2 | Namespace exclusions | Medium | Accepted | RBAC, pinned installs, documented boundary |
| 3 | Cosign key in repo | Low | Accepted | Encrypted, excluded from public, rotation documented |
| 4 | Signed-image test uses tag, not digest | Low | Accepted | Cosign signature binds to digest; tag-shift without matching signature still rejected at admission |
| 5 | PolicyExceptions scoped to `kyverno` namespace | Low (single-operator); High if namespace-admin delegated | Mitigated (exception namespace locked to `kyverno`) | `--exceptionNamespace=kyverno` prevents tenant self-exemption; `--protectManagedResources=false` and default namespace gap remain |
