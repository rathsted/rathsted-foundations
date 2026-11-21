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
| Ubuntu 22.04 LTS | `ubuntu:22.04` | Primary supported | 2026-11-19 |
| Ubuntu 24.04 LTS | `ubuntu:24.04` | Primary supported | 2026-11-19 |
| Ubuntu 26.04 LTS | `ubuntu:26.04` | Validated compatibility path | 2026-11-19 |
| Ubuntu 24.04 CIS L1 | `ubuntu:24.04-cis` | Validated hardened path | 2026-11-19 |
| Ubuntu 26.04 CIS L1 | `ubuntu:26.04-cis` | Validated hardened path | 2026-11-19 |
| Debian 12 | `debian:12` | Validated compatibility path | 2026-11-19 |
| Debian 13 | `debian:13` | Validated compatibility path | 2026-11-19 |
| Rocky Linux 9 | `rocky:9` | Validated compatibility path | 2026-11-19 |
| Rocky Linux 10 | `rocky:10` | Validated compatibility path | 2026-11-19 |
| RHEL 9 | n/a | Compatible (same family as Rocky 9) | n/a |
| RHEL 10 | n/a | Compatible (same family as Rocky 10) | n/a |
| AlmaLinux 9 | n/a | Compatible (same family as Rocky 9) | n/a |
| AlmaLinux 10 | n/a | Compatible (same family as Rocky 10) | n/a |

`bootstrap/install.sh` refuses any other release (for example Ubuntu 20.04 or 25.10, Debian 11, Rocky 8).

**Requirements:** x86_64 or arm64, systemd, root/sudo access, 2 CPU minimum (4 CPU recommended), 4 GB RAM minimum (8 GB recommended), 20 GB disk.

**Architectures:** Ubuntu 22.04, 24.04 and 26.04, Ubuntu 24.04 CIS and 26.04 CIS, Debian 12 and 13, and Rocky Linux 9 and 10 pass the same install-and-verify run on both arm64 (aarch64) and x86_64 (RHEL and AlmaLinux 9 and 10 are compatible by family, not separately validated). The x86_64 runs cover the current pins and use each distribution's official cloud image in a Hyper-V virtual machine with Secure Boot on. The kernel must support seccomp; every workload runs with the `RuntimeDefault` profile.

**Release notes per OS:**
- Rocky and RHEL 10 on x86_64 need an x86-64-v3 CPU (AVX2). AlmaLinux 10 defaults to x86-64-v3 and also ships an x86_64_v2 build for older CPUs. Ubuntu 26.04 AMD64 images from cloud providers are built for AMD64v3 by default. In a VM, the hypervisor must pass the host CPU features through.
- RHEL 10 moved the iptables compatibility modules k3s uses (`nft_compat`, `xt_` matches) into `kernel-modules-extra`. On EL10, when the running distribution kernel cannot resolve them, the installer installs the modules-extra build of that kernel's package (`kernel-modules-extra`, or `kernel-64k-modules-extra` and so on for variant kernels) before k3s; if the repositories no longer carry that kernel's build, update the kernel, reboot and rerun.
- On EL10 the k3s installer installs upstream's el9 `k3s-selinux` build from its stable channel (1.6-1.el9 in the 2026-11-19 x86_64 run, with the distribution's container-selinux 2.250.0 el10); k3s publishes no stable el10 build yet. The evidence logs up to 2026-11-19 do not record the SELinux mode for Rocky 9 or 10; `verify.sh` records the SELinux mode and Secure Boot state from the next run on.
- Ubuntu 26.04 uses `sudo-rs`, which ignores a bare `sudo -E`. The installer names its `RATHSTED_*` settings, and any set proxy (`http_proxy`, `https_proxy`, `no_proxy`, upper or lower case) and CA bundle (`SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`) variables, in `--preserve-env=` when it re-runs itself with sudo, so pins, the GitOps URL and proxy settings reach the root pass on both sudo implementations.

**Validating EL10:** Rocky Linux 10's validation is the x86_64 run (passed 2026-11-19, which installed `kernel-modules-extra` for the running kernel and the k3s-selinux policy). The arm64 matrix runs in VMs that bring their own kernel, so it skips the kernel-modules-extra and SELinux policy paths; an arm64 pass alone does not validate EL10.

**Not supported:** Fedora, CentOS Stream, Alpine, Arch, and releases older than Ubuntu 22.04, Debian 12 or EL9.

## Related Docs

- [Quickstart](quickstart.md)
- [Upgrade Guide](upgrade-guide.md)
- [Architecture](architecture.md)
