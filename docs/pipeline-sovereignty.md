# Pipeline Sovereignty (CI Runner Placement)

CI runner placement is part of the control story. If the cluster is in one jurisdiction but the build and signing path runs somewhere else, that difference may matter to customers, procurement, or regulators.

For stricter sovereignty deployments, run CI on customer-controlled runners in approved jurisdictions.

## Runner Placement Requirements

- Runner host is in customer-approved jurisdiction.
- Runner operator is customer team or approved managed operator.
- Runner network egress is restricted to approved endpoints (git, registry, package mirrors).
- Runner logs are retained in customer-controlled storage.

## Minimum Hardening Baseline

- Ephemeral runners preferred for release jobs.
- No long-lived signing keys on runner disks.
- Least-privilege tokens for git and registry access.
- Explicit artifact retention policy for SBOM and verification logs.

## Hosted CI Exposure Note

Hosted CI (for example, GitHub-hosted runners) may introduce jurisdictional exposure.
If hosted CI is used, document:

1. Why self-hosted is not used
2. Exposure acceptance owner
3. Expiration/review date for that exception

## Verification Command

```bash
make jurisdiction-scan
```

## Related Docs

- [Jurisdiction Control Matrix](jurisdiction-control-matrix.md)
- [Registry Residency Guide](registry-residency-guide.md)
- [Release Signing](release-signing.md)
