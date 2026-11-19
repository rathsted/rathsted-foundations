# Quickstart

This quickstart is easiest to follow if you start with one rule:

- `make doctor`, `make configure`, and `make validate-config` are workstation tasks
- `./bootstrap/install.sh` and `./bootstrap/verify.sh` are Linux host tasks (the k3s installer script is downloaded from the release tag and verified against a sha256 pin in the script)

Foundations always runs on Linux. Your local machine can be macOS, Linux, or Windows with WSL, but the actual cluster install happens on the Linux machine that will host `k3s`.

## Choose Your Starting Point

Use the path that matches how you are evaluating the repo:

- **I already have a Linux host for Foundations**: use the standard path below
- **I am on macOS and just want to evaluate locally**: create a Linux VM first, then use the standard path
- **I am on Windows**: use WSL for workstation tasks, and a Linux host or Linux VM for install and verify

## Standard Path

1. Clone the repo on your workstation.
2. Run `make doctor`.
3. Run `make configure`.
4. Optionally run `make validate-config`.
5. On the target Linux host, run `./bootstrap/install.sh`, with
   `RATHSTED_JURISDICTION` set to `ca`, `us` or `fr` so the platform namespaces
   get the jurisdiction labels (see Notes). The operator-control value comes from your
   Git source's `policies/require-namespace-labels.yaml` (see Notes).
   The k3s installer script is downloaded from the k3s release tag and verified
   against a sha256 checksum pinned in the script before it runs. Override the
   checksum with `RATHSTED_K3S_INSTALLER_SHA256` when deliberately changing the
   k3s version.
6. On the target Linux host, run `./bootstrap/verify.sh`.

## Prerequisites

### Workstation Requirements

These are for the machine where you prepare config and review the repo:

| Tool | Required | Notes |
|------|----------|-------|
| `bash` | yes | |
| `curl` | yes | |
| `git` | yes | |
| `make` | yes | |
| `python3` | yes | For configuration rendering and validation |
| `pyyaml` | yes | `pip install pyyaml` — used by `make validate-config` |
| `kubectl` | no | Installed by `install.sh` via k3s |
| `cosign` | no | Installed by `install.sh`; needed for supply-chain steps |
| `docker` | no | Needed for local image workflows |

Run `make doctor` to verify your environment before starting.

### Target Host Requirements

These are for the Linux machine that will actually run Foundations.

See [README](../README.md#target-host-requirements) for supported platforms and minimum specs.

## 1) Clone The Repo On Your Workstation
```bash
git clone https://github.com/rathsted/rathsted-foundations
cd rathsted-foundations
```

## 2) Check Workstation Prerequisites
```bash
make doctor
```

## 3) Configure Your Registry And Image

Set your image registry and workload image. This renders the Kyverno policies for your environment:

```bash
make configure
```

You will be prompted for:
- **Registry prefix** — where your workload images live (e.g. `ghcr.io/your-org`, `registry.example.com/team`)
- **Workload image** — the image used by the demo deployment and supply-chain verification

To run non-interactively (pass flags to `configure.sh`; `make configure` does not accept `REGISTRY`/`IMAGE` as make variables):
```bash
./scripts/configure.sh --registry ghcr.io/your-org --image ghcr.io/your-org/your-app:1.0.0 --yes
```

If you are evaluating Rathsted with the default demo image, you can skip this step and the defaults will be used.

Optional validation before install:
```bash
make validate-config
```

> **A custom registry or signing key needs a fork, set up before install.**
> `install.sh` applies the rendered registry and signature policies once, at
> bootstrap. Flux then applies `policies/` from your Git source at every
> reconcile, and at its first one replaces the rendered `restrict-registries`
> and `require-signed-images` with the ones in Git; pods from your registry are
> then denied. To keep your values, in this order:
>
> 1. Fork the repository and clone your fork (its `origin` is what Flux tracks;
>    `RATHSTED_GIT_URL` overrides it).
> 2. Run `make configure`.
> 3. Copy `config/rendered/restrict-registries.yaml` and
>    `config/rendered/require-signed-images.yaml` over the files of the same
>    name in `policies/`, then commit and push.
> 4. Run `./bootstrap/install.sh` from that commit.
>
> Without a fork, Flux tracks the public repository and restores the default
> `ghcr.io/rathsted/*` allowlist. A tracked-overlay workflow is planned.

## 4) Install On The Target Linux Host
```bash
./bootstrap/install.sh
```

Install changes the host, not just the cluster. Before starting k3s it writes
`/etc/sysctl.d/90-kubelet.conf` and applies it: `vm.overcommit_memory=1`,
`vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1`,
`kernel.keys.root_maxkeys=1000000`, `kernel.keys.root_maxbytes=25000000`. The
kubelet refuses to start without them because `cluster/k3s/config.yaml` enables
`protect-kernel-defaults`. They persist across reboots; `kernel.panic=10` means
the host reboots 10 seconds after a kernel panic. Install also places the k3s
binary and systemd unit, the audit policy under `/var/lib/rancher/k3s/server/`,
and the Flux, Cosign, Syft and Grype binaries in `/usr/local/bin`.

## 5) Verify On The Target Linux Host
```bash
./bootstrap/verify.sh
```

This will also attempt to apply an intentionally bad manifest and confirm it is blocked by policy.

## Local Setup By Operating System

### macOS

Use macOS as the workstation only. Create a Linux VM for the actual install.

Typical flow:

1. Clone the repo on macOS.
2. Run `make doctor` and `make configure` on macOS.
3. Create a Linux VM (minimum 2 CPU / 4 GB RAM, recommended 4 CPU / 8 GB RAM, 20 GB disk).
4. Copy the repo to the VM or clone it again inside the VM.
5. Run `./bootstrap/install.sh` and `./bootstrap/verify.sh` inside the VM.

If you want the simplest evaluation path, do all steps inside the Linux VM after cloning there.

### Linux Workstation

If your workstation is already a supported Linux machine and it will also host Foundations, you can do the full flow in one place:

```bash
git clone https://github.com/rathsted/rathsted-foundations
cd rathsted-foundations
make doctor
make configure
make validate-config
./bootstrap/install.sh
./bootstrap/verify.sh
```

If your Linux workstation is separate from the target host, use it only for workstation tasks and run install/verify on the target host.

### Windows With WSL

Use WSL as the workstation environment. Do not use native Windows shell commands for the repo workflow.

Typical flow:

1. Open a WSL shell.
2. Clone the repo inside the WSL filesystem.
3. Run `make doctor` and `make configure` inside WSL.
4. Use a separate Linux host or Linux VM for `./bootstrap/install.sh` and `./bootstrap/verify.sh`.

If you want a local evaluation path on one machine, create a Linux VM and run the host steps there.

## Supply Chain (Optional But Recommended)

If you ran `make configure` with your own image, the deployment manifest is already pointed at it, and the rendered policies are applied at bootstrap (see the fork note in step 3: without it Flux restores the defaults).

Generate a cosign keypair and apply it to the signing policy:

```bash
cosign generate-key-pair
mv cosign.pub supply-chain/cosign/cosign.pub
mv cosign.key supply-chain/cosign/cosign.key
./supply-chain/cosign/update-policy.sh
```

Sign your image and generate an SBOM:
```bash
export IMAGE=registry.example.com/your-app:1.0.0
make sign IMAGE="$IMAGE"
make sbom IMAGE="$IMAGE"
```

Then run `make verify-release` to confirm all supply-chain checks pass.
`verify-release` also requires every namespace to carry the jurisdiction labels. On an
existing 2.x install, run `make jurisdiction-audit` first and backfill anything
it reports as described in the [upgrade guide](upgrade-guide.md#labelling-the-platform-namespaces-on-an-existing-2x-install).

## Offline Or Local Registry (Optional)
To run a fully local demo registry:
```bash
docker run -d -p 5000:5000 --name registry registry:2
export IMAGE=localhost:5000/nginx:1.29.7-alpine
docker pull nginx:1.29.7-alpine && docker tag nginx:1.29.7-alpine "$IMAGE" && docker push "$IMAGE"
```
Or re-run configure with the local registry:
```bash
./scripts/configure.sh --registry localhost:5000 --image localhost:5000/nginx:1.29.7-alpine --yes
```
This renders `config/rendered/` for the local registry without touching tracked files.

## 6) Tear Down (Optional)
```bash
./bootstrap/uninstall.sh
```

## Optional Profile: App Runtime
```bash
kubectl apply -k profiles/app-runtime
```

## Isolation model
Rathsted Foundations follows a **sovereign infrastructure** model: one cluster per workload or team. Isolation comes from having separate nodes, not from sharing one cluster between tenants.

This is a deliberate design choice. In regulated and public-sector environments, a stronger practical isolation boundary for this baseline is separate nodes and clusters. Kubernetes namespace-level multi-tenancy introduces shared kernel, network, and storage attack surfaces that conflict with the auditability and determinism goals of this project. A dedicated single-node k3s instance per team gives you a clean blast radius, simpler compliance scope, and reproducible state — without the complexity of tenant RBAC, NetworkPolicies, and resource quota arbitration.

The baseline generates a default-deny NetworkPolicy in every newly created namespace (except kube-system, kube-public, kube-node-lease, flux-system, kyverno, and default). It does not include per-tenant RBAC, ResourceQuotas, or cross-namespace isolation policy. If your deployment model requires shared clusters, add those before exposing workloads to untrusted tenants.

## Notes
- `RATHSTED_GIT_SSH_KEY` must contain the private key contents (not a file path).
- By default, GitOps sync uses your `origin` remote. Override with `RATHSTED_GIT_URL`. A URL with embedded credentials (`https://user:token@host/...`) is refused, since it would be written into the GitRepository spec; pass the token in `RATHSTED_GIT_TOKEN`.
- `bootstrap/verify.sh` checks cluster health, signature policy, and policy enforcement. It fails on core cluster errors, missing signature policies, and policy-negative tests. With GitOps configured it also checks the two Flux Kustomizations:
  - `rathsted-sync` (the policies) must be Ready with a `lastAppliedRevision`, which is compared with its GitRepository's current artifact revision. Not Ready, no applied revision, or suspended fails in every mode, with the Ready condition's message, since Flux then neither applies nor self-heals the policies. A revision behind the source, or a source revision that cannot be read, warns and fails under `--release`.
  - `rathsted-apps` (the workloads) not Ready or suspended warns, and fails under `--release`: a failing workload should not hide, but it is not the platform's guarantee.
  - A self-hosted install with no `rathsted-sync` warns (fails under `--release`). With no Flux CRD, or `install-managed.sh` without `RATHSTED_GIT_URL`, nothing changes.
  - Verify re-reads each one up to `RATHSTED_GITOPS_READY_ATTEMPTS` times (1 to 120, default 24), `RATHSTED_GITOPS_READY_DELAY` seconds apart (0 to 60, default 5), so a just-installed cluster has about two minutes to reconcile.
- `bootstrap/verify.sh` prints `Cluster nodes:` (the live node count) and, from the contract marker, `Topology:` and `Topology support:` (`baseline` for the `single-node` default, `bounded` for `managed-3-node-v1`). A node count outside a multi-node contract's range fails verify; outside the single-node baseline it only warns. See [Multi-Node Design](multi-node-design.md).
- `RATHSTED_JURISDICTION` (`ca`, `us` or `fr`) tells `install.sh` and `install-managed.sh` which jurisdiction the platform namespaces they own (`flux-system`, `kyverno`, `default`) are in. After the policies are in place, the installer labels them `rathsted.io/jurisdiction=<value>` and `rathsted.io/operator-control` with the value `require-namespace-labels` stamps, sets `owner=platform` and `environment=platform` where those are absent, and records the jurisdiction as `r3_jurisdiction` in the `flux-system/rathsted-foundations-contract` ConfigMap. If any of the three already declares a different jurisdiction, the installer stops and writes nothing. Any value other than `ca`, `us` or `fr` stops the install before it changes anything. Unset, nothing is labelled: the installer prints a warning naming the namespaces and the command to label them. Either way, workload namespaces carry their own labels in Git.
- `rathsted.io/operator-control`: `require-namespace-labels` stamps it on every namespace it admits except `kube-system`, `kube-public` and `kube-node-lease`; namespaces that existed before keep their value until their next update. The tracked policy stamps `foreign-provider`, the value for Rathsted's reference deployment on a foreign-owned provider; it is not detected from your cluster. **With GitOps the value is whatever your Git source's `policies/require-namespace-labels.yaml` says**: `install.sh` always bootstraps GitOps, and `install-managed.sh` does when `RATHSTED_GIT_URL` is set, and Flux re-applies `policies/` from Git at every reconcile. To change it there, commit the new literal to your Git source and install from that commit.
- `RATHSTED_OPERATOR_CONTROL` (`customer`, `domestic-provider`, `foreign-provider` or `rathsted`) declares that value and records it as `r3_operator_control` in `flux-system/rathsted-foundations-contract`, so `verify.sh` checks the stamp against it. On the GitOps paths the installer first finds the commit GitOps will apply: it resolves the ref the GitRepository will pin (`RATHSTED_GIT_REF`, else the tag HEAD is exactly on, else `branch: main`) on `RATHSTED_GIT_URL` (else your clone's `origin`) with `git ls-remote`, which needs your read access to that URL without a prompt (at most 60 s; an HTTPS remote that only `RATHSTED_GIT_TOKEN` can read is refused, since that token goes to Flux, not to git), and reads that commit from your clone: if `cluster/gitops/apps/kustomization.yaml` enables one of the [`components/operator-control/<value>`](operator-control-components.md) components, that component's value is the literal; otherwise the literal in `policies/require-namespace-labels.yaml`. It stops, with nothing applied, labelled or recorded, when the literal there differs, and also whenever it cannot check: no URL, a ref other than `tag:`, `branch:` or `commit:` (for example `semver:`), a ref the remote does not have, a commit your clone has not fetched (or no clone at all), a literal it cannot read (quoted, or set by a kustomize patch elsewhere in your source), or a component entry it cannot use (more than one, an unknown value, a missing component file or one that patches another value, or an entry not written as `- ../../../components/operator-control/<value>` under `components:`), or an apps kustomization it cannot read as text (a duplicate top-level key, a second YAML document, or keys other than `apiVersion`, `kind`, `resources`, `components` and `images`; see the components doc). Then fetch the ref, set `RATHSTED_GIT_REF` to a readable `tag:`, `branch:` or `commit:`, or leave `RATHSTED_OPERATOR_CONTROL` unset. To carry a value other than `foreign-provider` in your fork, add that one entry, commit, push, and install with the same `RATHSTED_OPERATOR_CONTROL`; Flux then keeps it. With the variable unset and a component enabled in your checkout, the install stops and says which value to set. A push to that branch after the install is not covered; `verify.sh` reports it. Only `install-managed.sh` without `RATHSTED_GIT_URL` applies a different value itself (a kustomize patch over a copy of `policies/`; the tracked files are unchanged). Any value outside the four stops the install before it changes anything. Unset, the install behaves as before and prints a warning naming the stamped value. `verify.sh` warns when no operator declared the stamp (under `--release` too), warns in its operator-control check while `rathsted-sync` has not applied a revision (the GitOps check above fails on that separately), and fails when the stamp differs from `RATHSTED_OPERATOR_CONTROL` in its environment or the recorded value. After a change, re-stamp existing namespaces as in `docs/upgrade-guide.md`.
- `make jurisdiction-audit` (or `./bootstrap/jurisdiction-audit.sh`) lists every namespace with `owner`, `environment`, `rathsted.io/jurisdiction` and `rathsted.io/operator-control`, and exits 1 if any namespace other than `kube-system`, `kube-public` and `kube-node-lease` lacks them or carries an operator-control other than the stamped value (2 if it cannot read the namespaces or the policy). It changes nothing. `verify.sh` runs the same audit. It fails on a gap when the install recorded a jurisdiction, when a platform namespace declares one, when `RATHSTED_JURISDICTION` is set in verify's environment, or under `--release`, and then also checks that the platform namespaces declare that jurisdiction; otherwise it warns. It fails whenever the audit cannot run.
- Release-grade checks require registry reachability. Set `RATHSTED_DEMO_IMAGE` to an image you can pull and have signed.
- Pinned component versions are listed in `docs/versions.md`.

## Related Docs

- [Overview](overview.md)
- [Versions](versions.md)
- [Upgrade Guide](upgrade-guide.md)
- [Supply Chain](supply-chain.md)
