# Changelog

All notable changes to Rathsted Foundations will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [2.2.0] — 2026-11-20

### Breaking / action required
- `install.sh` checks the release as well as the distribution, and refuses
  anything outside the supported list (for example Ubuntu 20.04 or 25.10,
  Debian 11, Rocky 8, or an os-release without `VERSION_ID`), and no longer
  accepts CentOS Stream. It used to accept any version of a supported
  distribution and any CentOS, so re-running it on such a host now stops at
  OS detection. Move the host to a supported release first.

### Added
- Host support for Ubuntu 26.04 LTS, Debian 13 (trixie) and Rocky Linux,
  AlmaLinux and RHEL 10, alongside Ubuntu 22.04/24.04, Debian 12 and EL9.
  Ubuntu 26.04 (also CIS-hardened), Debian 13 and Rocky Linux 10 passed the
  arm64 and x86_64 runs on 2026-11-19 (details per release in
  `docs/versions.md`). The supported list lives in `bootstrap/lib/os.sh`, which `install.sh` and
  `make doctor` share.
- On EL10, when the running distribution kernel cannot resolve `nft_compat`
  and `xt_conntrack`, `install.sh` installs the modules-extra build of that
  kernel's package (`kernel-modules-extra`, `kernel-64k-modules-extra`, ...)
  before k3s. RHEL 10 moved those modules there. The 2026-11-19 x86_64
  Rocky 10 run installed it; the SELinux policy k3s installs there is
  upstream's el9 k3s-selinux build, as k3s has no stable el10 one.
- `verify.sh` records the host's SELinux mode (`getenforce`, or "not
  present") and Secure Boot state in its Environment section, so compat
  evidence carries both.

### Fixed
- `install.sh` names the `RATHSTED_*` settings, and any proxy (`http_proxy`,
  `https_proxy`, `no_proxy` in either case) or CA bundle (`SSL_CERT_FILE`,
  `SSL_CERT_DIR`, `CURL_CA_BUNDLE`) settings, that are set in
  `--preserve-env=` when it re-runs itself with sudo. `sudo-rs`, the default
  sudo on Ubuntu 26.04, ignores a bare `-E`, so pins, the GitOps URL and the
  Git credentials would not reach the root pass there. Only names go on the
  command line, never values.

## [2.1.0] — 2026-11-19

**Pin before this release reaches your cluster.** An install from a checkout
that was not exactly on a tag pins Flux to `branch: main` of its Git source.
If that source is the public repository, Flux applies this release as soon as
it is published, before the steps below. Pin to the release you run first:

```bash
kubectl -n flux-system patch gitrepository rathsted-foundations --type merge -p '{"spec":{"ref":{"branch":null,"tag":"v2.0.2"}}}'
```

or re-run the installer from a checkout of the tag you run (`git checkout v2.0.2`)
with `RATHSTED_GIT_REF="tag: v2.0.2"`; not from newer code, which would
apply this release's policies. Then follow
Breaking / action required and Migration below. Flux applies `policies/` from
the Git source, so keeping policies rendered by `make configure` requires a
fork that carries them in `policies/`.

### Breaking / action required
- PolicyExceptions on Pod controllers. An exception that matches a
  Deployment, StatefulSet, DaemonSet, Job, ReplicationController or CronJob
  and names a rule of `disallow-privileged`, `drop-all-capabilities`,
  `require-seccomp`, `require-readonly-rootfs`, `disallow-host-namespaces` or
  `restrict-hostpath` must add the generated rule names, `autogen-<rule>`
  (and `autogen-cronjob-<rule>` for a CronJob), or the controller is denied.
  The full table is in "Pod controllers are checked at admission" in
  `docs/upgrade-guide.md`.
- A controller that violates one of those six policies is now denied when it
  is created, by `kubectl apply` and by Flux's dry run. Before, it was
  admitted and only its Pods were denied. A Flux Kustomization of your own
  that carries such a controller goes not Ready with the policy message, and
  applies nothing else in its tree until the controller is fixed or excepted.
  Updates of a controller that already exists are still admitted. Find them
  before upgrading with `kyverno apply policies/ --cluster` from a checkout of
  the release.
- `verify.sh`, without `--release`, has new FAIL paths:
  - `rathsted-sync` is not Ready, has no applied revision, or is suspended
    (when GitOps is configured);
  - the live `require-namespace-labels` policy has no readable operator-control
    stamp, or `flux-system/rathsted-foundations-contract` or `rathsted-sync`
    cannot be read (an error other than NotFound);
  - the namespace label audit cannot run;
  - a namespace lacks the jurisdiction labels while the contract records a
    jurisdiction (`r3_jurisdiction`), `RATHSTED_JURISDICTION` is set in
    verify's environment, or `flux-system`, `kyverno` or `default` declares
    one; the platform namespaces then must also declare that jurisdiction;
  - `flux-system`, `kyverno` and `default` declare different jurisdictions and
    none is recorded or set, or `RATHSTED_JURISDICTION` differs from the
    recorded one;
  - the stamped operator-control differs from `RATHSTED_OPERATOR_CONTROL` or
    the recorded `r3_operator_control`, those two differ, or
    `RATHSTED_OPERATOR_CONTROL` is not one of the four values.

  With nothing recorded, set or declared, label gaps only warn, as before.
- `make verify-release` fails until the labels are backfilled: every namespace
  other than `kube-system`, `kube-public` and `kube-node-lease` needs `owner`,
  `environment`, `rathsted.io/jurisdiction` and the stamped
  `rathsted.io/operator-control`. Installs from v2.0.2 and earlier left
  `flux-system`, `kyverno` and `default` without them; run
  `make jurisdiction-audit` and backfill as in "Labelling the platform
  namespaces on an existing 2.x install" in `docs/upgrade-guide.md`.
- Policies rendered by `make configure` no longer last on a GitOps install.
  Flux now applies `policies/` from your Git source (it did not before; see
  Fixed), so at its first reconcile on this release `rathsted-sync` replaces
  the installer-applied `restrict-registries` and `require-signed-images`
  with the ones in Git, and pods from your registry are denied from their next
  creation. A `branch: main` tracker is hit as soon as the release is
  published; a tag-pinned cluster when its ref moves. Commit
  `config/rendered/restrict-registries.yaml` and
  `config/rendered/require-signed-images.yaml` to `policies/` in a fork that
  Flux tracks first.
- A GitOps URL with embedded credentials (`https://user:token@host/...`) is
  refused before the install changes anything: `RATHSTED_GIT_URL` for both
  installers, and for `install.sh` the `origin` remote it falls back to. The
  installers wrote that URL into the Flux GitRepository spec, where anyone
  who can read the object sees the token. Set a clean `RATHSTED_GIT_URL` and
  pass the token in `RATHSTED_GIT_TOKEN`, which becomes a Secret. SSH URLs
  (`git@host:org/repo`, `ssh://git@host/...`) are not affected.

### Added
- `components/operator-control/<value>` (`customer`, `domestic-provider`,
  `foreign-provider`, `rathsted`): one kustomize Component per
  operator-control value, so a GitOps fork can carry its own stamp. Add
  `components: - ../../../components/operator-control/<value>` to
  `cluster/gitops/apps/kustomization.yaml`, commit, push, and install with
  `RATHSTED_OPERATOR_CONTROL=<value>`; Flux keeps the value at every
  reconcile. Enable exactly one. The installer reads that file at the commit
  GitOps will apply (with `git show`; no `kubectl` needed) and stops, with
  nothing applied, if more than one is listed, the value is unknown, the
  component file is missing or patches another value, the entry is written in
  any other form, or the file patches the stamp some other way. With no
  component listed it checks the policy literal, as before. Changed for a
  declared install: since the installer reads the file as text, it now also
  stops on a duplicate top-level key, a second YAML document, an apps
  kustomization key other than `apiVersion`, `kind`, `resources`,
  `components` and `images`, any other entry under `components:` next to the
  operator-control one, or a `policies/kustomization.yaml` with a top-level
  key other than `apiVersion`, `kind` and `resources`. With
  `RATHSTED_OPERATOR_CONTROL` unset on a GitOps install and a component
  enabled in your checkout, the install stops and names the value to set. See
  `docs/operator-control-components.md`. The tracked default stays
  `foreign-provider`.
- `RATHSTED_JURISDICTION` (`ca`, `us` or `fr`) for `bootstrap/install.sh` and
  `bootstrap/install-managed.sh`. When set, the installer labels the namespaces
  Foundations owns (`flux-system`, `kyverno`, `default`) with `owner=platform`,
  `environment=platform` (only where absent), `rathsted.io/jurisdiction` and
  the `rathsted.io/operator-control` value the live policy stamps, after the
  policies are in place, and records the jurisdiction as `r3_jurisdiction` in
  the `flux-system/rathsted-foundations-contract` ConfigMap. A platform
  namespace that already declares a different jurisdiction stops the install
  with nothing written. Any value other than `ca`, `us` or `fr` stops the
  install before it changes anything. Unset, nothing is labelled and the
  installer warns, naming the namespaces and the command to label them. Found
  on a fresh v2.0.2 install (2026-11-08 UTC): those three namespaces had no jurisdiction labels, so the cluster did not
  meet "every namespace in one convention".
- Declared `rathsted.io/operator-control`. Limitation first: with GitOps
  (`install.sh` always, `install-managed.sh` when `RATHSTED_GIT_URL` is set)
  Flux re-applies `policies/` from your Git source at every reconcile, so the
  stamped value is the one committed there; change it by committing a new
  `rathsted.io/operator-control` literal to `policies/require-namespace-labels.yaml`
  in that source. The tracked value is `foreign-provider` (the reference
  deployment's), stamped on every non-system namespace the policy admits; it
  is not detected from your cluster.
- `RATHSTED_OPERATOR_CONTROL` (`customer`, `domestic-provider`,
  `foreign-provider` or `rathsted`) for `bootstrap/install.sh` and
  `bootstrap/install-managed.sh` declares that value. On the GitOps paths the
  installer resolves the ref the GitRepository will pin on the GitOps URL
  (`git ls-remote`, with your read access) and reads the policy at that commit
  from your clone; it stops, with nothing applied, labelled or recorded, when
  the literal differs or when it cannot check (no URL, a `semver:` or other
  ref that is not `tag:`, `branch:` or `commit:`, a ref the remote lacks, a
  commit not fetched, no clone, or a literal it cannot read). Without
  GitOps, `install-managed.sh` applies the policies with the declared value (a
  kustomize patch over a copy of `policies/`; the tracked files are
  unchanged). Either way the installer checks the live policy stamps it and
  records it as `r3_operator_control` in
  `flux-system/rathsted-foundations-contract`, before labelling the platform
  namespaces. Any other value stops the install before it changes anything.
  Unset, the install behaves as before and warns, naming the stamped value
  (and, if an earlier install recorded another value, how to remove that
  record; `docs/upgrade-guide.md`).
- The installers read the GitOps URL and ref from git with
  `safe.directory` set to the checkout. With `RATHSTED_OPERATOR_CONTROL` unset
  this changes one case: run as root without sudo on a checkout another user
  owns, `install.sh` now finds `origin` and the tag HEAD is on (before, git
  refused the checkout, so the install stopped with "No git remote found"
  unless `RATHSTED_GIT_URL` was set, and pinned `branch: main`).
- `verify.sh` reports the stamped operator-control: it warns when no operator
  declared it (also under `--release`) and while `rathsted-sync` has not
  applied a revision, and fails when the stamp differs from
  `RATHSTED_OPERATOR_CONTROL` in its environment or the recorded
  `r3_operator_control`, when those two differ, or when either cannot be read.
- `make jurisdiction-audit` (`bootstrap/jurisdiction-audit.sh`): read-only
  list of every namespace with its jurisdiction labels; exits 1 if any namespace other
  than `kube-system`, `kube-public` and `kube-node-lease` lacks them or carries
  an operator-control other than the stamped value, 2 if it cannot read the
  namespaces or the policy. `verify.sh` runs it: a gap fails when the install
  recorded a jurisdiction, when `RATHSTED_JURISDICTION` is set, or under
  `--release`, and warns otherwise; an audit that cannot run fails.

- Multi-node topology contract `managed-3-node-v1`. `bootstrap/lib/contract.sh`
  renders the `flux-system/rathsted-foundations-contract` marker with
  `topology_mode`, `topology_support_level`, `supported_node_min` and
  `supported_node_max`. The default stays `single-node` (`baseline`, 1-1
  nodes). `FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1` with
  `bootstrap/install-managed.sh` publishes `bounded`, 3-3 nodes: exactly 3
  nodes, the managed install path only, and no HA, failover or node-loss
  survivability claim. `FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL`,
  `FOUNDATIONS_SUPPORTED_NODE_MIN`, `FOUNDATIONS_SUPPORTED_NODE_MAX` and
  `FOUNDATIONS_MULTI_NODE_FOUNDATIONS_SUPPORTED` may state what the caller
  expects; a value that does not match the mode, or an unknown mode, is
  refused, not published. `install-managed.sh` checks the live node count in
  preflight, before Flux or Kyverno are installed, and refuses
  `managed-3-node-v1` unless the cluster has exactly 3 nodes. `install.sh`
  always publishes `single-node`. `verify.sh` prints `Cluster nodes` and
  `Topology support`, and fails when the node count is outside a multi-node
  contract's range; outside the single-node baseline it only warns, as
  before. See `docs/overview.md` and `docs/multi-node-design.md`.
  `scripts/test-topology-contract.sh` and `scripts/test-bootstrap-guards.sh`
  now ship and run without a cluster, in `make bootstrap-test` and in CI.

### Changed
- GitOps layout: `rathsted-sync` keeps its name, path
  (`./cluster/gitops/apps`) and `prune: true`, and that tree now holds only
  the policies plus `hello-gitops-registry-exception` (a PolicyException in
  `kyverno` for the demo's Docker Hub image: namespace `demo`, names
  `hello-gitops` and `hello-gitops-*`, image `nginx:1.29.7-alpine` only, the
  `restrict-registries` rules only). The demo app moved
  to `cluster/gitops/workloads`, reconciled by the new Flux Kustomization
  `rathsted-apps` (`dependsOn: rathsted-sync`, `prune: true`), so a denied
  workload can no longer block the policies. Put your own workloads there.
  `make flux-reconcile` reconciles both. Existing clusters: re-apply
  `cluster/gitops/sync/kustomization.yaml` to add `rathsted-apps` and move
  the GitRepository ref to the release tag (or re-run the release's
  installer, which does both), and check what `rathsted-sync` owns first; see
  "Splitting the policies from the workloads" in `docs/upgrade-guide.md`.
  If you ran `make configure`, Flux now also replaces its rendered
  `restrict-registries` and `require-signed-images` with the ones in Git at
  the first reconcile: carry them in your GitOps source first.
  On a GitOps install, `install.sh` (and `install-managed.sh` with
  `RATHSTED_GIT_URL`) now warns after applying `config/rendered/` when those
  files differ from `policies/` at the commit GitOps will apply. When it
  could only compare with your checkout's local HEAD and found no
  difference, it says so in one line: unpushed commits are not seen.
- `make verify-release` (`verify.sh --release`) now fails when any namespace
  other than `kube-system`, `kube-public` and `kube-node-lease` lacks the
  jurisdiction labels. `verify.sh` without `--release` fails the same way when the install
  recorded a jurisdiction or a platform namespace declares one (if
  `flux-system`, `kyverno` and `default` declare different ones and none is
  recorded or set, it fails), and warns otherwise. On an existing 2.x install, run `make jurisdiction-audit` and
  backfill before `make verify-release` (`docs/upgrade-guide.md`).
- `RATHSTED_LABEL_ATTEMPTS` (1-20, default 3) and `RATHSTED_LABEL_DELAY`
  (0-300 seconds, default 5) set the label retries; other values stop the
  install before it changes anything.

### Fixed
- Flux applies the policies again. From v2.0.0 to v2.0.2 the one Flux
  Kustomization, `rathsted-sync`, built the ClusterPolicies together with the
  demo app; Flux dry-runs that as one batch, `restrict-registries` denied the
  demo Deployment (`nginx` from Docker Hub), and `rathsted-sync` never became
  Ready, so it never applied the policies. A deleted or edited policy was not
  restored, and an operator-control value set only by the installer was not
  reverted to the one in Git. Found on kind, 2026-11-17.
- `verify.sh` now fails when the policies Kustomization, `rathsted-sync`, is
  not Ready. On v2.0.0 to v2.0.2 it passed with `rathsted-sync` permanently
  Ready=False, because it only listed the Flux Kustomizations. With GitOps
  configured, `rathsted-sync` must be Ready with a `lastAppliedRevision`
  (compared with its GitRepository's artifact revision; behind it warns,
  fails under `--release`); not Ready, no applied revision, or suspended
  fails in every mode and prints the Ready condition's message.
  `rathsted-apps` (the workloads) not Ready or suspended warns, and fails
  under `--release`. A self-hosted install without `rathsted-sync` warns
  (fails under `--release`). Verify waits first, up to
  `RATHSTED_GITOPS_READY_ATTEMPTS` checks (default 24)
  `RATHSTED_GITOPS_READY_DELAY` seconds apart (default 5). Without Flux's
  CRD, or on `install-managed.sh` without `RATHSTED_GIT_URL`, nothing changes.
- `require-namespace-labels` excludes `kube-system`, `kube-public` and
  `kube-node-lease` by name in both rules. Kyverno's `resourceFilters` kept them
  out of admission only, so background PolicyReports listed them as failing;
  the policy comment said they were excluded cluster-wide.
- Pod controllers are denied at admission. `disallow-privileged`,
  `drop-all-capabilities`, `require-seccomp`, `require-readonly-rootfs`,
  `disallow-host-namespaces` and `restrict-hostpath` listed Pod and the
  controllers in one rule, which disables Kyverno autogen, so on a
  Deployment, StatefulSet, DaemonSet, Job or CronJob the rule read the
  controller's own `spec` (no containers, `hostNetwork` or `volumes`) and
  admitted it; only its Pods were denied later. The rules now match Pod only
  and the policies set `pod-policies.kyverno.io/autogen-controllers:
  DaemonSet,Deployment,Job,StatefulSet,ReplicationController,CronJob`, so
  Kyverno checks the pod template under `autogen-<rule>` and
  `autogen-cronjob-<rule>`. Behaviour
  change: a non-compliant controller is now refused by `kubectl apply` and by
  Flux, and a PolicyException that matches a controller must name the autogen
  rules. `examples/customer-instance` example-app now sets a seccomp profile;
  it was admitted before while its Pods were denied. Found 2026-11-18.
- `verify.sh --release`: the vulnerability gate no longer aborts with
  `fail: command not found`. A blocked or missing scan called `fail`, which
  only `install.sh` defines, so verify died there without printing its
  Summary. It now warns, sets FAIL and carries on to the Summary.

### Migration
- Branch trackers: pin first (see the note at the top of this entry).
- Existing installs: backfill the platform namespace labels in place, see
  `docs/upgrade-guide.md`. Do this before the next `make verify-release`.
- PolicyExceptions that match a Deployment, StatefulSet, DaemonSet, Job,
  ReplicationController or CronJob and name a rule of the six policies above must add the autogen rule
  names; see "Pod controllers are checked at admission" in
  `docs/upgrade-guide.md`.
- Moving a tag-pinned install to this release: re-applying
  `cluster/gitops/sync/kustomization.yaml` adds `rathsted-apps` but does not
  move the GitRepository, so `rathsted-sync` stays on the old tree. After
  steps 1 to 3 of "Splitting the policies from the workloads" in
  `docs/upgrade-guide.md`, apply the sync objects and move the ref to the
  release tag:
  `kubectl -n flux-system patch gitrepository rathsted-foundations --type merge -p '{"spec":{"ref":{"tag":"vX.Y.Z"}}}'`.
  Or re-run the release's installer from a checkout of its tag, which does
  both (same k3s and Kyverno pins as v2.0.2).

## [2.0.2] — 2026-10-16

Documentation and evidence only; nothing that runs on a host changed.

### Added
- x86_64 evidence for every validated host: Debian 12, Rocky Linux 9, Ubuntu
  22.04, Ubuntu 24.04 and Ubuntu 24.04 CIS each pass the full install-and-verify
  run (36 passed, 0 failed) on x86_64, in a Hyper-V virtual machine with Secure
  Boot on, built from the distribution's official cloud image. See
  `artifacts/*-amd64.txt` and `artifacts/compat-latest-amd64.json`.

### Changed
- `docs/versions.md` records those five hosts as validated on both arm64 and
  x86_64. Previously only Ubuntu 22.04 and 24.04 were validated on x86_64.

## [2.0.1] — 2026-10-10

### Security
- `install.sh` now verifies what it downloads. **No earlier public release
  (v1.0.0–v2.0.0) did**, although the README and quickstart said the k3s installer
  checksum was pinned. A regression before v1.0.0 removed the checks; they are
  restored:
  - the k3s installer script is fetched from the k3s release tag and verified
    against a sha256 pinned in `install.sh` before it runs (no `curl | sh`);
  - Flux, Cosign, Syft and Grype are downloaded as release archives/binaries and
    verified against the checksums file in the same GitHub release (Syft and Grype
    were previously installed by scripts from their `main` branch);
  - every download uses `--fail --proto '=https' --tlsv1.2`;
  - GitHub SSH host keys are pinned instead of fetched with `ssh-keyscan`.
  See `docs/known-risks.md` for what this does and does not prove.
- `require-non-root` rejects containers that override the pod's setting with
  `runAsNonRoot: false` or `runAsUser: 0` (containers, initContainers and
  ephemeralContainers). Previously a container could run as root.
- The k3s audit policy logs Secrets at `Metadata` level. It previously logged
  Secret request bodies, so Secret data (including the Git credentials bootstrap
  stores) was written to the audit log.
- `install-managed.sh` always applies the full baseline. When `config/rendered/`
  existed it applied only the two rendered policies and skipped the other eleven.
- Git credentials are written to private temporary files for `kubectl`, not passed
  as command-line arguments.

### Changed
- PolicyExceptions are enabled, restricted to the `kyverno` namespace
  (`--exceptionNamespace=kyverno`): only exceptions there take effect, so a tenant
  cannot exempt itself. They were disabled before while the contract reported them
  as supported, so the app-runtime profile's exception was ignored; it now lives in
  `kyverno`. See `docs/policy-exceptions.md`.
- `install.sh` and `install-managed.sh` refuse to run over a cluster whose installed
  k3s or Kyverno version differs from the pins. In-place upgrades are not supported
  in 2.0.x; reinstall on a clean host (`docs/upgrade-guide.md`). Previously
  re-running bootstrap silently skipped installed components, so a 1.x cluster kept
  Kyverno v1.12.3.

### Fixed
- **Install works on stock hosts.** `cluster/k3s/config.yaml` enables
  `protect-kernel-defaults`, so the kubelet refuses to start unless six kernel
  parameters are already set; install never set them, so on a stock Ubuntu,
  Debian or Rocky host k3s came up without a node and install failed. Earlier
  releases have the same defect; our compatibility VMs shipped those values
  pre-set, which hid it. Install now writes and applies
  `/etc/sysctl.d/90-kubelet.conf` before starting k3s (values in
  `docs/quickstart.md`; note `kernel.panic=10` reboots the host 10 seconds after
  a kernel panic), and the compatibility tests reset VMs to stock kernel values
  first.
- Install waits for the Kubernetes API and a Ready node before installing Flux.
  On fast hosts `flux install` previously ran before the API was ready and failed.
- `make configure` and `make validate-config` work: their scripts now ship.
- `install.sh` applies the registry/signature policies `make configure` renders.
  They currently last until Flux's next reconcile, which restores the defaults from
  git; see the quickstart note. A tracked-overlay workflow is planned.
- Docs describe the 2.0 namespace labels (`rathsted.io/jurisdiction`), not the 1.x
  `jurisdiction` label.
- `docs/security-testing.md` no longer presents maintainer-only CI scripts as part
  of this repository.
- `cluster/sovereignty/rathsted-sovereignty.yaml` says what it is: Rathsted's own
  reference values, not installed by default.
- `install-managed.sh` GitOps bootstrap no longer fails rendering the GitRepository
  template.
- `verify.sh --release` runs the positive admission tests (it skipped them).
- Two policy test assertions named rules that do not exist and passed without
  testing anything; they now test the real rules. A new test covers the root
  override.
- The public nightly workflow renders a valid GitRepository (`REPLACE_GIT_REF`).
- Four docs had not been updated in this repository since v1.0.0 and are current
  again: `docs/offline.md`, `docs/policy-exceptions.md`, `docs/profiles.md` and
  `docs/sovereign-toolchain-inventory.md`. The 2.0.0 copy of
  `docs/policy-exceptions.md` predates PolicyExceptions being enabled.
- Docs: links to unpublished docs fixed, maintainer-only `make` targets marked as
  such, NetworkPolicy scope (default-deny in every new application namespace),
  encryption at rest (enabled), hardware requirements, and current-version
  references.

## [2.0.0] — 2026-10-06

### Changed (BREAKING)
- Namespaces must declare `rathsted.io/jurisdiction` set to `ca`, `us` or `fr`; a
  missing or other value is rejected at admission. The bare `jurisdiction` label,
  which 1.x required with any value, no longer counts. Existing namespaces labelled
  the 1.x way are rejected on their next create or update until relabelled.
- `rathsted.io/operator-control` is stamped on namespaces at admission (system
  namespaces excluded). Do not set it yourself; the platform overwrites it.
- The Foundations contract reports `foundations_series: "2.x"`. Tooling that checks
  for `1.x` must accept `2.x`.
- 1.x is no longer supported; see `SECURITY.md`.

### Migration
- Relabel every namespace before upgrading:
  `jurisdiction: <v>` → `rathsted.io/jurisdiction: <ca|us|fr>`. See
  `docs/upgrade-guide.md`.

### Changed
- Component versions: k3s v1.35.9+k3s1, Kyverno v1.19.1, Flux 2.9.6, Cosign v3.1.3, Syft v1.54.0, Grype v0.120.0.

### Fixed
- 1.x installed Kyverno v1.12.3 from a vendored manifest while documenting v1.17.1 (including v1.0.3). 2.0.0 vendors and installs v1.19.1, uses the vendored manifest only when it matches the pin, and verify records the Kyverno images actually running.
- `install.sh` no longer reports success when the baseline policies fail to apply.
  A failed apply (for example while Kyverno is still starting) is retried, the
  install checks every policy is actually in the cluster, and it stops with an error
  if they are not.
- `verify.sh` fails, and names what is missing, when any baseline policy is absent.
  It previously reported "Kyverno policies present" on a cluster with none.
- Baseline policies match `Pod` only and rely on Kyverno autogen; applying a compliant
  Deployment with `kubectl` no longer fails at `/spec/containers/`.
- `require-probes` exempts run-to-completion workloads (Jobs, CronJobs, their pods),
  keyed on `restartPolicy`. Long-running enforcement is unchanged.
- Flux `GitRepository` pinned to the release tag, not `main`.
- Kyverno policies reconciled by Flux; drift self-heals.
- Contract marker reports the real single-node topology.
- Registry allowlist scoped to the signed prefix; digest mutation on; CI asserts the
  enforced key equals the published `cosign.pub`.
- Grype scan is a release gate.

## [1.0.3] — 2026-06-10

### Changed
- Internal improvements only

## [1.0.2] — 2026-05-04

### Changed
- Internal improvements for CI

## [1.0.1] — 2026-05-03

### Changed
- Close absent-field and empty-drop gaps.
- Scope foundations multi-node substrate.

### Fixed
- Align app-runtime postgres uid with alpine image.
- Match Pod only and let Kyverno autogen handle controllers.

## [1.0.0] — 2026-04-21

### Added

- First stable public release: single-node k3s baseline with Flux GitOps, Kyverno policies, Cosign signing, and Syft SBOM workflows.
- Supported hosts: Ubuntu 22.04, Ubuntu 24.04, Ubuntu 24.04 CIS, Debian 12, Rocky Linux 9, RHEL 9, and AlmaLinux 9 — compatibility evidence published.
- Customer instance template under `examples/customer-instance/`.
- `SECURITY.md` for coordinated vulnerability disclosure.
- Fresh public repository history rooted at this release (no inherited private commit graph).

### Changed

- Example GitOps workload and policy test fixtures reference a public `nginx` image; operators point `make configure` at their own registry and sign the images they run.
- Public snapshot published from the curated release commit; scope boundaries and non-goals documented in the public README.

### Notes

- `v1.0.0` is intentionally narrow: stable single-node baseline, not multi-node HA, not a certification product.
