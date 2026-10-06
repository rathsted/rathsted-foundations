# Known Risks and Mitigations

This document lists accepted security risks in Rathsted Foundations, the mitigations in place, and when to re-evaluate. It is intended for internal review, auditors, and security-conscious operators.

Last reviewed: 2026-07-26

## 1. k3s Installer Trust Model

**Risk:** The k3s installer (`get.k3s.io`) is a remote script. The k3s installer (`get.k3s.io`) is fetched via HTTPS and piped to shell. The installer script itself is not checksum-verified before execution. The k3s binary is verified by the upstream installer against the official release checksum, but the installer script is trust-on-first-use.

**Mitigations:**
- The installer script itself verifies the k3s binary against the official release checksum
- `set -euo pipefail` and `--proto '=https' --tlsv1.2` enforce secure download
- Version is pinned via `INSTALL_K3S_VERSION` to prevent silent upgrades

**Residual risk:** A compromised `get.k3s.io` that changes between checksum pins could deliver a malicious installer. Fully hermetic installs (vendored binaries with repo-pinned checksums) would eliminate this.

**Re-evaluate:** When the project moves to a release-artifact model with vendored binaries, or if k3s provides an official checksum file for the installer script.

---

## 2. Namespace Exclusions (Policy Trust Boundary)

**Risk:** All Kyverno policies exclude `kube-system`, `flux-system`, and `kyverno` namespaces. Workloads in these namespaces bypass all security policies including image signing, registry restrictions, and privilege controls.

**Mitigations:**
- System components are installed via `bootstrap/install.sh` with pinned versions
- Only cluster administrators can deploy to system namespaces (RBAC)
- The signing trust boundary is documented in `docs/namespace-exclusions.md`
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

## 5. PolicyExceptions Enabled Cluster-Wide, Unscoped

**Risk:** Kyverno runs with `--enablePolicyException=true` on all controllers
(`cluster/policies/kyverno-install.yaml`) with **no** `--exceptionNamespace`, so a
`PolicyException` is honored from *any* namespace. A principal able to `create`
`policyexceptions.kyverno.io` in their own namespace could exempt their workloads
from any ClusterPolicy (non-root, signed-images, registry, seccomp, …).
Separately, `--protectManagedResources=false` leaves Kyverno-generated
default-deny NetworkPolicies editable at admission, and the `default` namespace is
excluded from the generated default-deny.

**Mitigations (current):**
- Single-operator / single-tenant v0: **no delegated Role grants `create` on
  `policyexceptions`** — a grep of the RBAC surface finds none, so exploitation
  requires cluster-admin today (**LOW** as shipped).
- Generated default-deny NetworkPolicies use `synchronize: true`, so drift is
  reconciled (leaving only a short window).
- The only shipped exceptions (`profiles/app-runtime`, `profiles/ai-inference`)
  are narrowly scoped by namespace + name and are operator-installed.

**Residual risk:** The moment namespace-admin is delegated to a tenant, this
becomes **HIGH** — self-service policy exemption.

**Planned remediation (requires live validation before commit):**
1. Add `--exceptionNamespace=kyverno-exceptions` to every `--enablePolicyException`
   controller. **Validate the flag against Kyverno v1.12.3 on a live cluster
   first** — an invalid flag crashloops the controller, and with
   `--forceFailurePolicyIgnore=false` that fails admission *closed* cluster-wide.
2. Create the admin-only `kyverno-exceptions` namespace and migrate the two
   existing exceptions into it (both already target their workload namespace
   explicitly via `spec.match…namespaces`, so relocating the resource is safe).
3. RBAC: never grant `create/update` on `policyexceptions.kyverno.io` in any
   delegated Role; keep it cluster-admin-only.
4. Consider `--protectManagedResources=true` and a policy denying pods in the
   `default` namespace (both are behavior changes to validate live).

**Re-evaluate:** Before any multi-tenant / delegated-namespace-admin deployment —
this remediation must land first. Tracked as a hardening item; not applied blind
because the flag change can brick admission if the version behavior differs.

---

## Summary

| # | Risk | Severity | Status | Mitigation |
|---|------|----------|--------|------------|
| 1 | k3s installer trust model | Medium | Accepted | Version-pinned, binary verified by upstream installer, script not checksummed |
| 2 | Namespace exclusions | Medium | Accepted | RBAC, pinned installs, documented boundary |
| 3 | Cosign key in repo | Low | Accepted | Encrypted, excluded from public, rotation documented |
| 4 | Signed-image test uses tag, not digest | Low | Accepted | Cosign signature binds to digest; tag-shift without matching signature still rejected at admission |
| 5 | PolicyExceptions unscoped cluster-wide | Low now / High if tenancy delegated | Remediation planned (live-validation required) | No delegated exception-create RBAC today; scope to `kyverno-exceptions` before delegating |
