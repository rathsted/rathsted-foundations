# Policy Authoring and Verification

This document explains how to add or change a Rathsted policy and how that change
should show up in testing and compatibility evidence.

## Purpose

Adding a policy is not just a YAML change. A policy should be:
- added to the installed baseline
- tested in isolation
- represented in negative-test verification where appropriate
- documented in plain language

If one of those steps is missing, the policy is more likely to drift, surprise users,
or disappear from compatibility evidence.

## Current Flow

### 1. Add the policy manifest

Add the policy file under:

- `policies/`

Most current baseline policies are `ClusterPolicy` objects enforced by Kyverno.

Starter template:

- `policies/templates/policy-template.yaml`

### 2. Include it in the installed bundle

Add the policy to:

- `policies/kustomization.yaml`

If it is not listed there, it is not part of the installed baseline.

### 3. Add policy tests

Update:

- `tests/kyverno/kyverno-test.yaml`

This file should include:
- the new policy under `policies:`
- any new good or bad resources under `resources:`
- explicit expected pass/fail outcomes under `results:`

Run:

```bash
make policy-test
```

This is the fastest way to prove the rule logic behaves as intended.

### 4. Add a compat-visible negative test when appropriate

If the policy should show up in verification and compatibility evidence, add an
intentionally bad manifest to:

- `tests/bad-manifests/`

Why this matters:
- `bootstrap/verify.sh` loops over all files in `tests/bad-manifests/`
- each bad manifest should be rejected by policy
- those rejections appear in the `Negative Tests` section of `verify`
- `compat-test` wraps install + verify, so those same rejections show up in the
  compatibility output and evidence logs

If you add a policy but do not add a bad manifest for it, the policy may still work,
but it will not become visible in compat evidence by default.

### 5. Add a direct verify check for especially important policies

Some policies are important enough to check by name in `bootstrap/verify.sh`.

Current example:
- `require-signed-images` is explicitly checked as a named policy

Do this when:
- the policy is part of a release-grade trust claim
- the policy is central to the product story
- a missing policy should be called out clearly, not just inferred from a generic failure

### 6. Update the docs

At minimum, update:
- `docs/policies.md`

Update other docs when relevant:
- `docs/compliance-mapping.md`
- `docs/supply-chain.md`
- `docs/decisions.md`

The policy should be explainable in plain language, not only visible in YAML.

Use:

- `docs/policy-checklist.md`

before merging the change.

## Recommended Change Sequence

Typical workflow:

```bash
make configure
make policy-test
make verify
make compat-test
```

Interpretation:
- `configure` renders any policy templates that depend on configured registry/image inputs
- `policy-test` validates policy logic against known fixtures
- `verify` confirms policies exist in-cluster and reject intentionally bad manifests
- `compat-test` runs install + verify across supported distro variants and captures evidence

## When A Policy Change Should Affect Compat Output

A policy change should be visible in compat output when:
- the policy is part of the installed baseline
- the policy has a corresponding bad-manifest rejection in `tests/bad-manifests/`
- `kyverno test tests/kyverno -f kyverno-test.yaml` passes
- or the verify script checks the policy directly by name

Without one of those paths, the compat output may not show the new policy clearly.

## What To Keep In The Baseline

The core baseline should contain rules that are:
- broadly defensible
- easy to explain
- likely to matter in most serious deployments
- low-friction enough that teams will not immediately disable them

Examples:
- non-root execution
- no privileged workloads
- no hostPath
- required requests and limits
- required probes
- approved registries
- signed images where configured

## What To Make Optional

A policy usually belongs in an optional pack when it is:
- environment-specific
- hard to explain to most buyers
- likely to break common workloads without preparation
- more about a particular sector's posture than a general baseline

Examples:
- no `:latest` tags / immutable digest enforcement
- required read-only root filesystem
- host port restrictions
- NodePort / LoadBalancer restrictions
- stricter ingress and TLS patterns
- namespace-wide default NetworkPolicy requirements for all workloads
- tighter egress controls
- richer ownership metadata requirements

## Should The Baseline Be More Hardened By Default?

Usually not all at once.

A stronger baseline is not automatically a better baseline. If the default policy set
becomes too strict too early, it creates three problems:
- more friction during adoption
- more pressure to disable rules instead of understand them
- a harder product story to explain clearly

The better pattern is:
- keep the default baseline strong and explainable
- add optional packs for stricter environments
- promote an optional policy into the baseline only after repeated evidence that it is
  broadly needed and operationally workable

## Optional Policy Pack Ideas

Reasonable future packs:
- core baseline
- hardened baseline
- stricter runtime pack
- network isolation pack
- ingress and TLS pack
- regulated-environment pack
- application runtime pack

## Recommended Packaging Model

The best long-term model is not one giant policy set.

Instead:
- keep a `core` baseline that most serious teams can adopt without immediate exceptions
- offer a `hardened` profile for teams that want a stricter default posture
- add optional packs for workload, network, or sector-specific tightening

That gives teams a real choice at the start:
- broad baseline first
- or stricter baseline first

Then they can layer in more policy only when their workloads and operating model
justify it.

## Recommended Directory Model

Today the repo still has one `policies/` directory for the installed baseline.

The cleaner next-step layout is:

```text
policies/
  core/
  hardened/
  packs/
    runtime/
    network/
    ingress/
    regulated/
  templates/
```

Suggested meaning:
- `core/` = broad, explainable baseline policies
- `hardened/` = stricter starting bundle for teams that want tighter defaults
- `packs/` = narrower optional bundles by concern area
- `templates/` = authoring scaffolds and rendered policy templates

Current state:
- this layout is a recommended direction
- the repo has not been fully refactored into it yet
- new policy work should still be named and documented with that model in mind

For the desired operator-facing enable/disable workflow, see
[Policy Pack UX Proposal](policy-pack-ux.md).

## Related Docs

- [Policies](policies.md)
- [Policy Addition Checklist](policy-checklist.md)
- [Policy Pack UX Proposal](policy-pack-ux.md)
- [Decisions](decisions.md)
- [Compliance Mapping](compliance-mapping.md)
