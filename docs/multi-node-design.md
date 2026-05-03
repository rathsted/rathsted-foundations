# Multi-Node Design

This note scopes the first multi-node design pass for `Rathsted Foundations`.

The goal is not to turn Foundations into a broad platform. The goal is to make
the substrate itself support a small multi-node cluster shape cleanly enough
that higher layers like Decks can depend on it.

## Why Foundations First

If multi-node is a real supported topology, the cluster baseline should own it
before Decks tries to inherit it.

That means Foundations should define:

- the supported cluster shape
- storage assumptions
- topology evidence
- verify expectations
- node-failure expectations

Decks can then build on that substrate instead of inventing its own topology
rules.

## Current Position

Today Foundations `v1.0.0` is intentionally narrow:

- single-node `k3s`
- GitOps
- Kyverno policy guardrails
- signed image verification
- SBOM generation

That boundary was the right first release boundary. Multi-node is the next
substrate expansion, not a correction to `v1.0.0`.

## First Supported Multi-Node Shape

The first target should be intentionally small:

- one cluster
- three nodes
- control-plane and worker capability on each node unless later separation is
  required
- one supported storage baseline
- the same GitOps/policy/supply-chain posture as single-node

This is enough to change scheduling and failure behavior meaningfully without
pretending to be a generic HA platform.

## What Multi-Node Means Here

Multi-node in this repo means:

- multiple Kubernetes nodes in one supported cluster
- workloads can schedule across more than one machine
- verify and evidence need to understand cluster shape
- node-failure behavior changes

It does not mean:

- a service provisioning UI
- a broad platform catalogue
- automatic failover guarantees
- multi-region orchestration

## First Design Questions

Before implementation starts, Foundations needs answers to:

- what exact three-node shape is supported first
- what operating systems and networking assumptions stay in-bounds
- what storage class or disk assumptions are required
- what survives a single node loss and what does not
- what verify output proves the cluster is in the supported topology
- what contract marker Decks should later read

## Storage Direction

The first multi-node expansion should not assume “storage solves itself.”

Foundations needs an explicit answer for:

- default storage class expectations
- persistent-volume behavior in the first supported shape
- what remains local-only versus topology-aware

If those assumptions are weak or environment-specific, the docs should say so
plainly.

## Policy Direction

The baseline policy story should stay the same:

- GitOps remains the system of record
- Kyverno remains the policy layer
- namespace and registry boundaries remain explicit

But verify and policy docs will need to acknowledge:

- more system pods
- more scheduling spread
- more node-level variation

## Verify And Evidence Direction

The first multi-node pass should extend the contract marker and verify flow to
include:

- topology mode
- supported node count floor
- current install mode
- whether Decks `v0` can consume the substrate

The verify path should also add:

- node-count validation
- cluster-shape validation
- clearer warnings when a cluster is smaller than the supported floor

## Explicit Non-Goals

The first multi-node pass does not yet promise:

- HA certification
- failover SLOs
- multi-region DR
- managed-database behavior
- new product breadth

## Sequence

1. lock the first supported multi-node shape in-doc
2. decide the storage and node assumptions
3. extend install and verify contract markers
4. add a repeatable multi-node smoke path
5. only then let Decks depend on the supported topology
