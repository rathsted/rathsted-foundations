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

Foundations 2.x is intentionally narrow:

- single-node `k3s`
- GitOps
- Kyverno policy guardrails
- signed image verification
- SBOM generation

That boundary was the right first release boundary. Multi-node is the next
substrate expansion, not a correction to the 2.x baseline.

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

- topology mode (`topology_mode`)
- topology support level (`topology_support_level`)
- supported node count range (`supported_node_min`, `supported_node_max`)
- current install mode (`install_mode`)
- whether Decks `v0` can consume the substrate (`decks_v0_supported`)

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

## Current Bounded Topology: `managed-3-node-v1`

Steps 1 to 3 of the sequence above are done for one bounded shape; step 4
is still open, because Foundations does not ship its own multi-node smoke. The
contract is rendered by `bootstrap/lib/contract.sh`.

Selecting it:

```bash
FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1 ./bootstrap/install-managed.sh
./bootstrap/verify.sh --managed
```

| `topology_mode` | `topology_support_level` | nodes | install path |
| --- | --- | --- | --- |
| `single-node` (default) | `baseline` | `1-1` | `install.sh` or `install-managed.sh` |
| `managed-3-node-v1` | `bounded` | `3-3` | `install-managed.sh` only |

Rules:

- the topology mode selects every other topology field.
  `FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL`, `FOUNDATIONS_SUPPORTED_NODE_MIN`,
  `FOUNDATIONS_SUPPORTED_NODE_MAX` and
  `FOUNDATIONS_MULTI_NODE_FOUNDATIONS_SUPPORTED` may be set to state what the
  caller expects, but a value that does not match the mode is refused rather
  than published
- unknown topology modes are refused
- `install-managed.sh` checks the live node count in preflight, before Flux or
  Kyverno are installed, and refuses `managed-3-node-v1` unless the cluster
  has exactly 3 nodes
- `verify.sh` prints the live node count and support level. A cluster outside
  a multi-node contract's range fails verify. The single-node baseline only
  warns, as it did before
- the self-hosted `install.sh` path (single-host `k3s`) always publishes
  `single-node`

Tested shape: a kind cluster with 1 control-plane and 2 worker nodes,
Foundations installed with this contract, and an application platform
installed on top. Foundations does not ship its own cluster-creation smoke
for this topology yet.

Storage: Foundations itself stays stateless at the workload layer and does
not define a storage class. Whatever `ReadWriteOnce` default the cluster
provides is what higher layers get. No persistent-volume survivability across
node loss is claimed.

Out of scope for `bounded`:

- HA certification and failover SLOs
- stateful workload survivability across node loss
- node counts other than 3, or other cluster shapes
- the self-hosted single-host install path

