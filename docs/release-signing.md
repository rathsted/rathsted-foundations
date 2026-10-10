# Release Signing (Tagged Images)

Operators **sign the workload images** they deploy. Foundations ships Kyverno policies, `cosign.pub` wiring, and `make verify-release` — it does **not** build application images in this repository.

Use local or self-hosted `make verify-release` runs for release-grade checks against the registry and image you actually plan to deploy.

## Prerequisites

Before your first signed rollout:

1. **Generate a cosign keypair** (if not already done):
   ```bash
   cosign generate-key-pair
   mv cosign.pub supply-chain/cosign/cosign.pub
   mv cosign.key supply-chain/cosign/cosign.key
   ```
2. **Update the Kyverno signature policy** with the public key:
   ```bash
   ./supply-chain/cosign/update-policy.sh
   ```
3. **If you automate signing in CI** (optional), store key material in your runner’s secret store — not in git. Hosted GitHub Actions can use `COSIGN_PRIVATE_KEY` / `COSIGN_PASSWORD` if you choose that path.
4. **Confirm signature policy is in Enforce mode**:
   - `validationFailureAction: Enforce` in `policies/require-signed-images.yaml` (default)

## Key Residency And Custody

For sovereign deployments, document and enforce where signing keys are stored and who can use them.

- Preferred: customer-controlled KMS/HSM with jurisdictionally compliant residency.
- Acceptable fallback: encrypted key material in a customer-managed secret manager with strict access controls.
- Avoid storing long-lived signing keys on developer workstations.
- If using hosted CI, explicitly record the jurisdictional exposure and approval.
- Rotate keys on a defined cadence and after any CI or credential incident.

## Release Flow (typical)

1. Merge changes to `main` and ensure CI is green.
2. Optional: `make sovereignty-check` (maintainer CI only; and `STRICT=1` with a filled customer inventory when appropriate).
3. **Tag** your Foundations release if you version the repo itself:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
4. **Sign the workload image** you configured with `make configure` (not a separate “demo build” from this repo):
   ```bash
   make sign IMAGE=registry.example.com/your-org/your-app:1.0.0
   ```
5. Run **release verification** (below).

## Reference Image

Rathsted publishes a signed demo image alongside each tagged release:

- Image: `ghcr.io/rathsted/foundations-demo:<version>`
- Signed with the Rathsted Cosign key (`supply-chain/cosign/cosign.pub`)
- SBOM produced by Syft and attached as a release artifact

This image is a **verification fixture**, not a product surface. Its job is to give anyone — operator, auditor, or casual reviewer — a concrete way to end-to-end verify the cosign + SBOM workflow against a real Rathsted-signed artifact, without having to stand up their own signing infrastructure first.

What it is:
- A minimal public container you can `cosign verify` against `cosign.pub` to prove the signing workflow is real.
- The default target of `./bootstrap/verify.sh` when `RATHSTED_DEMO_IMAGE` is unset.

What it is not:
- The Foundations product itself. The product is this repository plus the images **you** sign for **your** environment.
- A runtime dependency. The baseline does not require this image to function.

Operators are expected to point `RATHSTED_DEMO_IMAGE` (or `IMAGE` via `make configure`) at an image in their own registry, signed with their own key, for real deployments.

## Release Verification

### Local verification (default for this repo)

Point `RATHSTED_DEMO_IMAGE` at the **same** image reference you configured (see `config/customer.env` after `make configure`):

```bash
export RATHSTED_DEMO_IMAGE=registry.example.com/your-org/your-app:1.0.0
make verify-release
```

Requires: network access to **pull** that image from its registry, and `cosign.pub` in `supply-chain/cosign/`.

### Optional: automated verification in CI

If your organization maintains a separate workflow that provisions a cluster and runs `make verify-release`, use that pipeline and confirm zero failures. The stock **public** GitHub Actions workflows do not replace this step.

## Audit Evidence Bundle

After release verification, generate a reusable evidence document (maintainer-only target; not in the public Makefile):

```
# maintainer-only
make evidence-bundle RELEASE_TAG=vX.Y.Z
```

This captures git provenance, cosign verification output when `cosign` and `cosign.pub` are present, hardening config excerpts, artifact details with SHA-256 digests, any CI/registry/key-audit references you pass in, and a structured key-rotation attachment when you supply one.

Example (maintainer-only):

```
CI_RUN_URL=https://github.com/org/repo/actions/runs/123 \
REGISTRY_AUDIT_REF=s3://audit-bucket/releases/vX.Y.Z.json \
KEY_AUDIT_REF=arn:aws:kms:... \
KEY_ROTATION_EVIDENCE=examples/customer-instance/key-rotation-evidence-template.md \
KEY_ROTATION_SUMMARY="KMS key rotated 2026-04-14 after quarterly review" \
# maintainer-only target: not in the public Makefile
make evidence-bundle RELEASE_TAG=vX.Y.Z
```

Recommended format:

- Use `examples/customer-instance/key-rotation-evidence-template.md` as the starting point for the key-rotation attachment.
- Fill in the actual key identifier, versions, custody owner, approval reference, and audit record reference before bundling.

## Evidence

A passing release verification produces:

- SBOM artifact metadata and SHA-256 digest
- Cosign signature verification output against the published public key when `cosign` is available
- Kyverno policies enforced (including signed-image policy)
- Negative tests confirming policy rejection of bad manifests
- Optional CI / registry / key-audit references when supplied at bundle time
- Structured key-rotation evidence attachment when supplied at bundle time

## Current Evidence Scope

The release evidence bundle is intentionally narrow. Today it captures:

- git tag provenance and recent commit summary
- SBOM artifact presence plus SHA-256 digest
- cosign verification output when the required tooling and public key are present
- vulnerability scan artifact presence plus SHA-256 digest when a scan was run
- Flux and Kyverno state when captured on an operator host
- hardening config excerpts
- optional CI, registry, and key-audit references passed in at bundle time
- optional key-rotation evidence file and rotation summary passed in at bundle time

It does not currently automate:

- secrets lifecycle evidence
- backup / restore evidence
- broad workload-level runtime attestation beyond the shipped verification flow

## Notes

- Git tag version and container image tag are **independent** unless your pipeline ties them together.
- Do not commit `cosign.key`.

## Related Docs

- [Supply Chain](supply-chain.md)
- [Pipeline Sovereignty](pipeline-sovereignty.md)
- [Jurisdiction Control Matrix](jurisdiction-control-matrix.md)
