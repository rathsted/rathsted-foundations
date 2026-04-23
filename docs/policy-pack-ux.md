# Policy Pack UX Proposal

This document describes the desired operator experience for enabling and disabling
policy bundles in Rathsted. The goal is an experience closer to `a2enmod` /
`a2dismod` than to manual YAML editing.

Status:
- proposed product and repo UX
- not fully implemented today

## Goal

Make policy selection feel like:

```bash
rathsted policy list
rathsted policy enable hardened
rathsted policy disable network-egress
rathsted policy status
```

Instead of:
- manually editing `kustomization.yaml`
- remembering which YAML files belong together
- guessing which policies are safe to remove

## User Model

Operators should be able to think in packs, not single policy files.

Examples:
- `core`
- `hardened`
- `runtime`
- `network`
- `ingress`
- `regulated`

Each pack should answer:
- what it enables
- why it exists
- what it may break
- whether it is recommended by default

## Proposed Commands

### List available packs

```bash
rathsted policy list
```

Expected output:
- available packs
- short description
- whether the pack is currently enabled
- whether the pack is part of `core`, `hardened`, or optional

### Show enabled packs

```bash
rathsted policy status
```

Expected output:
- enabled packs
- rendered bundle location
- whether cluster state matches the desired set

### Enable a pack

```bash
rathsted policy enable hardened
```

Expected behavior:
- adds the pack to the desired policy set
- re-renders the effective bundle
- optionally applies it
- tells the user which new policies were added
- warns if the pack is likely to tighten admission behavior

### Disable a pack

```bash
rathsted policy disable runtime
```

Expected behavior:
- removes the pack from the desired policy set
- re-renders the effective bundle
- optionally applies it
- tells the user which policies were removed
- warns if this weakens the baseline materially

### Preview changes

```bash
rathsted policy diff hardened
```

Expected behavior:
- shows which policies would be added or removed
- does not mutate cluster or config

### Validate chosen set

```bash
rathsted policy validate
```

Expected behavior:
- checks that the selected packs render cleanly
- runs policy tests
- warns about known pack conflicts if any

## Proposed Repo Model

The UX should sit on top of a pack-based repo structure like:

```text
policies/
  core/
    kustomization.yaml
    ...
  hardened/
    kustomization.yaml
    ...
  packs/
    runtime/
      kustomization.yaml
      ...
    network/
      kustomization.yaml
      ...
    ingress/
      kustomization.yaml
      ...
    regulated/
      kustomization.yaml
      ...
  generated/
    active/
      kustomization.yaml
```

Meaning:
- `core/` = always-on starting point
- `hardened/` = stricter bundle that can be enabled at start
- `packs/` = optional concern-area bundles
- `generated/active/` = rendered effective bundle for install/apply/verify

## Suggested Config Model

Store operator intent in a simple config file, for example:

```yaml
policyProfile:
  base: core
  enabled:
    - hardened
    - runtime
  disabled: []
```

Or:

```env
RATHSTED_POLICY_BASE=core
RATHSTED_POLICY_ENABLE=hardened,runtime
RATHSTED_POLICY_DISABLE=
```

The CLI should modify this config rather than editing multiple YAML files directly.

## What The Wrapper Should Actually Do

Under the hood, `rathsted policy enable ...` should:

1. update the chosen policy config
2. render `policies/generated/active/kustomization.yaml`
3. optionally run:

```bash
make policy-test
make verify
```

4. optionally apply the new active bundle

This keeps Kyverno and Kustomize as the underlying mechanism while giving the user a
clean operator workflow.

## Why This Is Better Than Raw YAML Editing

- easier to explain
- easier to document
- easier to support
- less likely to produce accidental drift
- easier to expose in future UI or installer flows

## Warnings The UX Should Surface

The CLI should warn when:
- disabling a pack weakens an important baseline guarantee
- enabling a pack is likely to block common workloads
- a pack requires extra workload preparation
- a pack is only recommended for stricter environments

## Minimum Viable Version

The first version does not need to be fancy.

Enough for V1:
- `list`
- `status`
- `enable`
- `disable`
- `validate`

That alone would make the policy model feel much more like a product and much less
like a collection of YAML files.

## Related Docs

- [Policies](policies.md)
- [Policy Authoring and Verification](policy-authoring.md)
- [Policy Addition Checklist](policy-checklist.md)
- [Policy Pack Implementation Sketch](policy-pack-implementation.md)
