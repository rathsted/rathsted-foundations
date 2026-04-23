# Sovereign Toolchain Inventory

Use this inventory during customer onboarding, release readiness, and audits.

## Required Inventory Fields

| Domain | Required Fields |
|--------|-----------------|
| Git hosting | Provider, legal entity, repo owner, region/jurisdiction, branch protection status |
| CI runners | Runner type (hosted/self-hosted), host location, operator owner, hardening baseline |
| Artifact registry | Registry endpoint, jurisdiction, data retention policy, audit log export path |
| Signing keys | Key store type (KMS/HSM/secret manager), custody owner, rotation cadence, incident rotation trigger |
| Evidence storage | Where SBOM, verification logs, and release evidence bundles are retained |
| Cluster control plane | Cluster owner, region/site, Flux source repo, audit log retention setting |

## Minimum Acceptance Criteria

1. Every field above has an explicit value in customer documentation.
2. CI and registry jurisdictions are approved by customer governance.
3. Signing key custody owner is identified by team and role.
4. Evidence retention period is defined and auditable.

## Verification Commands

```bash
./bootstrap/verify.sh --dry-run
make jurisdiction-scan
```
