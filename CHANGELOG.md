# Changelog

All notable changes to Rathsted Foundations will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
