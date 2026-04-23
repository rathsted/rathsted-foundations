# In-Jurisdiction Registry Guide

This guide documents how to move from the **default example** flow (often a public base image under `docker.io/library` or your first `make configure` prefix) to a registry that satisfies jurisdiction and residency requirements.

This matters because registry location affects artifact custody, retention, and the overall trust story around what was released and where it lived.

## Supported Patterns

1. Self-hosted `registry:2` (minimum viable)
2. Self-hosted Harbor (recommended for production)
3. In-country managed registry approved by customer governance

## Implementation Steps

1. Choose the approved registry endpoint and image name.
2. Run `make configure` or `./scripts/configure.sh --registry ... --image ...`.
3. Push or sign the image you want Rathsted to validate.
4. Apply your cosign public key with `./supply-chain/cosign/update-policy.sh`.
5. Re-run release verification against the approved registry.

## Example

```bash
./scripts/configure.sh \
  --registry registry.customer.example/rathsted \
  --image registry.customer.example/rathsted/app:1.0.0
make sign IMAGE=registry.customer.example/rathsted/app:1.0.0
RATHSTED_DEMO_IMAGE=registry.customer.example/rathsted/app:1.0.0 make verify-release
```

## Policy Guardrail Check

Confirm registry restrictions still enforce approved sources:

```bash
kyverno test tests/kyverno -f kyverno-test.yaml
```

## Related Docs

- [Pipeline Sovereignty](pipeline-sovereignty.md)
- [Jurisdiction Control Matrix](jurisdiction-control-matrix.md)
- [Supply Chain](supply-chain.md)
