# Changelog

All notable changes to Rathsted Foundations will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [2.0.0] — 2026-10-06

### Changed (BREAKING)
- Namespaces must declare `rathsted.io/jurisdiction` set to `ca`, `us` or `fr`; a
  missing or other value is rejected at admission. The bare `jurisdiction` label,
  which 1.x required with any value, no longer counts. Existing namespaces labelled
  the 1.x way are rejected on their next create or update until relabelled.
- `rathsted.io/operator-control` is stamped on namespaces at admission (system
  namespaces excluded). Do not set it yourself; the platform overwrites it.
- The Foundations contract reports `foundations_series: "2.x"`. Tooling that checks
  for `1.x` must accept `2.x`.
- 1.x is no longer supported; see `SECURITY.md`.

### Migration
- Relabel every namespace before upgrading:
  `jurisdiction: <v>` → `rathsted.io/jurisdiction: <ca|us|fr>`. See
  `docs/upgrade-guide.md`.

### Changed
- Component versions: k3s v1.35.9+k3s1, Kyverno v1.19.1, Flux 2.9.6, Cosign v3.1.3, Syft v1.54.0, Grype v0.120.0.

### Fixed
- 1.x installed Kyverno v1.12.3 from a vendored manifest while documenting v1.17.1 (including v1.0.3). 2.0.0 vendors and installs v1.19.1, uses the vendored manifest only when it matches the pin, and verify records the Kyverno images actually running.
- `install.sh` no longer reports success when the baseline policies fail to apply.
  A failed apply (for example while Kyverno is still starting) is retried, the
  install checks every policy is actually in the cluster, and it stops with an error
  if they are not.
- `verify.sh` fails, and names what is missing, when any baseline policy is absent.
  It previously reported "Kyverno policies present" on a cluster with none.
- Baseline policies match `Pod` only and rely on Kyverno autogen; applying a compliant
  Deployment with `kubectl` no longer fails at `/spec/containers/`.
- `require-probes` exempts run-to-completion workloads (Jobs, CronJobs, their pods),
  keyed on `restartPolicy`. Long-running enforcement is unchanged.
- Flux `GitRepository` pinned to the release tag, not `main`.
- Kyverno policies reconciled by Flux; drift self-heals.
- Contract marker reports the real single-node topology.
- Registry allowlist scoped to the signed prefix; digest mutation on; CI asserts the
  enforced key equals the published `cosign.pub`.
- Grype scan is a release gate.

## [1.0.3] — 2026-06-10

### Changed
- Internal improvements only

## [1.0.2] — 2026-05-04

### Changed
- Internal improvements for CI

## [1.0.1] — 2026-05-03

### Changed
- Close absent-field and empty-drop gaps.
- Scope foundations multi-node substrate.

### Fixed
- Align app-runtime postgres uid with alpine image.
- Match Pod only and let Kyverno autogen handle controllers.

## [Unreleased]

### Fixed

- Baseline policies (`require-non-root`, `require-probes`, `require-resources`, `restrict-registries`) now match `Pod` only and rely on Kyverno's autogen to derive controller-shaped rules. Previously these policies listed Deployment/StatefulSet/etc. directly while keeping a Pod-shape pattern, which caused admission to fail at `/spec/containers/` when applying compliant Deployments directly via kubectl.

## [1.0.0] — 2026-04-21

### Added

- First stable public release: single-node k3s baseline with Flux GitOps, Kyverno policies, Cosign signing, and Syft SBOM workflows.
- Supported hosts: Ubuntu 22.04, Ubuntu 24.04, Ubuntu 24.04 CIS, Debian 12, Rocky Linux 9, RHEL 9, and AlmaLinux 9 — compatibility evidence published.
- Customer instance template under `examples/customer-instance/`.
- `SECURITY.md` for coordinated vulnerability disclosure.
- Fresh public repository history rooted at this release (no inherited private commit graph).

### Changed

- Example GitOps workload and policy test fixtures reference a public `nginx` image; operators point `make configure` at their own registry and sign the images they run.
- Public snapshot published from the curated release commit; scope boundaries and non-goals documented in the public README.

### Notes

- `v1.0.0` is intentionally narrow: stable single-node baseline, not multi-node HA, not a certification product.
