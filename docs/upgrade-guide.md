# Upgrade Guide

## Overview

Foundations uses tagged releases (`vX.Y.Z`). Each release pins specific versions of k3s, Flux, and Kyverno to a tested combination. Customer instances reference a specific Foundations version via `foundations-version.env`.

**In-place upgrades depend on the version pins.** `install.sh` detects an existing cluster whose k3s or Kyverno version differs from the release pins and refuses to continue, telling you to reinstall on a clean host. A 2.x release that keeps the k3s and Kyverno pins of the release you run (compare `docs/versions.md` in both) is applied in place, by moving the Flux GitRepository to its tag; from v2.0.x, follow [Splitting the policies from the workloads](#splitting-the-policies-from-the-workloads). In-place upgrades across a pin change are planned for a future release.

> **If Flux tracks `branch: main`, pin it first.** An install from a checkout that was not exactly on a tag pins its GitRepository to `branch: main`. If that branch is the public repository's, Flux applies a new release as soon as it is published, before you have prepared for it. Pin to the release you run now, then upgrade with the steps for the target release:
>
> ```bash
> kubectl -n flux-system patch gitrepository rathsted-foundations --type merge -p '{"spec":{"ref":{"branch":null,"tag":"v2.0.2"}}}'
> ```
>
> Or re-run the installer from a checkout of the tag you run (`git checkout v2.0.2`) with `RATHSTED_GIT_REF="tag: v2.0.2"`; not from newer code, which would apply the new release's policies. Flux applies `policies/` from the Git source, so policies you rendered with `make configure` only last when they are committed to `policies/` in a fork that Flux tracks.

To upgrade across a pin change: relabel namespaces if needed (see 1.x→2.0 section below), back up your cluster state, then reinstall on a clean host and restore workloads from backup or let Flux redeploy them.

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

## Labelling the platform namespaces on an existing 2.x install

Installs from v2.0.2 and earlier leave `flux-system`, `kyverno` and `default` without `owner`, `environment` or `rathsted.io/jurisdiction`, so the cluster does not meet the namespace label convention (every namespace labelled) even though admission works. Current installers label them when `RATHSTED_JURISDICTION` is set. On an existing cluster, backfill in place; no reinstall is needed.

**1. See what is missing.** The audit is read-only. It exits 1 while any namespace other than `kube-system`, `kube-public` and `kube-node-lease` lacks the labels, or carries a `rathsted.io/operator-control` that differs from the value the live policy stamps, and 2 if it cannot read the namespaces or the policy.

```bash
./bootstrap/jurisdiction-audit.sh
```

**2. Label the platform namespaces.** Set `J` to the cluster's jurisdiction (`ca`, `us` or `fr`). `rathsted.io/operator-control` is set to the value the live `require-namespace-labels` policy stamps, read from the policy itself. This is the one place you write it: Kyverno's `resourceFilters` keep updates to the `kyverno` namespace out of admission, so the stamp rule never runs on it.

```bash
J=ca
CTL="$(kubectl get cpol require-namespace-labels -o jsonpath='{.spec.rules[?(@.name=="stamp-operator-control")].mutate.patchStrategicMerge.metadata.labels.rathsted\.io/operator-control}')"
echo "operator-control: ${CTL}"
kubectl label namespace flux-system kyverno default owner=platform environment=platform "rathsted.io/jurisdiction=${J}" "rathsted.io/operator-control=${CTL}" --overwrite
kubectl patch configmap rathsted-foundations-contract -n flux-system --type merge -p "{\"data\":{\"r3_jurisdiction\":\"${J}\"}}"
```

Leave `owner=platform environment=platform` out for a namespace that already carries your own values. The last command records the jurisdiction in the Foundations contract marker, which makes `verify.sh` strict about these labels from then on.

An installer from a release that includes `RATHSTED_JURISDICTION` does the same thing when re-run with it set, but only on a cluster whose k3s and Kyverno match that release's pins; otherwise its version guard refuses to continue. Re-running v2.0.2 or earlier labels nothing. The installer sets `owner` and `environment` only where they are absent, always rewrites `rathsted.io/operator-control`, and refuses, writing nothing, if any of the three namespaces already declares a different `rathsted.io/jurisdiction`.

**3. Label anything else the audit reports.** Namespaces Foundations does not own (for example kind's `local-path-storage`, or a workload namespace created before 2.0) need `owner`, `environment` and `rathsted.io/jurisdiction`; put workload namespaces' labels in their GitOps manifests so Flux does not re-apply them unlabelled. `rathsted.io/operator-control` is stamped on that update.

**4. Check again.** `./bootstrap/jurisdiction-audit.sh` exits 0 and `./bootstrap/verify.sh` reports the namespace jurisdiction labels as ok. verify fails on a non-conforming namespace when the install recorded `r3_jurisdiction`, when any of `flux-system`, `kyverno` and `default` declares a jurisdiction, when `RATHSTED_JURISDICTION` is set in its environment, or under `--release` (so `make verify-release` fails until this backfill is done), and then also requires `flux-system`, `kyverno` and `default` to declare that jurisdiction. Otherwise it only warns. It always fails when the audit cannot run.

**When the stamped operator-control changes.** If a deploy overlay or `RATHSTED_OPERATOR_CONTROL` changes the `rathsted.io/operator-control` literal in `require-namespace-labels`, existing namespaces keep the old value: background scans do not mutate. The audit then reports them as non-conforming. Update each one so admission stamps the new value; any update does, for example `kubectl annotate namespace <name> rathsted.io/restamped-at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite`. Write the new value on `kyverno` explicitly, as in step 2, since its updates never reach the stamp rule.

**A stale `r3_operator_control` record.** An install with `RATHSTED_OPERATOR_CONTROL` set records the value in `flux-system/rathsted-foundations-contract`, and `verify.sh` then fails whenever the stamp differs from it. Fix the stamp when the record is still true: enable `components/operator-control/<value>` in your Git source's `cluster/gitops/apps/kustomization.yaml` (see `docs/operator-control-components.md`) or commit that value to its `policies/require-namespace-labels.yaml` (or, without GitOps, re-run `install-managed.sh` with it). Remove the record only when it no longer says who controls the operator: it was declared in error, or the cluster moved to another operator and you have not declared the new one yet. verify then warns that the stamp is undeclared instead of failing:

```bash
kubectl patch configmap rathsted-foundations-contract -n flux-system --type json -p '[{"op":"remove","path":"/data/r3_operator_control"}]'
```

Kyverno background reports no longer list `kube-system`, `kube-public` and `kube-node-lease` as failing `require-namespace-labels`: the policy now excludes them by name, matching what admission already did.

---

## Splitting the policies from the workloads

**What was wrong (v2.0.0 to v2.0.2).** The one Flux Kustomization, `rathsted-sync`, built the Kyverno ClusterPolicies and the demo app as one tree. Flux dry-runs a Kustomization as one batch, and `restrict-registries` denied the demo Deployment (`nginx` from Docker Hub), so `rathsted-sync` never became Ready and never applied the policies. The policies on the cluster were only the installer's seed: a deleted or edited policy was not restored, and an operator-control value set only at install time was not reverted to the one in Git.

**What changed.** `rathsted-sync` keeps its name, path (`./cluster/gitops/apps`) and `prune: true`; that path now builds only the policies and one PolicyException that lets the demo run its Docker Hub image (`cluster/gitops/apps/hello-gitops-registry-exception.yaml`, namespace `demo`, names `hello-gitops` and `hello-gitops-*`, image `nginx:1.29.7-alpine` only, the `restrict-registries` rules only). Workloads moved to `cluster/gitops/workloads`, reconciled by a new Kustomization, `rathsted-apps`, which `dependsOn` `rathsted-sync`. A workload the policies deny now keeps `rathsted-apps` not Ready and nothing else.

Because the `rathsted-sync` object is unchanged, a cluster whose GitOps source reaches a commit with this layout applies the policies at the next reconcile, with no action from you. When that happens depends on the GitRepository ref:

- **Pinned to a tag** (the normal case: `install.sh` pins the tag HEAD is on, for example `tag: v2.0.2`). The cluster stays on the old layout until you move the ref to the new tag in step 4. Re-applying the sync objects alone does not move it.
- **Tracking a branch.** An install from a checkout that is not exactly on a tag pins `branch: main`, so it picks up the new layout when the release reaches that branch, before you do anything. Pin it first (see the note in the [Overview](#overview)), then follow the steps.

Do steps 1 to 3 before the ref reaches the new layout. What follows:

- Flux then stamps the `rathsted.io/operator-control` value your Git source carries. If an installer set another value on this cluster, carry it in Git first (`docs/operator-control-components.md`).
- If you ran `make configure`, the installer applied its rendered `restrict-registries` and `require-signed-images` (your registry and key). Flux now replaces them with the ones in Git at the first reconcile, and pods from your registry are denied from their next creation. Current installers warn about this.
- The demo app is not deployed until `rathsted-apps` exists (step 4).

**1. Carry your rendered registry and signing policies in Git** (only if you ran `make configure`). If Flux tracks the public repository, they can only be kept in a fork: fork it, commit there, and point Flux at the fork (re-run the installer with `RATHSTED_GIT_URL`, or patch the GitRepository's `spec.url`). In your GitOps source:

```bash
cp config/rendered/restrict-registries.yaml policies/restrict-registries.yaml
cp config/rendered/require-signed-images.yaml policies/require-signed-images.yaml
git add policies/restrict-registries.yaml policies/require-signed-images.yaml
git commit -m "Carry the rendered registry and signing policies"
git push
```

**2. Check what `rathsted-sync` owns.** On a stock v2.0.x install it never applied a revision, so the inventory is usually empty. Check: if it prints nothing, go to step 4.

```bash
kubectl get kustomization rathsted-sync -n flux-system -o jsonpath='{.status.inventory.entries[*].id}'
```

**3. Protect any workload it owns.** If the inventory lists anything other than ClusterPolicies (you worked around the denial, or added your own workloads to `cluster/gitops/apps`), `rathsted-sync` prunes those objects when it builds the policies-only tree. A Namespace pruned this way takes everything in it, PersistentVolumeClaims included. Mark them in Git; an annotation set with `kubectl annotate` does not last, because Flux removes fields that kubectl wrote at its next apply.

a. While your source is still on the old layout, add the annotation to each of those manifests in Git (the Namespaces first), then commit and push:

```yaml
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

b. Wait until `rathsted-sync` has applied that commit (`flux get kustomizations -n flux-system` shows it as the applied revision), and check each object, for example:

```bash
kubectl get namespace demo -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}{"\n"}'
```

It must print `disabled` for every object before you go on.

c. In one commit, move those manifests (annotation included) from `cluster/gitops/apps` to `cluster/gitops/workloads` and bring in the new layout. `rathsted-sync` then drops them without deleting them, and `rathsted-apps` (step 4) takes them over in place.

d. Once `rathsted-apps` is Ready, remove the annotation in Git, commit and push.

**4. Apply the sync objects, then move the ref to the new tag.** From a checkout of the release, with `vX.Y.Z` its tag:

```bash
kubectl apply -f cluster/gitops/sync/kustomization.yaml
kubectl -n flux-system patch gitrepository rathsted-foundations --type merge -p '{"spec":{"ref":{"tag":"vX.Y.Z"}}}'
```

The first command adds `rathsted-apps` and leaves `rathsted-sync` as it is. `rathsted-apps` reports an error until your source has `cluster/gitops/workloads`; that is harmless. The second moves the GitRepository, and with it `rathsted-sync`, to the release; this is when `rathsted-sync` builds the policies-only tree and prunes what steps 1 to 3 did not carry or protect. If Flux tracks a fork, the tag must exist there: merge the release into the fork and push the tag, or set the ref to a fork branch or `commit:` that has the new layout. Check with `kubectl -n flux-system get gitrepository rathsted-foundations -o jsonpath='{.spec.ref}'`.

Re-running the release's installer from a checkout of its tag does both: it applies the sync objects and writes the GitRepository pinned to that tag (`RATHSTED_GIT_REF` overrides it). It also re-applies the seed policies and any `config/rendered/` policies, and its version guard refuses if this cluster's k3s or Kyverno differs from the release pins.

Do not point `rathsted-sync` at another path: an object Flux stops building is pruned, so a `rathsted-sync` that built a tree without the policies would delete them.

**5. Check.** Both Kustomizations are Ready, and the policies carry Flux's ownership labels:

```bash
flux get kustomizations -n flux-system
kubectl get cpol -l kustomize.toolkit.fluxcd.io/name=rathsted-sync
```

`./bootstrap/verify.sh` checks the first part too: it fails while `rathsted-sync` is not Ready, and warns while `rathsted-apps` is not (fails under `--release`).

From now on, add your own workloads to `cluster/gitops/workloads`, not to `cluster/gitops/apps`. When you replace or remove the demo app, delete `hello-gitops-registry-exception.yaml` and its entry in `cluster/gitops/apps/kustomization.yaml`.

---

## Pod controllers are checked at admission

**What was wrong (v2.0.2 and earlier).** `disallow-privileged`, `drop-all-capabilities`, `require-seccomp`, `require-readonly-rootfs`, `disallow-host-namespaces` and `restrict-hostpath` listed `Pod` and the controllers (Deployment, StatefulSet, DaemonSet, Job, CronJob) in one rule. Kyverno does not generate autogen rules for such a rule, so on a controller the rule read the controller's own `spec`, where there are no containers, `hostNetwork` or `volumes`, and admitted it. A privileged or hostNetwork Deployment was accepted, and only its Pods were denied later, when the ReplicaSet controller created them: the Deployment sat at 0 ready replicas with the denial in the ReplicaSet's events.

**What changed.** Each of those rules matches `Pod` only, and the policy sets `pod-policies.kyverno.io/autogen-controllers: DaemonSet,Deployment,Job,StatefulSet,ReplicationController,CronJob`. Kyverno checks each controller's pod template at admission under generated rule names: `autogen-<rule>` for Deployment, StatefulSet, DaemonSet, Job and ReplicationController, `autogen-cronjob-<rule>` for CronJob. A non-compliant controller is now refused by `kubectl apply` or by Flux's dry run, with the policy message.

**What you need to do.**

1. **PolicyExceptions.** An exception that matches a controller and names one of these rules must also name the autogen rule, or the controller is denied:

   | Policy | Rule | Add for Deployment, StatefulSet, DaemonSet, Job, ReplicationController | Add for CronJob |
   |--------|------|------|------|
   | `disallow-privileged` | `privileged` | `autogen-privileged` | `autogen-cronjob-privileged` |
   | `drop-all-capabilities` | `require-drop-all` | `autogen-require-drop-all` | `autogen-cronjob-require-drop-all` |
   | `drop-all-capabilities` | `restrict-added-capabilities` | `autogen-restrict-added-capabilities` | `autogen-cronjob-restrict-added-capabilities` |
   | `require-seccomp` | `seccomp-profile` | `autogen-seccomp-profile` | `autogen-cronjob-seccomp-profile` |
   | `require-readonly-rootfs` | `readonly-root-filesystem` | `autogen-readonly-root-filesystem` | `autogen-cronjob-readonly-root-filesystem` |
   | `disallow-host-namespaces` | `host-namespaces` | `autogen-host-namespaces` | `autogen-cronjob-host-namespaces` |
   | `restrict-hostpath` | `hostpath` | `autogen-hostpath` | `autogen-cronjob-hostpath` |

   The exception's `kinds` must include the controller kind (and `Job` and `Pod` when it matches `CronJob`), and its `names` or `selector` must match the controller's own name and labels; use a wildcard (`name*`) for the Jobs and Pods controllers create. An exception that matches `Pod` only keeps working for bare Pods.

2. **Workloads that were already broken.** A controller whose Pods were denied before is now denied itself when it is created. Running Pods are not evicted. An update of a controller that already violates the policy is still accepted, because the rules keep Kyverno's default `allowExistingViolations: true` (v1.19.1), so Flux keeps reconciling it; its Pods stay denied as before. Background policy reports list it as failing under the autogen rule. Find these controllers before you upgrade by running the release's policies against what the cluster holds, from a checkout of the release:

   ```bash
   kyverno apply policies/ --cluster
   ```

   After the upgrade, the PolicyReports list them under the autogen rule names:

   ```bash
   kubectl get policyreports -A
   ```

   Controllers whose Pods are being denied also leave `FailedCreate` events, a quick hint:

   ```bash
   kubectl get events -A --field-selector reason=FailedCreate
   ```

   Fix the manifest (or add a scoped exception) so its Pods comply; the controller then passes too.

3. **Check.** On a checkout of the release, with your manifests and exceptions:

   ```bash
   kyverno apply policies/ -r <your-manifests> --exception <your-exceptions>
   make policy-test
   ```

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

### Method 1: Git Tag (clean host required when the pins change)

Use this when upgrading the Foundations repository directly to a release that changes the k3s or Kyverno pin. Run it on a clean host after uninstalling the previous cluster. For a release with the same pins, move the GitRepository ref instead (see the [Overview](#overview)).

```bash
# Uninstall current cluster first
./bootstrap/uninstall.sh

# Check out the target release and reinstall
git fetch --tags
git checkout vX.Y.Z
./bootstrap/install.sh
./bootstrap/verify.sh
```

### Method 2: Customer Instance (clean host required when the pins change)

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
- In 2.x, any change to the k3s or Kyverno version requires a clean reinstall. `install.sh` detects version mismatches and refuses to continue. A release with the same pins is applied in place by moving the GitRepository ref.

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
