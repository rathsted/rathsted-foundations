# Overview

Rathsted Foundations is a Kubernetes baseline for teams that need infrastructure they can control, explain, and defend. It is intentionally narrow: a stable, single-node starting point with GitOps, policy enforcement, signed artifacts, and SBOM generation in a stack small enough to understand.

That “single-node” qualifier is a real boundary, not an omission hidden in the
footnotes. If Foundations grows into a supported multi-node substrate, that
should be an explicit next-stage product step owned here first.

In this context, sovereignty does not mean marketing language or automatic compliance. It means knowing where the important control points live, who controls them, and which surrounding choices still need explicit business approval. Foundations helps you stand up that baseline faster, but it does not make a cloud or hosting model sovereign on its own.

## What This Means In Practice

- The cluster runs in infrastructure you or your customer control
- Change control is visible through Git and GitOps reconciliation
- Release evidence is clearer because images, policies, and verification steps are documented
- The repo makes its own boundaries explicit instead of pretending to be a full platform

## What Foundations Gives You

- A hardened single-node Kubernetes baseline (`k3s`)
- GitOps so cluster state is declared and reviewable
- Signed artifacts and SBOMs as part of the release story
- Guardrails that prevent unsafe manifests from being applied
- A practical Kyverno policy set with tests

## What May Come Next

The next likely substrate expansion is:

- a small supported multi-node cluster shape

But that should preserve the same narrow product posture:

- explicit assumptions
- explicit verify output
- no automatic claim of HA/failover

## Example Situations

- You deploy into customer-owned or regulator-sensitive environments
- You need a baseline you can explain to security, procurement, or customers
- You need to know where your cluster, registry, keys, and evidence live before that becomes a contractual problem
- You need a narrow baseline now, not months of platform work before you can ship responsibly

## Why Flux + Kyverno

Flux keeps the stack controller-first and UI-optional, which makes it easier to bootstrap and to run in tighter environments. Kyverno keeps policies in plain YAML and provides image signature verification without requiring Rego. Alternatives are discussed as trade-offs in `docs/decisions.md`.

## What It Does Not Do

See the [README](../README.md#scope-boundaries) section for the full list. In short: no multi-node HA, no enforced secrets lifecycle, and no claim that the baseline by itself confers compliance or legal approval.

The current design note for that next step is:

- [Multi-Node Design](multi-node-design.md)

## Related Docs

- [Quickstart](quickstart.md)
- [Architecture](architecture.md)
- [Jurisdiction Control Matrix](jurisdiction-control-matrix.md)
- [Versions](versions.md)
