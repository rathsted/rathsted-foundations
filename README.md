# Rathsted Foundations

Rathsted Foundations is a Kubernetes baseline for teams that need infrastructure they can control, explain, and defend under customer, jurisdictional, or audit pressure. `v1.0.0` is a stable, single-node release with explicit boundaries: GitOps, policy enforcement, signed artifacts, and SBOM generation in a small, opinionated stack. It helps teams set up a controlled baseline, but the sovereignty of the overall environment still depends on where and how you host it.

## Who It Helps
- Teams deploying into customer-owned or regulator-sensitive environments
- Operators who need a baseline they can explain to security, procurement, or customers
- Small teams that need a supportable starting point instead of a vague platform bundle

## What It Means In Practice
- You keep operational control of the cluster and surrounding infrastructure choices
- The important control points are visible: git hosting, CI runners, artifact registry, signing keys, and evidence retention
- The repo is explicit about what the baseline does now versus what you still need to decide for your own environment

## What It Is
- Single‑node `k3s` baseline with hardened defaults
- Flux GitOps bootstrap
- Kyverno policy guardrails (including image signature verification)
- SBOM generation with Syft (optional vulnerability scan via Grype)
- A demo workload and an optional app‑runtime profile

## Product Promise For `1.x`
- Stable, tag-based single-node baseline
- Primary supported path on Ubuntu 22.04 and 24.04
- Validated compatibility paths for Debian 12, Rocky Linux 9, and Ubuntu 24.04 CIS
- Compatible family guidance for RHEL 9 and AlmaLinux 9 where noted
- Deterministic GitOps bootstrap and verification flow
- Policy and supply-chain controls that can be reviewed, tested, and evidenced (see [release signing](docs/release-signing.md) for the Rathsted reference image)

## Public Trust

`rathsted-foundations` is intended to be the public, reviewable source of truth for the published Foundations baseline. Public claims should be supportable from public files alone: manifests, policies, docs, tests, and verification scripts. See [Public Trust Statement](docs/public-trust-statement.md).

## What It Is Not
- A managed Kubernetes service
- A hyperscaler clone
- A serverless platform
- A multi-node HA platform
- A certification guarantee

## Quick Start
```bash
git clone https://github.com/rathsted/rathsted-foundations
cd rathsted-foundations
make doctor
make configure
./bootstrap/install.sh
./bootstrap/verify.sh
```

## Environment Split

Use two environments:

- Local workstation: clone the repo, run `make doctor`, `make configure`, and `make validate-config`
- Target Linux host: run `./bootstrap/install.sh` and `./bootstrap/verify.sh` on the machine that will host `k3s`

The k3s version is pinned in `install.sh`, and the upstream installer verifies the k3s binary for supply-chain integrity. Override with `RATHSTED_K3S_INSTALLER_SHA256` if the upstream installer changes.

The local workstation can be macOS, Linux, or Windows with WSL. The target host is a supported Linux machine.

## Local Workstation Requirements

- `bash`
- `curl`
- `git`
- `make`
- `python3`
- `pyyaml` for rendered-config validation: `pip install pyyaml`

Optional on the workstation:

- `docker` for local registry flows
- `cosign` and `syft` if you want to do signing/SBOM work locally

## Target Host Requirements

- Ubuntu 22.04 or 24.04 (primary)
- Debian 12, Rocky Linux 9, RHEL 9, AlmaLinux 9 (tested or compatible)
- 4 CPU / 8 GB RAM / 20 GB disk minimum
- outbound network access for initial bootstrap downloads
- open ports required by your deployment, including `6443` for the Kubernetes API

## Docs

| Document | What it covers |
|----------|---------------|
| [Quickstart](docs/quickstart.md) | The fastest path to evaluate Foundations, including workstation-vs-host split and OS guidance |
| [Overview](docs/overview.md) | What Foundations is, what sovereignty means here, and where the product boundaries are |
| [Architecture](docs/architecture.md) | System diagram and control-flow view of Git, Flux, cluster, policy, and registry |
| [Policies](docs/policies.md) | The baseline guardrails that are actually enforced, including signature and registry policy |
| [Policy Catalog](docs/policy-catalog.md) | Plain-language explanation of each shipped policy, including when it helps and when it may be too strict |
| [Policy Authoring](docs/policy-authoring.md) | How to add or change a policy so it is enforced, tested, and represented in verification evidence |
| [Policy Checklist](docs/policy-checklist.md) | The operational checklist for adding or changing a policy without skipping tests, docs, or verification |
| [Policy Exceptions](docs/policy-exceptions.md) | When to use Kyverno `PolicyException` and how to scope exceptions without weakening the whole baseline |
| [Compliance Mapping](docs/compliance-mapping.md) | How repo controls map to CIS, NIST 800-53, and SOC 2 in an illustrative way |
| [Versions](docs/versions.md) | Pinned component versions, platform status, and current support/compatibility matrix |
| [Upgrade Guide](docs/upgrade-guide.md) | How to move between tagged `1.x` releases, verify results, and roll back when needed |
| [Profiles](docs/profiles.md) | What the optional `profiles/app-runtime` bundle adds, and why it is off by default |
| [Offline Notes](docs/offline.md) | What must be pre-staged if you want an offline or local-only bootstrap path |
| [Backup Guide](docs/backup-guide.md) | What to back up on a single-node deployment and what recovery does and does not restore |
| [Monitoring Guide](docs/monitoring-guide.md) | Recommended observability add-ons and why monitoring is outside the narrow baseline |
| [Incident Response](docs/incident-response.md) | First-response guidance for suspected compromise, evidence preservation, reinstall, and rotation |
| [Known Risks](docs/known-risks.md) | Accepted risks, current mitigations, and the trust boundaries that still need operator judgment |
| [Jurisdiction Control Matrix](docs/jurisdiction-control-matrix.md) | The business and operating questions to ask about cluster location, CI, registry, keys, and evidence retention |
| [Sovereign Toolchain Inventory](docs/sovereign-toolchain-inventory.md) | The inventory fields to capture for Git, CI, registry, keys, evidence retention, and control-plane custody |
| [Operator Training Checklist](docs/operator-training-checklist.md) | The minimum operator knowledge expected before production rollout or audit-facing use |
| [Stack](docs/stack.md) | What each component contributes to the baseline and how the pieces fit together in practice |
| [Pipeline Sovereignty](docs/pipeline-sovereignty.md) | How CI runner location and custody affect the overall control story |
| [Registry Residency](docs/registry-residency-guide.md) | How to move from default example image flows to an approved in-jurisdiction registry model |
| [Supply Chain](docs/supply-chain.md) | How signing, SBOM generation, and release verification work in the baseline |
| [Release Signing](docs/release-signing.md) | The concrete steps for signing and verifying tagged release images |
| [Secret Lifecycle](docs/secret-lifecycle.md) | Which Foundations credentials exist, where they should live, and when they should be rotated or revoked |
| [Security Testing](docs/security-testing.md) | Which checks to run before release and which ones should live in CI, nightly, or pre-release flows |
| [Threat Model](docs/threat-model.md) | Which risks the baseline is meant to reduce, and which ones remain out of scope |
| [Decisions](docs/decisions.md) | Why the baseline uses Flux, Kyverno, and the current narrow operating model |
| [Public Trust Statement](docs/public-trust-statement.md) | What external reviewers should be able to verify from the public repo alone |
| [Compat Evidence](artifacts/) | Latest validation output per supported OS from `make compat-test`, refreshed every release |

## Proposed Docs

These documents are public because they explain the intended direction of policy-pack management, but they are not part of the shipped `v1.0.0` operator surface:

| Document | Why it exists |
|----------|---------------|
| [Policy Pack UX](docs/policy-pack-ux.md) | Proposal for a pack-oriented operator experience instead of manual YAML-only policy management |
| [Policy Pack Implementation](docs/policy-pack-implementation.md) | Sketch of how the first policy-pack implementation could be wired without a large refactor |
| [Policy UI](docs/policy-ui.md) | Proposal for a local-only UI that would sit on top of the same config and generated bundle model |

## Repo Layout

| Directory | Purpose |
|-----------|---------|
| `bootstrap/` | Install, verify, and uninstall scripts for the full stack |
| `cluster/` | k3s config, GitOps sync templates, vendored Kyverno manifest |
| `config/` | Environment config written by `make configure` |
| `docs/` | All documentation — architecture, policies, compliance, upgrade guide, etc. |
| `examples/` | GitOps pattern example (`hello-gitops-app`), customer instance template |
| `policies/` | Kyverno ClusterPolicies (all Enforce mode) |
| `profiles/` | Optional runtime profile (Traefik + NATS + Postgres + demo workloads) |
| `scripts/` | Configuration, validation, and doctor utilities |
| `supply-chain/` | Cosign keys, SBOM config, signing scripts |
| `tests/` | Kyverno policy tests and negative test fixtures |
| `tools/` | Jurisdiction scan CLI for sovereignty posture assessment |

## Scope Boundaries

What `v1.0.0` does not include:

- No multi-node HA or disaster recovery
- No secrets lifecycle or encryption at rest (recommend SOPS/age)
- No runtime sandboxing beyond baseline Kubernetes controls
- No full east-west network segmentation beyond shipped namespace baselines
- No zero-prestage offline bootstrap
- Compliance mappings are illustrative and do not replace formal assessment
- Release-grade verification requires registry reachability

## Config Model

`make configure` writes `config/customer.env`, renders registry/signature policies for your image namespace, and points the example deployment at your chosen image. The default demo uses `nginx:1.29.7-alpine` from Docker Hub as a placeholder — Foundations does not ship its own application image. Production use requires replacing this with your own image.

## Compliance Note

Foundations helps teams produce controls, evidence, and repeatable release practices. It does not by itself confer certification, legal approval, or regulatory compliance.

## Feedback

Found a bug or have a question? [Open an issue](https://github.com/rathsted/rathsted-foundations/issues/new/choose) — all submissions use structured templates.
