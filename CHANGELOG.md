# Changelog

All notable changes to Rathsted Foundations will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/).

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
