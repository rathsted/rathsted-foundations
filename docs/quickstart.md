# Quickstart

This quickstart is easiest to follow if you start with one rule:

- `make doctor`, `make configure`, and `make validate-config` are workstation tasks
- `./bootstrap/install.sh` and `./bootstrap/verify.sh` are Linux host tasks (the k3s installer checksum is pinned in the script)

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
5. On the target Linux host, run `./bootstrap/install.sh`.
   The k3s installer checksum is pinned in the script. Override with
   `RATHSTED_K3S_INSTALLER_SHA256` if the upstream installer changes.
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

## 4) Install On The Target Linux Host
```bash
./bootstrap/install.sh
```

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
3. Create a Linux VM with at least 4 CPU / 8 GB RAM / 20 GB disk.
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

If you ran `make configure` with your own image, the policies and deployment manifest are already pointed at it.

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

The baseline intentionally does not include multi-tenant primitives (NetworkPolicies, per-tenant RBAC, ResourceQuotas). If your deployment model requires shared clusters, add these before exposing workloads to untrusted tenants.

## Notes
- `RATHSTED_GIT_SSH_KEY` must contain the private key contents (not a file path).
- By default, GitOps sync uses your `origin` remote. Override with `RATHSTED_GIT_URL`.
- `bootstrap/verify.sh` checks cluster health, signature policy, and policy enforcement. It fails on core cluster errors, missing signature policies, and policy-negative tests.
- Release-grade checks require registry reachability. Set `RATHSTED_DEMO_IMAGE` to an image you can pull and have signed.
- Pinned component versions are listed in `docs/versions.md`.

## Related Docs

- [Overview](overview.md)
- [Versions](versions.md)
- [Upgrade Guide](upgrade-guide.md)
- [Supply Chain](supply-chain.md)
