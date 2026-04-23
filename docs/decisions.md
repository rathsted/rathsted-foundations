# Decisions

This document explains why Foundations uses the current narrow stack and operating model. The point is not to claim these are the only valid tools. The point is to show that the baseline choices are deliberate and fit the product boundaries.

## GitOps: Flux (default)

**Why Flux fits the baseline**
- Controller‑first: no UI dependency, fewer moving parts, smaller surface area.
- Bootstrap ergonomics: built for “clean cluster → GitOps in one flow.”
- Kustomize‑first: maps directly to repo structure.
- Offline‑friendly: no persistent UI or external services required.

**When Argo would be better**
- You need a rich UI for many app teams.
- You want ApplicationSets or fleet management UX.
- You prioritize multi‑cluster ops as the primary persona.

**Direction**
- Current: Flux as the default.
- Future consideration: optional Argo overlay, same workloads and policies.

## Policy: Kyverno (default)

**Why Kyverno fits the baseline**
- Kubernetes‑native YAML policies (no Rego learning curve).
- Policies are easy to review in PRs.
- Generate/Mutate are practical for baseline guardrails.
- Strong coverage for common baseline controls.
- Lower cognitive overhead for teams not already deep into OPA/Rego.

**When Gatekeeper (OPA) would be better**
- You need Rego expressiveness for complex logic.
- Your users already run OPA in production and want parity.
- You require cross‑object checks or custom data sources.

**Direction**
- Current: Kyverno as the default.
- Future consideration: optional Gatekeeper profile with equivalent policies.

## Included Kyverno policy set
- Require non‑root, drop capabilities
- Disallow privileged, hostNetwork, hostPID/IPC
- Restrict or deny hostPath volumes
- Require resource requests/limits
- Require liveness/readiness probes
- Restrict image registries to allowlist (configured registry prefix / localhost)
- Require image signatures (as feasible)
- Enforce namespace labeling (owner, environment, jurisdiction)
- Baseline NetworkPolicy (default deny + allow DNS) for demo namespaces

## Why The Baseline Is Not "Maximum Hardening" By Default

The goal of Foundations is not to enable every possible restriction from day one.
The goal is to ship a baseline that is:

- strong enough to matter
- explainable to buyers and operators
- operable across real workloads
- narrow enough that teams do not immediately start turning rules off

Some stricter controls make sense only after a team understands its workload shapes,
networking model, and operational constraints. Those controls are usually better
treated as optional packs first, then promoted into the baseline only if repeated
real-world use shows they belong there.

## Related Docs

- [Stack](stack.md)
- [Architecture](architecture.md)
- [Policies](policies.md)
- [Policy Authoring and Verification](policy-authoring.md)
