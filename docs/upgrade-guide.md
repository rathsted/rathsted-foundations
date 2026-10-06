# Upgrade Guide

## Overview

Foundations uses tagged releases (`vX.Y.Z`). Each release pins specific versions of k3s, Flux, and Kyverno to a tested combination. Customer instances reference a specific Foundations version via `foundations-version.env`.

Upgrades are performed by updating the version pin and re-running the bootstrap script. There is no in-place migration tooling — the bootstrap script is idempotent and handles reconciling the existing cluster to the target state.

---

## Upgrading from 1.x to 2.0

2.0 changes the namespace label contract, so it needs one manual step **before** you upgrade.

| | 1.x | 2.0 |
|---|---|---|
| Jurisdiction label | `jurisdiction`, any non-empty value | `rathsted.io/jurisdiction`, one of `ca`, `us`, `fr` |
| Operator control | not used | `rathsted.io/operator-control`, stamped by the platform at admission |
| Contract `foundations_series` | `1.x` | `2.x` |

After the upgrade, a namespace without a valid `rathsted.io/jurisdiction` is rejected on its next create or update, including when Flux re-applies it. The bare `jurisdiction` label is ignored.

**1. Relabel while still on 1.x.** 1.x accepts the extra label, so this is safe to do first. Keep the old label for now so a rollback to 1.x still works.

```bash
kubectl get ns -L jurisdiction,rathsted.io/jurisdiction

for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in kube-system|kube-public|kube-node-lease|kyverno) continue ;; esac
  [[ -n "$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.rathsted\.io/jurisdiction}')" ]] && continue
  old="$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.jurisdiction}')"
  case "$old" in
    ca|us|fr) kubectl label ns "$ns" "rathsted.io/jurisdiction=${old}" ;;
    *)        echo "decide manually: ${ns} (jurisdiction='${old}')" ;;
  esac
done
```

Label anything reported as "decide manually" with the right value yourself. Update the same labels in your GitOps manifests, or Flux will later re-apply namespaces without them.

**2. Do not set `rathsted.io/operator-control`.** 2.0 stamps it on each namespace at admission and overwrites any value you set. Existing namespaces get it on their next update.

**3. Update tooling that checks the contract series.** Anything that requires `foundations_series` to be `1.x` must accept `2.x`. Decks releases from before this change refuse a `2.x` cluster in preflight.

**4. Upgrade and verify** with Method 1 or 2 below, then:

```bash
make verify
kubectl get ns -L rathsted.io/jurisdiction,rathsted.io/operator-control
```

Once you are not going to roll back, you can remove the old label: `kubectl label ns <name> jurisdiction-`.

---

## Pre-Upgrade Checklist

Before starting an upgrade:

1. Back up current cluster state:
   ```bash
   k3s kubectl get all -A -o yaml > pre-upgrade-backup.yaml
   ```

2. Note the current version:
   ```bash
   cat foundations-version.env
   # or
   git describe --tags
   ```

3. Review `CHANGELOG.md` for breaking changes between your current version and the target version. Pay attention to:
   - Policy additions or removals
   - k3s, Flux, or Kyverno version bumps
   - Changes to bootstrap script behavior

4. Confirm Flux has finished reconciling — no pending or failing kustomizations:
   ```bash
   flux get kustomizations -A
   ```

5. Confirm no in-flight deployments or active rollouts:
   ```bash
   kubectl get pods -A | grep -v Running | grep -v Completed
   ```

6. Confirm toolchain sovereignty posture for the target environment:
   - CI runner location and ownership documented
   - Registry location/jurisdiction approved
   - Signing key custody (KMS/HSM or approved secret store) confirmed
   - Audit log exports available for Git, CI, registry, and cluster events

If any item above is unknown, treat the upgrade as blocked until ownership and residency are explicit.

---

## Upgrade Steps

### Method 1: Git Tag (recommended for Foundations repo itself)

Use this when upgrading the Foundations repository directly.

```bash
git fetch --tags
git checkout vX.Y.Z
./bootstrap/install.sh
./bootstrap/verify.sh
```

### Method 2: Customer Instance

Use this when upgrading a customer instance that pins Foundations via `foundations-version.env`.

```bash
# Update the version pin
# Edit foundations-version.env and set:
FOUNDATIONS_VERSION=vX.Y.Z

# Re-run bootstrap to apply the new version
./bootstrap.sh
```

### Method 3: Track main (development only)

Not recommended for production. Use only for testing against the latest development state.

```bash
git pull origin main
./bootstrap/install.sh
./bootstrap/verify.sh
```

---

## Post-Upgrade Verification

After bootstrap completes:

1. Run the verification script — all checks should pass:
   ```bash
   ./bootstrap/verify.sh
   ```

2. Confirm Flux has reconciled all sources and kustomizations:
   ```bash
   flux get all
   ```

3. Confirm Kyverno cluster policies are active:
   ```bash
   kubectl get cpol
   ```

4. Confirm the demo app is running:
   ```bash
   kubectl get pods -n demo
   ```

If any check fails, do not proceed. Investigate before treating the upgrade as complete.

---

## Rollback

### Git-based rollback

Check out the previous release and re-run bootstrap:

```bash
git checkout v<previous-version>
./bootstrap/install.sh
./bootstrap/verify.sh
```

This works reliably when the k3s version has not changed between releases. Bootstrap is idempotent and will reconcile the cluster back to the previous state.

### Full reinstall (nuclear option)

Required when the k3s version has changed and a downgrade is needed, or when the cluster state is unrecoverable:

```bash
./bootstrap/uninstall.sh
git checkout v<previous-version>
./bootstrap/install.sh
./bootstrap/verify.sh
```

This destroys all cluster state. Restore workloads from backup or Flux will re-deploy managed resources automatically after bootstrap completes.

---

## Version Compatibility

k3s, Flux, and Kyverno versions are pinned per Foundations release. See `docs/versions.md` for the full version matrix.

Key points:

- Upgrading Foundations may upgrade one or more of these components.
- Downgrading to a release with the same k3s version is supported via git checkout and re-running bootstrap.
- Downgrading across a k3s version boundary requires a full uninstall and reinstall.
- Flux and Kyverno upgrades are handled by bootstrap and do not require cluster teardown.

---

## Troubleshooting

**Flux stuck reconciling after upgrade**

Force a reconciliation of the Foundations source:
```bash
flux reconcile source git rathsted-foundations -n flux-system
```

Check for errors in specific kustomizations:
```bash
flux get kustomizations -A
flux logs --level=error -n flux-system
```

**Policy violations after upgrade**

New releases may add Kyverno policies that block existing workloads. Check the CHANGELOG for new policies, then either:
- Update affected workloads to comply with the new policy
- Add a policy exception via `docs/policy-exceptions.md` if the violation is intentional

**k3s version mismatch**

If bootstrap reports a k3s version conflict:
```bash
make uninstall
make install
```

This performs a full uninstall and reinstall. Flux-managed workloads will be redeployed automatically. Non-Flux workloads must be restored manually.

**Bootstrap fails partway through**

Bootstrap is idempotent. Re-running it is safe:
```bash
./bootstrap/install.sh
```

If the failure is persistent, check logs for the specific step that failed and consult `CHANGELOG.md` for known issues in the target release.
