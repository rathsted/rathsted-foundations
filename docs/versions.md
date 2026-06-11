# Pinned Versions

These are the versions installed by `bootstrap/install.sh` and should be reflected in release notes and offline bundles.

| Component | Version | Notes |
| --- | --- | --- |
| k3s | v1.35.1+k3s1 | Installed via the pinned `get.k3s.io` installer script with `INSTALL_K3S_VERSION`. |
| Flux | 2.8.1 | Installed via the upstream install script with `FLUX_VERSION` pinned. No local checksum verification of the installer script. |
| Kyverno | v1.17.1 | Install manifest pinned in `bootstrap/install.sh`. |
| Cosign | v3.0.5 | Binary download. Backward-compatible with v2 key-based signing. |
| Syft | v1.42.1 | Installed via the pinned upstream installer script; if that fetch fails, bootstrap exits with an error. Update the pin in docs/versions.md if the version has been removed upstream. |
| Grype | v0.109.0 | Installed via the pinned upstream installer script; if that fetch fails, bootstrap exits with an error. Update the pin in docs/versions.md if the version has been removed upstream. |

If you update any version, update this document and re‑run `bootstrap/install.sh` in a clean environment.

## Supported Platforms

Tested via `make compat-test` (OrbStack E2E matrix). Each run produces evidence logs in `artifacts/`.

| OS | Image | Status | Last Validated |
| --- | --- | --- | --- |
| Ubuntu 22.04 LTS | `ubuntu:22.04` | Primary supported | 2026-06-10 |
| Ubuntu 24.04 LTS | `ubuntu:24.04` | Primary supported | 2026-06-10 |
| Ubuntu 24.04 CIS L1 | `ubuntu:24.04-cis` | Validated hardened path | 2026-06-10 |
| Debian 12 | `debian:12` | Validated compatibility path | 2026-06-10 |
| Rocky Linux 9 | `rocky:9` | Validated compatibility path | 2026-06-10 |
| RHEL 9 | — | Compatible (same family as Rocky 9) | — |
| AlmaLinux 9 | — | Compatible (same family as Rocky 9) | — |

**Requirements:** x86_64, systemd, root/sudo access, 2+ CPU, 4 GB RAM minimum (8 GB recommended), 20 GB disk.

**Not supported:** Fedora, CentOS Stream, Alpine, Arch, ARM64 (not tested).

## Related Docs

- [Quickstart](quickstart.md)
- [Upgrade Guide](upgrade-guide.md)
- [Architecture](architecture.md)
