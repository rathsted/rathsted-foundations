# Offline/Local‑Only Notes

The baseline can bootstrap online, then run offline. For full offline bootstrap you must pre‑stage:
- `k3s` install script and binary
- Flux CLI
- Kyverno install manifest
- Container images for Flux, Kyverno, and your demo app

See `docs/versions.md` and `bootstrap/install.sh` for the exact URLs and versions.

For Kyverno, you can vendor the pinned manifest into
`cluster/policies/kyverno-install.yaml`. If that file is present and non‑empty,
the installer uses it instead of fetching from the network.
