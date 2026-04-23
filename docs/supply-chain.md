# Supply Chain (Signing + SBOM)

This baseline uses Cosign key-pair signing and Syft SBOM generation. These steps are part of the trust story Foundations is built around: what shipped, where it came from, and what is inside it.

The default demo uses `nginx:1.29.7-alpine` from Docker Hub as a placeholder for onboarding. Foundations does not ship its own application image. For production, replace this with your own image and run the steps below against it.

## 1) Generate signing keys
```bash
cosign generate-key-pair
mv cosign.pub supply-chain/cosign/cosign.pub
mv cosign.key supply-chain/cosign/cosign.key
```

## 2) Update signature policy
```bash
./supply-chain/cosign/update-policy.sh
```

## 3) Sign your image
```bash
export IMAGE=registry.example.com/your-app:1.0.0
make sign IMAGE="$IMAGE"
```

## 4) Generate SBOM
```bash
make sbom IMAGE="$IMAGE"
```
Output: `supply-chain/sbom/output/image.sbom.json`

Note: `bootstrap/install.sh` installs pinned `syft` and `grype` versions with checksum verification. The install will fail if the checksum does not match.

## Using a different registry

After `make configure`, your registry prefix and image are rendered into policies and overlays. To switch registries, re-run `configure` or edit the Kustomize overlay so the image reference matches:

```yaml
# examples/hello-gitops-app/overlays/local/kustomization.yaml
images:
  - name: nginx
    newName: registry.example.com/your-app
    newTag: 1.0.0
```

Also update `cluster/gitops/apps/kustomization.yaml` and the `restrict-registries` Kyverno policy allowlist. Then run `make verify-release` to confirm the supply-chain checks pass.

## Registry Options (Jurisdiction And Residency)

1. **Docker Hub (default placeholder)** — The tracked example uses `docker.io/library/nginx` as a public base image for onboarding. Pull or mirror it under **your** prefix if Docker Hub is not acceptable.
2. **GitHub Container Registry (GHCR)** — Common for teams already on GitHub; jurisdiction follows GitHub’s platform footprint.
3. **Self-hosted registry** (`registry:2`, Harbor, etc.) in customer infrastructure
   - Strong fit for strict sovereignty requirements.
   - Keep storage, access logs, and retention in customer-controlled systems.
4. **In-country managed registry**
   - Acceptable when legal terms and data residency align with customer controls.
   - Document provider region, legal entity, and export controls in customer runbooks.

Minimum actions when **not** using the default placeholder image / registry:
- Set `IMAGE` to the approved registry.
- Update `cluster/gitops/apps/kustomization.yaml` image rewrite.
- Update `restrict-registries` Kyverno policy allowlist to the approved registry endpoints.
- Verify release with `make verify-release` against the chosen registry.

## Dev vs Release Verification

In **dev mode** (`make verify`), supply chain checks are best-effort:
- SBOM is generated from the local k3s containerd image if available
- Cosign verification is skipped if the image isn't signed or in a registry
- Both produce `[ok]` with an explanatory note

In **release mode** (`make verify-release`), supply chain checks are enforced:
- Registry must be reachable
- SBOM must generate successfully
- Cosign signature must verify against `supply-chain/cosign/cosign.pub`
- Signature policy must be in `Enforce` mode (not `Audit`)

## CI Notes
CI may reference a configured example image for SBOM or Grype steps where enabled. Treat those outputs as review artifacts unless you promote them to release gates in your own pipeline.

## Notes
- Store `cosign.key` securely and never commit it.
- For CI, set `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` secrets.
- See `docs/release-signing.md` for the full release flow.

## Related Docs

- [Release Signing](release-signing.md)
- [Policies](policies.md)
- [Compliance Mapping](compliance-mapping.md)
