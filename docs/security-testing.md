# Security Testing

How to verify Rathsted Foundations is secure, and when to run each check.

## Quick Reference

| Target | What it checks | When to run |
|---|---|---|
| `make security-check` | Everything below | Before every release |
| `make supply-chain-check` | Download integrity, pinned versions, no pipe-to-shell | Every CI run |
| `make leak-check` | Secrets, private files, internal references | Every CI run |
| `make policy-audit` | Kyverno policy gaps (init containers, workload kinds, test coverage) | Before release, after policy changes |
| `make shell-lint` | Shellcheck on critical scripts | Before release |
| `make policy-test` | Kyverno CLI policy tests (existing) | Every CI run |
| `make verify` | Cluster health, policy enforcement, evidence generation | After install, before release |
| `make compat-test` | E2E across supported distros | Nightly / before release |
| `make dependency-watch` | Pinned versions vs upstream releases | Weekly |

## Check Categories

### Automated / Every CI Run

These should run on every push. They are fast and need no cluster.

- **`make supply-chain-check`** -- Verifies all binary downloads have checksums, no pipe-to-shell patterns, no mutable upstream installer references, GitHub Actions pinned to commit SHAs, pip installs pinned.
- **`make leak-check`** -- Scans for hardcoded credential patterns (API keys, tokens, private keys), checks for .env files, private key files, and internal references in public-facing YAML.
- **`make policy-test`** -- Runs Kyverno CLI tests against policy definitions. Requires `kyverno` CLI.

### Automated / Nightly or Weekly

These are slower or need external data.

- **`make compat-test`** -- Full E2E install + verify on Ubuntu 22.04, Ubuntu 24.04, Rocky 9, Debian 12. Produces evidence artifacts. Run nightly or before release.
- **`make dependency-watch`** -- Checks pinned dependency versions against upstream releases. Run weekly to catch stale pins.

### Before Release

Run the full suite before cutting a release.

- **`make security-check`** -- Runs all security checks (supply chain, leaks, policy audit, shell lint, YAML validation). This is the gate.
- **`make verify-all`** -- Full acceptance checks (cluster verify + policy test + jurisdiction scan).
- **`make evidence-bundle RELEASE_TAG=vX.Y.Z`** -- Generates release evidence package. Supply `CI_RUN_URL`, `REGISTRY_AUDIT_REF`, and `KEY_AUDIT_REF` when you want those references embedded in the bundle.
- **`make verify-public-snapshot PUBLIC_DIR=/path/to/rathsted-foundations`** -- Verifies that the generated public repo is self-contained, free of known private-only files, and still passes core public validation checks.

### On-demand / As-needed

These are manual or situational.

- **Policy bypass testing** -- After changing Kyverno policies, manually test with init containers and ephemeral containers to confirm they are covered. Use `kubectl run --image=... --overrides='...'` with initContainer specs.
- **Public repo review** -- After `make publish`, clone the public repo fresh and review it as a new visitor would. Check for leaked private files, broken links, and professionalism.
- **Public snapshot verification** -- After `make publish`, run `make verify-public-snapshot PUBLIC_DIR=/path/to/rathsted-foundations` before committing or tagging the public repo.
- **Supply chain signing flow** -- After changing cosign/signing workflows, test end-to-end: sign an image, verify the signature, generate SBOM, verify SBOM.

## Known Policy Gaps (Tracked)

These are surfaced by `make policy-audit` as warnings:

1. **initContainers and ephemeralContainers** -- Not covered by any container-level policy. An init container can bypass all security rules.
2. **Workload kinds** -- Policies only match `Pod`. Should also match Deployment, StatefulSet, DaemonSet, Job, CronJob for defense in depth.
3. **Network policy scope** -- `baseline-networkpolicy.yaml` only generates for the `demo` namespace. All other namespaces have no default-deny.
4. **Test coverage** -- Several policies have no Kyverno CLI test coverage. Test fixtures use Docker Hub images instead of ghcr.io, which may mask registry restriction failures.
5. **Probe types** -- `require-probes.yaml` only accepts `httpGet` probes at path `/`. Rejects valid `tcpSocket`, `exec`, and `grpc` probes.

## CI Integration

Add to `.github/workflows/ci.yml`:

```yaml
- name: Security checks
  run: |
    make supply-chain-check
    make leak-check
```

Add to nightly workflow:

```yaml
- name: Full security audit
  run: make security-check
```

## Adding New Checks

Security checks live in `scripts/security-checks.sh`. The script is organized into functions:

- `check_supply_chain` -- download integrity
- `check_leaks` -- secret and file leak detection
- `check_policies` -- Kyverno policy analysis
- `check_shell_lint` -- shellcheck
- `check_yaml_validation` -- kustomize builds

To add a new check, add it to the appropriate function or create a new one. Use `ok`, `warn`, or `fail` for output. `fail` causes a non-zero exit. `warn` is informational.

## CVE Response Guidance

The weekly CVE check (`.github/workflows/dependency-cve-check.yml`) queries OSV.dev every Monday for all pinned dependencies and creates a GitHub issue if vulnerabilities are found.

### When a patch exists

| Severity | Action | Timeline |
|---|---|---|
| **CRITICAL/HIGH** (remote code execution, auth bypass, actively exploited) | Bump pinned version + checksum immediately. Run `make security-check` and `make compat-test` to verify. | Same day |
| **MEDIUM** (requires local access, specific conditions, limited impact) | Plan to patch. Document risk and any mitigating factors. | Within one week |
| **LOW** (theoretical, informational, already mitigated by policies) | Patch on next regular update cycle. | Next release |

### When no patch exists

If the upstream project has not released a fix:

1. **Assess actual exposure.** Does the CVE apply to how Foundations uses the component? Many CVEs require conditions that our policies or configuration already prevent (e.g., a privilege escalation CVE is less relevant when `disallow-privileged` blocks privileged containers).

2. **Add a compensating control if possible.** For example:
   - A network-level CVE can be mitigated by tightening NetworkPolicies
   - An API-level CVE can be mitigated by restricting access at the ingress layer
   - A container escape CVE is partially mitigated by non-root enforcement and dropped capabilities

3. **Document the accepted risk.** Create an entry in `docs/known-risks.md` (or the GitHub issue) with:
   - The CVE ID and affected component/version
   - Why no patch is available yet
   - What compensating controls are in place
   - When to re-evaluate (e.g., "check upstream monthly")

4. **Consider disabling the component** if the CVE is critical, unmitigable, and the component is not essential.

5. **Never roll back blindly.** Rolling back to a previous version trades one set of risks for another. Only roll back if you just bumped a version and the new version introduced the CVE.

### Updating a pinned version

When bumping a dependency:

```bash
# 1. Update the version in bootstrap/install.sh (and CI workflows if applicable)
# 2. Get the new checksum
curl -fsSL <new-release-url> | sha256sum
# 3. Update the checksum in install.sh, CI workflows, and orbstack-host-e2e.sh
# 4. Update docs/versions.md
# 5. Verify
make security-check
make compat-test
# 6. Update the version in .github/workflows/dependency-cve-check.yml DEPS array
```
