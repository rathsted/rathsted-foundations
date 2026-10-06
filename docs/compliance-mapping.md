# Compliance Mapping (v0 — Illustrative)

This document maps Rathsted Foundations controls to industry frameworks. This is an illustrative starting point, not a certification claim. Each mapping links to the enforcing mechanism in the repo.

## Kyverno Policies → CIS Kubernetes Benchmark

| Policy | CIS Control | Description | Enforcement |
|--------|------------|-------------|-------------|
| `disallow-privileged` | 5.2.1 | Minimize admission of privileged containers | Enforce |
| `require-non-root` | 5.2.6, 5.2.7 | Minimize admission of root containers; require non-root | Enforce |
| `disallow-host-namespaces` | 5.2.2, 5.2.3 | Minimize admission of containers with hostPID/hostIPC/hostNetwork | Enforce |
| `restrict-hostpath` | 5.2.4 | Minimize admission of containers with hostPath volumes | Enforce |
| `require-resources` | — | Resource requests/limits (operational best practice) | Enforce |
| `require-probes` | — | Liveness/readiness probes (operational best practice) | Enforce |
| `restrict-registries` | — | Allow only approved image registries | Enforce |
| `require-signed-images` | 6.10.5 | Ensure images are signed before admission | Enforce |
| `require-namespace-labels` | — | Governance metadata on namespaces | Enforce |
| `baseline-networkpolicy` | 5.3.2 | Generate default-deny NetworkPolicy for newly created application namespaces (with documented exclusions) | Enforce |
| `require-readonly-rootfs` | 5.2.5 | Minimize admission of containers without read-only root filesystem | Enforce |
| `require-seccomp` | 5.7.2 | Ensure Seccomp profile is set | Enforce |
| `drop-all-capabilities` | 5.2.8, 5.2.9 | Minimize capabilities; drop ALL, allow only NET_BIND_SERVICE | Enforce |

## Kyverno Policies → NIST 800-53

| Policy | NIST Control | Control Family | Description |
|--------|-------------|----------------|-------------|
| `disallow-privileged` | AC-6 | Access Control | Least privilege — no privileged containers |
| `require-non-root` | AC-6(1) | Access Control | Least privilege — non-root execution |
| `disallow-host-namespaces` | SC-39 | System & Communications | Process isolation — no host namespace sharing |
| `restrict-hostpath` | AC-6, SC-28 | Access Control | Prevent host filesystem access from containers |
| `require-signed-images` | SA-12, SI-7 | Supply Chain / Integrity | Software supply chain provenance |
| `restrict-registries` | CM-7, SA-12 | Config Management | Only approved software sources |
| `baseline-networkpolicy` | SC-7 | System & Communications | Boundary protection — generate default-deny networking for newly created application namespaces |
| `require-namespace-labels` | AU-2, CM-8 | Audit / Config | Asset inventory and governance metadata |
| `require-resources` | SC-6 | System & Communications | Resource availability — prevent noisy neighbor |
| `require-probes` | SI-4 | System Integrity | Monitoring — health checks for all workloads |
| `require-readonly-rootfs` | SI-7 | System Integrity | Immutable root filesystem — prevent runtime modification |
| `require-seccomp` | SC-39 | System & Communications | Syscall filtering — reduce kernel attack surface |
| `drop-all-capabilities` | AC-6 | Access Control | Least privilege — drop all Linux capabilities by default |

## Infrastructure Controls → NIST 800-53

| Control | NIST | Mechanism | Location |
|---------|------|-----------|----------|
| GitOps (no manual kubectl apply) | CM-3, CM-5 | Flux reconciliation from git | `cluster/gitops/` |
| Signed artifacts | SA-12, SI-7 | Cosign image signing | `supply-chain/cosign/` |
| SBOM generation | SA-12 | Syft generates component inventory | `supply-chain/sbom/` |
| Vulnerability scanning | RA-5 | Grype scan — release-blocking at High+ (`verify-release`; time-boxed exceptions in `.grype.yaml`), informational in CI | `bootstrap/verify.sh --release`, `.grype.yaml`, CI workflow |
| Pinned versions | CM-2 | All components version-pinned | `docs/versions.md`, `bootstrap/install.sh` |
| Upgrade via git | CM-3 | Version bumps are PRs with audit trail | `examples/customer-instance/` |
| Policy-as-code | CM-6 | Kyverno policies in git, versioned | `policies/` |
| Jurisdictional scanning | SA-9 | Detect external dependencies | `tools/jurisdiction-scan/` |

## Infrastructure Controls → SOC 2 (Trust Services Criteria)

| Control | SOC 2 Criteria | Mechanism |
|---------|---------------|-----------|
| GitOps reconciliation | CC6.1 (Logical access) | GitOps is the intended change path; direct kubectl access should be restricted via RBAC and operational policy |
| Kyverno policy enforcement | CC6.1, CC8.1 | Automated guardrails prevent non-compliant deployments |
| Image signing | CC7.1 (System operations) | Image signing enforced for the configured scope; operators extend to cover their own images |
| SBOM + vulnerability scan | CC7.1, CC7.2 | Component inventory and known vulnerability detection |
| Default deny networking | CC6.6 (Network controls) | Newly created application namespaces receive a generated default-deny policy; excluded system namespaces do not |
| Namespace governance labels | CC6.3 (Role-based access) | Ownership and environment metadata enforced |
| Audit trail via git | CC7.2, CC7.3 | Changes applied via GitOps are traceable in git; direct cluster changes are captured in Kubernetes audit logs |
| Pinned, reproducible bootstrap | CC8.1 (Change management) | Deterministic environment from version-controlled config |

## Sovereign Toolchain Audit Trail Checklist

Use this checklist to prove control-plane auditability across the full delivery path.

| System | Required Evidence | Example Command / Artifact |
|--------|-------------------|----------------------------|
| Git | PR review, merge commit, tag provenance | Git history, protected branch settings |
| CI | Workflow run logs, runner identity/location | CI run URL + retained logs |
| Registry | Push, pull, signature, and retention logs | Registry audit export for release tag |
| Signing | Key usage records and rotation history | KMS/HSM audit events or key access logs |
| Cluster | Flux reconciliation + Kubernetes audit trail | `flux get all`, cluster audit logs |
| Policy | Kyverno admission decisions | Kyverno policy reports / admission events |

## How to Use This Document

1. **During vendor onboarding**: Share this mapping to demonstrate baseline controls
2. **During audits**: Link each row to the specific policy file and CI evidence
3. **For gap analysis**: Items marked "—" in CIS/NIST columns are operational best practices not directly mapped to a framework control
4. **To extend**: Add rows as new policies or controls are introduced
5. **For business trust narrative**: Pair this with `docs/public-trust-statement.md` so public claims stay tied to release evidence artifacts and repo-verifiable controls
6. **For jurisdiction-specific obligations**: Track per-region legal mappings in `docs/jurisdiction-control-matrix.md`

## Infrastructure Controls — Hardening

| Control | Mechanism | Location |
|---------|-----------|----------|
| Secrets encryption at rest | k3s `secrets-encryption: true` | `cluster/k3s/config.yaml` |
| API server audit logging | Audit policy with per-resource log levels | `cluster/k3s/audit-policy.yaml` |
| Audit log retention | 30 days, 10 backups, 100MB max per file | `cluster/k3s/config.yaml` |
| Anonymous auth disabled | `anonymous-auth=false` | `cluster/k3s/config.yaml` |
| RBAC authorization | `authorization-mode=Node,RBAC` | `cluster/k3s/config.yaml` |
| Kernel protection | `protect-kernel-defaults=true` | `cluster/k3s/config.yaml` |
| Read-only kubelet port disabled | `read-only-port=0` | `cluster/k3s/config.yaml` |

## Limitations

- This mapping is illustrative. Formal certification requires additional controls beyond what Foundations provides
- Multi-node HA and runtime sandboxing (gVisor/Kata) are not yet addressed
- Network segmentation is enforced for newly created application namespaces via generated default-deny NetworkPolicy; excluded system namespaces and broader traffic-blocking verification remain documented limits
- SOC 2 mappings are indicative — actual SOC 2 compliance requires organizational controls beyond infrastructure
- Key rotation and management evidence is not yet automated
