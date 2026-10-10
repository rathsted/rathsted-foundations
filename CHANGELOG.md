# Changelog

All notable changes to Rathsted Foundations will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [2.0.1] — 2026-10-10

### Security
- `install.sh` now verifies what it downloads. **No earlier public release
  (v1.0.0–v2.0.0) did**, although the README and quickstart said the k3s installer
  checksum was pinned. A regression before v1.0.0 removed the checks; they are
  restored:
  - the k3s installer script is fetched from the k3s release tag and verified
    against a sha256 pinned in `install.sh` before it runs (no `curl | sh`);
  - Flux, Cosign, Syft and Grype are downloaded as release archives/binaries and
    verified against the checksums file in the same GitHub release (Syft and Grype
    were previously installed by scripts from their `main` branch);
  - every download uses `--fail --proto '=https' --tlsv1.2`;
  - GitHub SSH host keys are pinned instead of fetched with `ssh-keyscan`.
  See `docs/known-risks.md` for what this does and does not prove.
- `require-non-root` rejects containers that override the pod's setting with
  `runAsNonRoot: false` or `runAsUser: 0` (containers, initContainers and
  ephemeralContainers). Previously a container could run as root.
- The k3s audit policy logs Secrets at `Metadata` level. It previously logged
  Secret request bodies, so Secret data (including the Git credentials bootstrap
  stores) was written to the audit log.
- `install-managed.sh` always applies the full baseline. When `config/rendered/`
  existed it applied only the two rendered policies and skipped the other eleven.
- Git credentials are written to private temporary files for `kubectl`, not passed
  as command-line arguments.

### Changed
- PolicyExceptions are enabled, restricted to the `kyverno` namespace
  (`--exceptionNamespace=kyverno`): only exceptions there take effect, so a tenant
  cannot exempt itself. They were disabled before while the contract reported them
  as supported, so the app-runtime profile's exception was ignored; it now lives in
  `kyverno`. See `docs/policy-exceptions.md`.
- `install.sh` and `install-managed.sh` refuse to run over a cluster whose installed
  k3s or Kyverno version differs from the pins. In-place upgrades are not supported
  in 2.0.x; reinstall on a clean host (`docs/upgrade-guide.md`). Previously
  re-running bootstrap silently skipped installed components, so a 1.x cluster kept
  Kyverno v1.12.3.

### Fixed
- **Install works on stock hosts.** `cluster/k3s/config.yaml` enables
  `protect-kernel-defaults`, so the kubelet refuses to start unless six kernel
  parameters are already set; install never set them, so on a stock Ubuntu,
  Debian or Rocky host k3s came up without a node and install failed. Earlier
  releases have the same defect; our compatibility VMs shipped those values
  pre-set, which hid it. Install now writes and applies
  `/etc/sysctl.d/90-kubelet.conf` before starting k3s (values in
  `docs/quickstart.md`; note `kernel.panic=10` reboots the host 10 seconds after
  a kernel panic), and the compatibility tests reset VMs to stock kernel values
  first.
- Install waits for the Kubernetes API and a Ready node before installing Flux.
  On fast hosts `flux install` previously ran before the API was ready and failed.
- `make configure` and `make validate-config` work: their scripts now ship.
- `install.sh` applies the registry/signature policies `make configure` renders.
  They currently last until Flux's next reconcile, which restores the defaults from
  git; see the quickstart note. A tracked-overlay workflow is planned.
- Docs describe the 2.0 namespace labels (`rathsted.io/jurisdiction`), not the 1.x
  `jurisdiction` label.
- `docs/security-testing.md` no longer presents maintainer-only CI scripts as part
  of this repository.
- `cluster/sovereignty/rathsted-sovereignty.yaml` says what it is: Rathsted's own
  reference values, not installed by default.
- `install-managed.sh` GitOps bootstrap no longer fails rendering the GitRepository
  template.
- `verify.sh --release` runs the positive admission tests (it skipped them).
- Two policy test assertions named rules that do not exist and passed without
  testing anything; they now test the real rules. A new test covers the root
  override.
- The public nightly workflow renders a valid GitRepository (`REPLACE_GIT_REF`).
- Four docs had not been updated in this repository since v1.0.0 and are current
  again: `docs/offline.md`, `docs/policy-exceptions.md`, `docs/profiles.md` and
  `docs/sovereign-toolchain-inventory.md`. The 2.0.0 copy of
  `docs/policy-exceptions.md` predates PolicyExceptions being enabled.
- Docs: links to unpublished docs fixed, maintainer-only `make` targets marked as
  such, NetworkPolicy scope (default-deny in every new application namespace),
  encryption at rest (enabled), hardware requirements, and current-version
  references.

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
