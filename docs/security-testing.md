# Security Testing

How to verify Rathsted Foundations is secure, and when to run each check.

## Quick Reference

The following targets are available in the **public Makefile**:

| Target | What it checks | When to run |
|---|---|---|
| `make policy-test` | Kyverno CLI policy tests | Every CI run |
| `make verify` | Cluster health, policy enforcement, evidence generation | After install, before release |
| `make verify-release` | Release-grade verification (registry, signatures enforced) | Before release |
| `make verify-all` | Full acceptance checks (verify + policy-test + jurisdiction-scan) | Before release |

The following targets are **maintainer CI tooling** — they are not included in this repository and are run from the private source:

| Target | What it checks | When to run (maintainer CI) |
|---|---|---|
| `make security-check` | Everything below | Before every release (maintainer CI) |
| `make supply-chain-check` | Download integrity, pinned versions, no pipe-to-shell | Every CI run (maintainer CI) |
| `make leak-check` | Secrets, private files, internal references | Every CI run (maintainer CI) |
| `make policy-audit` | Kyverno policy gaps (workload kinds, test coverage) | Before release, after policy changes (maintainer CI) |
| `make shell-lint` | Shellcheck on critical scripts | Before release (maintainer CI) |
| `make compat-test` | E2E across supported distros | Nightly / before release (maintainer CI) |
| `make dependency-watch` | Pinned versions vs upstream releases | Weekly (maintainer CI) |

## Check Categories

### What You Can Run

These targets are in the public Makefile and can be run by any operator.

- **`make policy-test`** — Runs Kyverno CLI policy tests against policy definitions. Requires the `kyverno` CLI. Run on every change; it is fast and needs no cluster.
- **`make verify`** — Cluster health, policy enforcement, evidence generation. Run after install, before release, and after policy changes.
- **`make verify-release`** — Release-grade verification (registry reachability and image signature enforcement).
- **`make verify-all`** — Full acceptance checks (verify + policy-test + jurisdiction-scan).

### Maintainer CI Checks

These run from the private release source and are not in this repository. They are documented here so reviewers understand what the pre-release suite covers.

**Every CI run** (fast, no cluster needed):

- **`make supply-chain-check`** (maintainer CI only) — Verifies all binary downloads have checksums, no pipe-to-shell patterns, no mutable upstream installer references, GitHub Actions pinned to commit SHAs, pip installs pinned.
- **`make leak-check`** (maintainer CI only) — Scans for hardcoded credential patterns (API keys, tokens, private keys), checks for .env files, private key files, and internal references in public-facing YAML.

**Nightly or weekly**:

- **`make compat-test`** (maintainer CI only) — Full E2E install + verify on Ubuntu 22.04, Ubuntu 24.04, Rocky 9, Debian 12. Produces evidence artifacts in `artifacts/`.
- **`make dependency-watch`** (maintainer CI only) — Checks pinned dependency versions against upstream releases.

**Before every release**:

- **`make security-check`** (maintainer CI only) — Runs all security checks (supply chain, leaks, policy audit, shell lint, YAML validation). This is the release gate.
- **`make evidence-bundle RELEASE_TAG=vX.Y.Z`** (maintainer CI only) — Generates release evidence package. Supply `CI_RUN_URL`, `REGISTRY_AUDIT_REF`, and `KEY_AUDIT_REF` when you want those references embedded in the bundle.
- **`make verify-public-snapshot PUBLIC_DIR=/path/to/rathsted-foundations`** (maintainer CI only) — Verifies the generated public repo is self-contained, free of known private-only files, and still passes core public validation checks.

**On-demand (maintainer)**:

- **Policy bypass testing** — After changing Kyverno policies, manually test with init containers and ephemeral containers to confirm they are covered. Use `kubectl run --image=... --overrides='...'` with initContainer specs.
- **Public repo review** (maintainer) — After publishing a new release, clone the public repo fresh and review as a new visitor. Check for leaked private files, broken links, and professionalism.
- **Supply chain signing flow** — After changing cosign/signing workflows, test end-to-end: sign an image, verify the signature, generate SBOM, verify SBOM.

## Known Policy Gaps (Tracked)

These gaps are surfaced by `make policy-audit` (maintainer CI only). Verified current as of v2.0.1.

1. **Workload kinds** — Policies only match `Pod`. Kyverno autogenerates matching rules for higher-level resources (Deployment, StatefulSet, DaemonSet, Job, CronJob), but explicit top-level resource coverage provides additional defense in depth.
2. **Test coverage** — Several policies have no Kyverno CLI test coverage. Test fixtures use Docker Hub images instead of ghcr.io, which may mask registry restriction failures.
3. **hostPort and procMount** — Not restricted by any policy. An app with `hostPort` exposes a port on the host network stack; `procMount` access is not checked.
4. **Controller-level policy reports** — Kyverno's policy report for a Deployment may show as passing while the individual pods it owns are blocked. Admission enforcement is pod-level; the controller's status depends on when it created the pods.
5. **grpc probes** — `require-probes.yaml` accepts `httpGet`, `tcpSocket`, and `exec` probes. `grpc` probes may be rejected; validate before using gRPC health checks.

## CI Integration

Add to `.github/workflows/ci.yml` (public targets only):

```yaml
- name: Policy tests
  run: make policy-test
```

Maintainer CI also runs supply-chain and leak checks on every push from the private source.

## Adding New Checks

The maintainer security check script is not included in this repository — it is part of the private release tooling. The checks are organized into these categories:

- `check_supply_chain` — download integrity
- `check_leaks` — secret and file leak detection
- `check_policies` — Kyverno policy analysis
- `check_shell_lint` — shellcheck
- `check_yaml_validation` — kustomize builds

To request a new check or report a gap, open an issue.

## CVE Response Guidance

The weekly CVE check (`.github/workflows/dependency-cve-check.yml`) queries OSV.dev every Monday for all pinned dependencies and creates a GitHub issue if vulnerabilities are found.

### When a patch exists

| Severity | Action | Timeline |
|---|---|---|
| **CRITICAL/HIGH** (remote code execution, auth bypass, actively exploited) | Bump pinned version + checksum immediately. Run `make verify` and `make policy-test` to confirm no regressions. (Maintainer CI additionally runs `make security-check` and `make compat-test` before tagging.) | Same day |
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
# 3. Update the checksum in install.sh and CI workflows
# 4. Update docs/versions.md
# 5. Verify (public targets)
make verify
make policy-test
# 6. Update the version in .github/workflows/dependency-cve-check.yml DEPS array
```
