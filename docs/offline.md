# Offline/Local‑Only Notes

The baseline can bootstrap online, then run offline. For full offline bootstrap you must pre‑stage:
- `k3s` installer script (fetched from `https://raw.githubusercontent.com/k3s-io/k3s/<K3S_VERSION>/install.sh`) and its SHA-256 checksum
- `k3s` binary (fetched by the installer script from the k3s release; the installer verifies it against the official sha256sum file)
- Flux CLI release archive and its checksums file
- Cosign binary release archive (`cosign-linux-<arch>`) and its checksums file (`cosign_checksums.txt`) from the sigstore/cosign GitHub release
- Syft release archive (`syft_<version>_linux_<arch>.tar.gz`) and its checksums file from the anchore/syft GitHub release
- Grype release archive (`grype_<version>_linux_<arch>.tar.gz`) and its checksums file from the anchore/grype GitHub release
- Kyverno install manifest (vendored at `cluster/policies/kyverno-install.yaml`)
- Container images for Flux, Kyverno, and your demo app

See `bootstrap/install.sh` for the pinned versions and exact download URLs.

For Kyverno, you can vendor the pinned manifest into
`cluster/policies/kyverno-install.yaml`. The installer uses the vendored file
when its version label matches the pin in `bootstrap/install.sh`; otherwise it
downloads the manifest from the upstream GitHub release.
