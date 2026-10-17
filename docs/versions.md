# Pinned Versions

These are the versions installed by `bootstrap/install.sh` and should be reflected in release notes and offline bundles.

| Component | Version | Notes |
| --- | --- | --- |
| k3s | v1.35.9+k3s1 | Installer script downloaded from the k3s release tag on GitHub and verified against a sha256 pinned in `install.sh` (`RATHSTED_K3S_INSTALLER_SHA256`). The installer then verifies the k3s binary against the official release sha256 file. |
| Flux | 2.9.6 | Release archive downloaded over HTTPS and verified against the checksums file published in the same GitHub release. |
| Kyverno | v1.19.1 | Install manifest vendored in `cluster/policies/kyverno-install.yaml`; bootstrap uses the vendored file when it matches the pin, otherwise downloads the release. The vendored file is the upstream v1.19.1 `install.yaml` (sha256 `d3322cb3…24b88e6`) with two changes from upstream: (1) its five images pull from `ghcr.io/kyverno/` instead of `reg.kyverno.io/kyverno/` (the same images, without the download-analytics proxy in the pull path); (2) all three controllers run with `--enablePolicyException=true --exceptionNamespace=kyverno` instead of upstream's `--enablePolicyException=false`. |
| Cosign | v3.1.3 | Release binary downloaded over HTTPS and verified against the checksums file published in the same GitHub release. Backward-compatible with v2 key-based signing. |
| Syft | v1.54.0 | Release archive downloaded over HTTPS and verified against the checksums file published in the same GitHub release; if that fetch fails, bootstrap exits with an error. Update the pin in docs/versions.md if the version has been removed upstream. |
| Grype | v0.120.0 | Release archive downloaded over HTTPS and verified against the checksums file published in the same GitHub release; if that fetch fails, bootstrap exits with an error. Update the pin in docs/versions.md if the version has been removed upstream. |

If you update any version, update this document and re‑run `bootstrap/install.sh` in a clean environment.

## Supported Platforms

Tested via `make compat-test` (OrbStack E2E matrix; maintainer CI only). Each run produces evidence logs in `artifacts/`.

| OS | Image | Status | Last Validated |
| --- | --- | --- | --- |
| Ubuntu 22.04 LTS | `ubuntu:22.04` | Primary supported | 2026-10-09 |
| Ubuntu 24.04 LTS | `ubuntu:24.04` | Primary supported | 2026-10-09 |
| Ubuntu 24.04 CIS L1 | `ubuntu:24.04-cis` | Validated hardened path | 2026-10-09 |
| Debian 12 | `debian:12` | Validated compatibility path | 2026-10-09 |
| Rocky Linux 9 | `rocky:9` | Validated compatibility path | 2026-10-09 |
| RHEL 9 | — | Compatible (same family as Rocky 9) | — |
| AlmaLinux 9 | — | Compatible (same family as Rocky 9) | — |

**Requirements:** x86_64 or arm64, systemd, root/sudo access, 2 CPU minimum (4 CPU recommended), 4 GB RAM minimum (8 GB recommended), 20 GB disk.

**Architectures:** Ubuntu 22.04, Ubuntu 24.04, Ubuntu 24.04 CIS, Debian 12 and Rocky Linux 9 pass the same install-and-verify run on both arm64 (aarch64) and x86_64 (RHEL 9 and AlmaLinux 9 are compatible by family, not separately validated). The x86_64 runs cover the current pins and use each distribution's official cloud image in a Hyper-V virtual machine with Secure Boot on. The kernel must support seccomp; every workload runs with the `RuntimeDefault` profile.

**Not supported:** Fedora, CentOS Stream, Alpine, Arch.

## Related Docs

- [Quickstart](quickstart.md)
- [Upgrade Guide](upgrade-guide.md)
- [Architecture](architecture.md)
