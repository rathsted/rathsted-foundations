# Stack

This document explains what each component in Foundations does and why it belongs in the baseline.

## Why This Stack Exists

The stack is designed to keep the baseline understandable while still making control, change, and evidence visible. That is why it stays narrow.

- Client control: everything runs on client-owned infrastructure and is driven by a Git repo they control.
- Governance first: policies, signatures, and SBOMs are enforced early in the lifecycle.
- Minimal surface area: a single-node baseline reduces dependency sprawl and hidden control planes.
- Deterministic change: GitOps is the source of truth; drift is treated as a failure.
- Auditability: every change is versioned, reviewed, and provable through signed artifacts and SBOMs.

## Components And Purpose

### k3s (Kubernetes Runtime)
Single-node Kubernetes with hardened defaults. This provides the minimal, auditable substrate without the operational overhead of a full multi-node platform.

### Flux (GitOps Controllers)
Flux reconciles the cluster state to what is declared in Git. This ensures reproducibility, reviewable change, and deterministic operations.

### Kyverno (Policy Enforcement)
Kyverno enforces security and governance policies in plain YAML. It blocks unsafe workloads and verifies image signatures without requiring Rego.

### Cosign (Image Signing)
Cosign signs container images. Kyverno verifies those signatures so only approved images can run.

### Syft (SBOM Generation)
Syft generates SBOMs for the workload images you configure (the examples use a small `nginx` image by default). This enables traceability and supply-chain audit requirements.

### Grype (Optional Vulnerability Scan)
Grype can scan SBOMs for vulnerabilities. It is optional but included for teams that need vulnerability reporting.

## Sovereign Toolchain Inventory

Use this as the minimum inventory during customer onboarding and compliance reviews.

| Layer | Default in this repo | Control owner | Sovereignty note |
|------|-----------------------|---------------|------------------|
| Source of truth | GitHub repository | Customer org or Rathsted (implementation phase) | Prefer customer-owned git hosting for strict sovereignty |
| Reconciliation | Flux in customer cluster | Customer | Runs inside client-owned infrastructure |
| Runtime | k3s in customer cluster | Customer | No external control plane required |
| Policy enforcement | Kyverno in customer cluster | Customer | Policies are versioned and auditable in git |
| CI execution | GitHub Actions (default examples) | Customer or vendor | For strict residency, use self-hosted runners in-jurisdiction |
| Artifact registry | Example: Docker Hub / your mirror (`make configure`) | Customer or vendor | Point `RATHSTED_REGISTRY` at an in-jurisdiction registry when required |
| Signing keys | Cosign key-pair | Customer security team | Keep private keys in customer-controlled KMS/HSM |
| SBOM evidence | Syft output in repo artifacts | Customer | Store artifacts in customer-controlled evidence store |
| Vulnerability evidence | Grype output (optional) | Customer | Treat as supplementary evidence, not sole gate |

## How The Pieces Work Together

1. Operators or CI push desired state into Git.
2. CI builds images, signs them with Cosign, and generates SBOMs with Syft (optionally scans with Grype).
3. Flux pulls the Git state into the cluster and applies manifests.
4. Kyverno enforces baseline policies and verifies Cosign signatures before workloads run.
5. Any drift or policy violations are visible and can be blocked at admission time.

This flow keeps governance and provenance in the same system of record (Git) and ensures the cluster never drifts from approved, auditable state.

## Related Docs

- [Architecture](architecture.md)
- [Decisions](decisions.md)
- [Policies](policies.md)
- [Jurisdiction Control Matrix](jurisdiction-control-matrix.md)
