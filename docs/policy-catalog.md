# Policy Catalog

This page explains each current Rathsted baseline policy in plain language:
- what it is
- what it enforces
- when it is useful
- when it may be too strict or not the right default

The goal is to make the policy set understandable to operators, reviewers, and buyers
without requiring them to read Kyverno YAML first.

## How To Read This Page

- "Good when" means situations where the policy is broadly helpful.
- "Not always right when" means situations where the policy may need tuning,
  exceptions, or a different packaging decision.

## Require Non-Root

Policy:
- `require-non-root`

What it enforces:
- workloads must run as non-root
- containers must not allow privilege escalation
- containers must drop all Linux capabilities

Good when:
- you want a strong default runtime posture
- you want to reduce the blast radius of compromised workloads
- you want a broadly defensible secure baseline

Not always right when:
- a legacy container image assumes root
- a third-party workload has not been prepared for non-root execution
- a specific workload genuinely requires additional capabilities and needs a documented exception

## Disallow Privileged

Policy:
- `disallow-privileged`

What it enforces:
- privileged containers are blocked

Good when:
- you want to prevent workloads from taking near-host-level privileges
- you want a baseline that blocks one of the clearest risky runtime settings

Not always right when:
- a specialized infrastructure workload really needs privileged access
- the team is trying to run low-level system software that does not belong in a normal app namespace

## Disallow Host Namespaces

Policy:
- `disallow-host-namespaces`

What it enforces:
- `hostNetwork`, `hostPID`, and `hostIPC` are blocked

Good when:
- you want workload isolation from the host
- you want to avoid app teams bypassing normal cluster network and process boundaries

Not always right when:
- a workload has a legitimate infrastructure reason to use host networking
- the software is closer to node-level operations than normal application runtime

## Restrict HostPath

Policy:
- `restrict-hostpath`

What it enforces:
- `hostPath` volumes are blocked

Good when:
- you want to stop workloads from mounting arbitrary parts of the host filesystem
- you want storage access to flow through more controlled patterns

Not always right when:
- a local or node-coupled workload really does need host-mounted data
- a specialized operational agent has a documented host access requirement

## Require Resources

Policy:
- `require-resources`

What it enforces:
- each container must declare CPU and memory requests and limits

Good when:
- you want predictable scheduling
- you want to reduce noisy-neighbor behavior
- you want a baseline that forces teams to think about workload sizing

Not always right when:
- a team is still experimenting and has not sized a workload yet
- the initial values are unknown and the team needs a temporary exception while profiling

## Require Probes

Policy:
- `require-probes`

What it enforces:
- containers must have liveness and readiness probes

Good when:
- you want healthier rolling updates and clearer workload status
- you want the platform to distinguish between "process started" and "service ready"

Not always right when:
- a simple batch or one-shot workload does not fit the same probe model
- a third-party application is not yet ready for meaningful readiness or liveness checks

## Restrict Registries

Policy:
- `restrict-registries`

What it enforces:
- images must come from the approved registry patterns in the policy

Good when:
- you want tighter control over software sources
- you want a clearer supply-chain story
- you want to stop ad hoc pulls from random public registries

Not always right when:
- a team needs to introduce a new approved registry and the policy has not been updated yet
- the organization has a more complex multi-registry model than the baseline currently assumes

## Require Signed Images

Policy:
- `require-signed-images`

What it enforces:
- images in the configured scope must satisfy signature verification

Good when:
- you want a strong release and provenance story
- you want to prove that approved images were signed before deployment
- you want release-grade trust claims to be technically backed

Not always right when:
- the organization has not yet adopted image signing
- third-party software is being introduced without a compatible signing path
- the team needs an earlier adoption phase where verification is introduced before strict enforcement

## Require Namespace Labels

Policy:
- `require-namespace-labels`

What it enforces:
- namespaces must include `owner`, `environment`, and `jurisdiction` labels

Good when:
- you want clearer ownership and operational context
- you want policy, reporting, and evidence to carry business-relevant metadata
- you want jurisdiction to be visible as part of the operating model

Not always right when:
- a team wants to create quick throwaway namespaces with no metadata discipline
- the organization needs more or different labels than the baseline currently requires

## Baseline NetworkPolicy

Policy:
- `baseline-networkpolicy`

What it enforces:
- when the `demo` namespace exists, a default-deny NetworkPolicy is generated there
- DNS egress is still allowed

Good when:
- you want the demo environment to start from a deny-by-default network posture
- you want a visible example of network isolation as part of the baseline

Not always right when:
- a workload needs broader network access and no explicit policy has been added yet
- the team expects the same generated behavior in every namespace, which the current baseline does not yet do

## What This Catalog Is For

This catalog helps answer:
- what each baseline rule does
- why it exists
- where exceptions or optional packs may make sense

It is not meant to replace:
- the actual policy YAML
- the policy tests
- environment-specific policy design

## Related Docs

- [Policies](policies.md)
- [Policy Authoring and Verification](policy-authoring.md)
- [Policy Addition Checklist](policy-checklist.md)
- [Policy Pack UX Proposal](policy-pack-ux.md)
