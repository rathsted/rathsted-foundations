# Operator Training Checklist (Sovereign DevOps)

Use this checklist to prepare platform and security operators before production rollout.

## Audience

- Platform operator (cluster + GitOps)
- Security/compliance operator (policy + evidence)
- Release operator (signing + registry + CI verification)

## Required Training Topics

1. GitOps change control
   - Protected branch workflow
   - PR review requirements
   - Rollback by git revert
2. Policy enforcement operations
   - Kyverno policy failure triage
   - Exception process and expiration handling
3. Supply-chain controls
   - Signing workflow and verification
   - SBOM generation and retention
   - Registry allowlist management
4. Sovereignty controls
   - CI runner jurisdiction and ownership
   - Registry/data residency constraints
   - Key custody model (KMS/HSM preferred)
5. Evidence and audit handling
   - Archive release verification output and artifact records
   - Capture CI/registry/key usage references when they exist
   - Retain review records for the required audit window

## Operator Readiness Commands

```bash
./bootstrap/verify.sh --dry-run
make jurisdiction-scan
make verify-release
```

## Sign-Off Record (Template)

- Training date:
- Environment:
- Platform operator:
- Security/compliance operator:
- Release operator:
- Exceptions approved (if any):
- Next review date:
