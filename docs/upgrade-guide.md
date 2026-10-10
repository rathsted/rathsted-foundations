# Upgrade Guide

## Overview

Foundations uses tagged releases (`vX.Y.Z`). Each release pins specific versions of k3s, Flux, and Kyverno to a tested combination. Customer instances reference a specific Foundations version via `foundations-version.env`.

**In-place upgrades are not supported in 2.0.x.** `install.sh` detects an existing cluster whose k3s or Kyverno version differs from the release pins and refuses to continue, telling you to reinstall on a clean host. Real in-place upgrades are planned for a future release.

To upgrade: relabel namespaces if needed (see 1.x→2.0 section below), back up your cluster state, then reinstall on a clean host and restore workloads from backup or let Flux redeploy them.

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

**4. Reinstall on a clean host.** Back up cluster state first (`k3s kubectl get all -A -o yaml > pre-upgrade-backup.yaml`), then uninstall the old cluster and run a fresh `./bootstrap/install.sh` from the 2.x tag. Flux will redeploy managed workloads automatically; non-Flux workloads must be restored from backup.

```bash
# On the old host — back up first
k3s kubectl get all -A -o yaml > pre-upgrade-backup.yaml

# Uninstall the 1.x cluster
./bootstrap/uninstall.sh

# Check out 2.x and install fresh
git checkout v2.0.0   # or the target 2.x tag
./bootstrap/install.sh
./bootstrap/verify.sh
kubectl get ns -L rathsted.io/jurisdiction,rathsted.io/operator-control
```

Once the 2.x cluster is verified, you can remove the old bare `jurisdiction` label from your GitOps manifests.

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

### Method 1: Git Tag (clean host required in 2.0.x)

Use this when upgrading the Foundations repository directly. Because in-place upgrades are not supported, run this on a clean host after uninstalling the previous cluster.

```bash
# Uninstall current cluster first
./bootstrap/uninstall.sh

# Check out the target release and reinstall
git fetch --tags
git checkout vX.Y.Z
./bootstrap/install.sh
./bootstrap/verify.sh
```

### Method 2: Customer Instance (clean host required in 2.0.x)

Use this when upgrading a customer instance that pins Foundations via `foundations-version.env`. Same clean-host requirement applies.

```bash
# Uninstall current cluster first
./bootstrap/uninstall.sh

# Update the version pin
# Edit foundations-version.env and set:
FOUNDATIONS_VERSION=vX.Y.Z

# Reinstall on the clean host
./bootstrap.sh
```

### Method 3: Track main (development only)

Not recommended for production. Use only for testing against the latest development state, on a fresh or already-uninstalled host.

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

Only applicable when the k3s and Kyverno versions have not changed between the current and previous release. If those versions differ, the installer will refuse; use the full reinstall path below.

```bash
./bootstrap/uninstall.sh
git checkout v<previous-version>
./bootstrap/install.sh
./bootstrap/verify.sh
```

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
- In 2.0.x, any change to the k3s or Kyverno version requires a clean reinstall. `install.sh` detects version mismatches and refuses to continue.

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
- Add a policy exception (see [Policy Exceptions](policy-exceptions.md)) if the violation is intentional

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
