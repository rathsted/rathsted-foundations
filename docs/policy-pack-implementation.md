# Policy Pack Implementation Sketch

This document turns the policy-pack UX proposal into a concrete first implementation
shape for Rathsted.

Status:
- implementation sketch
- not yet wired into the repo

## Goal

Make the first version simple enough to ship without a large refactor:
- clear pack layout
- one config file for enabled packs
- generated active bundle
- a few Make targets or wrapper commands

Principle:
- multiple management interfaces are allowed
- Git/YAML, CLI, and local UI should all operate on the same underlying config and generated bundle

## First Implementation Scope

V1 should support:
- list packs
- show enabled packs
- enable a pack
- disable a pack
- render the active bundle
- validate the chosen set

It does not need to:
- auto-resolve complex pack conflicts
- provide a UI
- support every possible policy dependency case

## Proposed Repo Layout

```text
policies/
  core/
    kustomization.yaml
    require-non-root.yaml
    disallow-privileged.yaml
    disallow-host-namespaces.yaml
    restrict-hostpath.yaml
    require-resources.yaml
    require-probes.yaml
    restrict-registries.yaml
    require-signed-images.yaml
    require-namespace-labels.yaml
    baseline-networkpolicy.yaml
  hardened/
    kustomization.yaml
    require-read-only-rootfs.yaml
    restrict-service-types.yaml
    restrict-host-ports.yaml
  packs/
    runtime/
      kustomization.yaml
      no-latest-tags.yaml
    network/
      kustomization.yaml
      require-networkpolicy.yaml
      restrict-egress.yaml
    ingress/
      kustomization.yaml
      require-approved-ingress.yaml
    regulated/
      kustomization.yaml
      require-extra-metadata.yaml
  generated/
    active/
      kustomization.yaml
  templates/
    policy-template.yaml
```

## Config File

Use one config file to store operator intent.

Suggested path:
- `config/policy-packs.yaml`

Suggested content:

```yaml
base: core
enabled:
  - hardened
disabled: []
```

Rules:
- `base` must always be present
- `enabled` contains optional additional packs
- `disabled` is mainly useful later if a higher-level profile implies packs by default

For V1, `base=core` is enough.

## Generated Active Bundle

Do not apply individual packs directly during normal operations.

Instead:
- read the config file
- generate `policies/generated/active/kustomization.yaml`
- install/apply/verify from that generated bundle

That file should simply reference the selected packs.

Example generated file:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../core
  - ../../hardened
  - ../../packs/network
```

## Suggested Commands

These can start as Make targets and later become a proper `rathsted` wrapper CLI.

### List packs

```bash
make policy-list
```

Behavior:
- reads pack directories
- prints pack name, short description, and whether enabled

### Show active set

```bash
make policy-status
```

Behavior:
- prints base profile
- prints enabled packs
- prints generated active bundle path

### Enable a pack

```bash
make policy-enable PACK=hardened
```

Behavior:
- updates `config/policy-packs.yaml`
- regenerates `policies/generated/active/kustomization.yaml`
- prints what changed

### Disable a pack

```bash
make policy-disable PACK=hardened
```

Behavior:
- updates config
- regenerates active bundle
- prints what changed

### Validate the chosen set

```bash
make policy-validate
```

Behavior:
- renders the generated bundle
- runs `make policy-test`
- optionally runs `make verify`

### Apply the active set

```bash
make policy-apply
```

Behavior:
- `kubectl apply -k policies/generated/active`

This should probably stay a separate action from `enable`/`disable` in V1.

## Minimum Makefile Additions

Suggested targets:
- `policy-list`
- `policy-status`
- `policy-enable`
- `policy-disable`
- `policy-render`
- `policy-validate`
- `policy-apply`

That is enough to prove the model before building a richer CLI.

## Pack Metadata

Each pack should eventually have a small metadata file, for example:

```yaml
name: hardened
description: stricter runtime restrictions for teams that want a tighter default posture
level: hardened
recommended: false
warnings:
  - may block workloads that expect writable root filesystems
```

This would power `policy-list` and warning output.

## Transition Plan

You do not need to refactor everything at once.

Reasonable order:

1. Add config file and generated active bundle concept
2. Move current baseline into `policies/core/`
3. Keep `policies/kustomization.yaml` temporarily pointing at `generated/active` or `core`
4. Add one first optional pack, such as `hardened`
5. Add wrapper targets for enable/disable/render/validate

## Why This Is The Right First Step

- low conceptual overhead
- easy to explain to operators
- compatible with current Kyverno/Kustomize flow
- keeps policy changes reviewable in Git
- moves Rathsted toward a product-like operator experience

## Related Docs

- [Policy Pack UX Proposal](policy-pack-ux.md)
- [Local Policy UI Proposal](policy-ui.md)
- [Policy Authoring and Verification](policy-authoring.md)
- [Policies](policies.md)
