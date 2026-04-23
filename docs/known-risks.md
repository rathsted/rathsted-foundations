# Known Risks and Mitigations

This document lists accepted security risks in Rathsted Foundations, the mitigations in place, and when to re-evaluate. It is intended for internal review, auditors, and security-conscious operators.

Last reviewed: 2026-04-07

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

## Summary

| # | Risk | Severity | Status | Mitigation |
|---|------|----------|--------|------------|
| 1 | k3s installer trust model | Medium | Accepted | Version-pinned, binary verified by upstream installer, script not checksummed |
| 2 | Namespace exclusions | Medium | Accepted | RBAC, pinned installs, documented boundary |
| 3 | Cosign key in repo | Low | Accepted | Encrypted, excluded from public, rotation documented |
