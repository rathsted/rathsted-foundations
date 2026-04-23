# Local Policy UI Proposal

This document describes a local web UI for managing Rathsted policy packs.

Purpose:
- give operators a visual way to manage policy packs
- keep CLI, Git/YAML, and UI aligned to one underlying model

Status:
- proposed local interface
- not implemented yet

## Principle

Rathsted should support multiple ways of managing policies:
- direct Git/YAML editing
- CLI commands
- local web UI

These are not different systems.

They should all operate on:
- one config file
- one generated active bundle
- one validation path

The UI must not become a second source of truth.

## Entry Point

Suggested command:

```bash
rathsted policy ui
```

Or as an initial Make target:

```bash
make policy-ui
```

Expected behavior:
- start a local web server
- open a browser to a local page
- read the current policy-pack config

## What The UI Should Show

### 1. Current Policy State

Show:
- active base profile
- enabled optional packs
- generated bundle path
- last validation status

### 2. Available Packs

For each pack, show:
- name
- short description
- category (`core`, `hardened`, optional pack)
- whether enabled
- warnings

### 3. Pack Details

When a pack is selected, show:
- what it enforces
- why someone would enable it
- what it may break
- which policies are inside it

### 4. Change Preview

Before apply, show:
- policies that would be added
- policies that would be removed
- warnings about stricter admission behavior
- warnings about weakened baseline guarantees

## Primary Actions

### Enable pack

User action:
- toggle or button to enable a pack

Under the hood:
- update config
- re-render generated active bundle
- optionally mark the configuration as needing validation

### Disable pack

User action:
- toggle or button to disable a pack

Under the hood:
- update config
- re-render generated active bundle
- warn if the pack removal weakens an important baseline guarantee

### Validate

User action:
- click `Validate`

Under the hood:
- render active bundle
- run policy validation flow
- show pass/fail and any warnings

### Apply

User action:
- click `Apply`

Under the hood:
- apply the generated active bundle
- optionally run verify afterward

## Suggested Screens

V1 can be a single-page local app with four areas:

1. Header
- current profile
- current cluster or local context
- validation status

2. Left column
- pack list with enabled/disabled state

3. Main detail panel
- selected pack description
- included policies
- warnings

4. Footer actions
- Validate
- Apply
- Show diff

## Safety Rules

The UI should:
- warn before disabling an important pack
- warn when enabling a stricter pack likely to reject current workloads
- separate `enable/disable` from `apply`
- keep validation and apply explicit

The UI should not:
- silently mutate cluster state
- bypass Git/config history
- hide which policies are being added or removed

## Why A Local UI Helps

- less YAML-oriented users can still manage packs safely
- pack selection becomes easier to explain
- the product feels more deliberate and accessible
- support becomes easier because the operator can see the current state visually

## Relationship To CLI And Git

Best model:
- Git/YAML for direct control
- CLI for scripted/operator workflows
- local UI for visual workflows

All three should read and write the same policy-pack config and generate the same
active bundle.

## Minimum Viable UI

Enough for a first version:
- read current config
- list packs
- enable/disable packs
- show change preview
- run validate

That is enough to prove the interface model before building a richer management UI.

## Related Docs

- [Policy Pack UX Proposal](policy-pack-ux.md)
- [Policy Pack Implementation Sketch](policy-pack-implementation.md)
- [Policies](policies.md)
