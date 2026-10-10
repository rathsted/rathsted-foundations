#!/usr/bin/env bash
set -euo pipefail

# Centralized temp file cleanup
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# Ensure /usr/local/bin is on PATH (not always present on RHEL-family minimal installs)
export PATH="/usr/local/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_CONFIG="${ROOT_DIR}/cluster/k3s/config.yaml"

# Verified download helpers (verify_sha256, checksum_for, download_https)
# shellcheck source=bootstrap/lib/download.sh
source "${ROOT_DIR}/bootstrap/lib/download.sh"

# Cluster readiness helpers (wait_for_api)
# shellcheck source=bootstrap/lib/cluster.sh
source "${ROOT_DIR}/bootstrap/lib/cluster.sh"

# Version pins (overridable via env vars for version matrix testing)
K3S_VERSION="${RATHSTED_K3S_VERSION:-v1.35.9+k3s1}"
KYVERNO_VERSION="${RATHSTED_KYVERNO_VERSION:-v1.19.1}"
FLUX_VERSION="${RATHSTED_FLUX_VERSION:-2.9.6}"
COSIGN_VERSION="${RATHSTED_COSIGN_VERSION:-v3.1.3}"
SYFT_VERSION="${RATHSTED_SYFT_VERSION:-v1.54.0}"
GRYPE_VERSION="${RATHSTED_GRYPE_VERSION:-v0.120.0}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

info() { echo "[rathsted] $*"; }
fail() { echo "[FAIL] $*" >&2; }
step() { printf '\n━━━ %s ━━━\n\n' "$1"; }

apply_foundations_contract_marker() {
  local install_mode="$1"
  local foundations_version contract_version
  foundations_version="$(git -C "${ROOT_DIR}" describe --tags --always 2>/dev/null || echo "untagged")"
  contract_version="v1"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: rathsted-foundations-contract
  namespace: flux-system
data:
  contract_version: "${contract_version}"
  foundations_version: "${foundations_version}"
  foundations_series: "2.x"
  install_mode: "${install_mode}"
  decks_v0_supported: "true"
  policy_exception_support: "true"
  topology_mode: "single-node"
  topology_support_level: "baseline"
  supported_node_min: "1"
  supported_node_max: "1"
EOF
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if require_cmd sudo; then
    exec sudo -E bash "$0" "$@"
  else
    echo "sudo is required to install." >&2
    exit 1
  fi
fi

# OS check
# shellcheck disable=SC1091
. /etc/os-release
case "${ID}" in
  ubuntu|debian)    OS_FAMILY="debian" ;;
  rocky|almalinux|rhel|centos) OS_FAMILY="rhel" ;;
  *)
    echo "Unsupported OS: ${ID}. Supported: Ubuntu 22.04/24.04, Debian 12, Rocky/Alma/RHEL 9." >&2
    exit 1
    ;;
esac
step "1/6  OS Detection"
info "Detected OS: ${ID} ${VERSION_ID} (${OS_FAMILY} family)"
info "Version pins: k3s=${K3S_VERSION} kyverno=${KYVERNO_VERSION} flux=${FLUX_VERSION}"
info "Version pins: cosign=${COSIGN_VERSION} syft=${SYFT_VERSION} grype=${GRYPE_VERSION}"

# arch detection: amd64/arm64 from uname -m
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)           ARCH="amd64" ;;
  aarch64|arm64)    ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: ${ARCH}. Supported: x86_64 (amd64), aarch64 (arm64)." >&2
    exit 1
    ;;
esac

# Dependencies
for bin in curl awk sed git python3; do
  require_cmd "$bin" || { echo "Missing required tool: $bin" >&2; exit 1; }
 done

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Version mismatch guard — compare any already-running components against the pins.
# A fresh host (missing KUBECONFIG, cluster not yet up) returns 0 silently.
# shellcheck source=bootstrap/lib/versions.sh
source "${ROOT_DIR}/bootstrap/lib/versions.sh"
check_installed_versions || { fail "Version mismatch: see above. Reinstall on a clean host."; exit 1; }

step "2/6  k3s"
# Place audit policy where the API server can read it
AUDIT_POLICY="${ROOT_DIR}/cluster/k3s/audit-policy.yaml"
if [[ -f "$AUDIT_POLICY" ]]; then
  mkdir -p /var/lib/rancher/k3s/server
  cp "$AUDIT_POLICY" /var/lib/rancher/k3s/server/audit-policy.yaml
  info "Audit policy installed"
fi

if ! systemctl is-active --quiet k3s; then
  info "Installing k3s..."
  # Download the k3s installer script pinned to the release tag.
  # URL: https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh
  # (the '+' in the version is percent-encoded as %2B for the URL).
  # To recompute K3S_INSTALLER_SHA256 when bumping K3S_VERSION:
  #   K3S_URL="https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION//+/%2B}/install.sh"
  #   curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "${K3S_URL}" \
  #     | sha256sum | awk '{print $1}'
  K3S_INSTALLER_SHA256="${RATHSTED_K3S_INSTALLER_SHA256:-8598e002e61d658fed7b7542fc6d2c66d8da6eae69e088830105d2ee1ffb6d91}"
  K3S_VERSION_URL="${K3S_VERSION//+/%2B}"
  k3s_tmpdir="$(mktemp -d)"
  CLEANUP_DIRS+=("${k3s_tmpdir}")
  download_https \
    "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION_URL}/install.sh" \
    "${k3s_tmpdir}/k3s-install.sh"
  verify_sha256 "${k3s_tmpdir}/k3s-install.sh" "${K3S_INSTALLER_SHA256}"
  chmod 700 "${k3s_tmpdir}/k3s-install.sh"
  # cluster/k3s/config.yaml enables protect-kernel-defaults: true, which causes
  # the kubelet to refuse to start unless the host already has these kernel
  # parameters set (k3s CIS hardening guide).  Write them now, before the
  # installer starts the kubelet, so stock Ubuntu (GitHub x86_64 runners) works.
  info "Writing /etc/sysctl.d/90-kubelet.conf (required by protect-kernel-defaults)"
  cat > /etc/sysctl.d/90-kubelet.conf <<'EOF'
# Required by protect-kernel-defaults: true in cluster/k3s/config.yaml,
# per the k3s CIS hardening guide.
vm.overcommit_memory = 1
vm.panic_on_oom = 0
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.keys.root_maxkeys = 1000000
kernel.keys.root_maxbytes = 25000000
EOF
  # Apply only this file: --system would also reload unrelated host config
  # and abort the install if any of it fails.
  sysctl -p /etc/sysctl.d/90-kubelet.conf >/dev/null || { fail "could not apply /etc/sysctl.d/90-kubelet.conf (kernel parameters required by protect-kernel-defaults)"; exit 1; }
  # The installer script internally verifies the k3s binary against the
  # official sha256sum file for the pinned version.
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="--config ${K3S_CONFIG}" \
    bash "${k3s_tmpdir}/k3s-install.sh"
else
  info "k3s already running"
fi

# Wait for the Kubernetes API to be ready before installing cluster components.
wait_for_api || { fail "Kubernetes API did not become ready; check k3s status"; exit 1; }

step "3/6  Flux + Supply Chain Tools"
if ! require_cmd flux; then
  info "Installing Flux CLI..."
  flux_raw="${FLUX_VERSION#v}"
  flux_asset="flux_${flux_raw}_linux_${ARCH}.tar.gz"
  flux_checksums="flux_${flux_raw}_checksums.txt"
  flux_tmpdir="$(mktemp -d)"
  CLEANUP_DIRS+=("${flux_tmpdir}")
  download_https \
    "https://github.com/fluxcd/flux2/releases/download/v${flux_raw}/${flux_asset}" \
    "${flux_tmpdir}/${flux_asset}"
  download_https \
    "https://github.com/fluxcd/flux2/releases/download/v${flux_raw}/${flux_checksums}" \
    "${flux_tmpdir}/${flux_checksums}"
  flux_hash="$(checksum_for "${flux_tmpdir}/${flux_checksums}" "${flux_asset}")"
  verify_sha256 "${flux_tmpdir}/${flux_asset}" "${flux_hash}"
  tar -xzf "${flux_tmpdir}/${flux_asset}" -C "${flux_tmpdir}" flux
  install -m 0755 "${flux_tmpdir}/flux" /usr/local/bin/flux
fi

# Install Cosign if missing
if ! require_cmd cosign; then
  info "Installing cosign..."
  cosign_asset="cosign-linux-${ARCH}"
  cosign_checksums="cosign_checksums.txt"
  cosign_tmpdir="$(mktemp -d)"
  CLEANUP_DIRS+=("${cosign_tmpdir}")
  download_https \
    "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/${cosign_asset}" \
    "${cosign_tmpdir}/${cosign_asset}"
  download_https \
    "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/${cosign_checksums}" \
    "${cosign_tmpdir}/${cosign_checksums}"
  cosign_hash="$(checksum_for "${cosign_tmpdir}/${cosign_checksums}" "${cosign_asset}")"
  verify_sha256 "${cosign_tmpdir}/${cosign_asset}" "${cosign_hash}"
  install -m 0755 "${cosign_tmpdir}/${cosign_asset}" /usr/local/bin/cosign
fi

# Install Syft if missing
if ! require_cmd syft; then
  info "Installing syft..."
  syft_raw="${SYFT_VERSION#v}"
  syft_asset="syft_${syft_raw}_linux_${ARCH}.tar.gz"
  syft_checksums="syft_${syft_raw}_checksums.txt"
  syft_tmpdir="$(mktemp -d)"
  CLEANUP_DIRS+=("${syft_tmpdir}")
  download_https \
    "https://github.com/anchore/syft/releases/download/${SYFT_VERSION}/${syft_asset}" \
    "${syft_tmpdir}/${syft_asset}"
  download_https \
    "https://github.com/anchore/syft/releases/download/${SYFT_VERSION}/${syft_checksums}" \
    "${syft_tmpdir}/${syft_checksums}"
  syft_hash="$(checksum_for "${syft_tmpdir}/${syft_checksums}" "${syft_asset}")"
  verify_sha256 "${syft_tmpdir}/${syft_asset}" "${syft_hash}"
  tar -xzf "${syft_tmpdir}/${syft_asset}" -C "${syft_tmpdir}" syft
  install -m 0755 "${syft_tmpdir}/syft" /usr/local/bin/syft
fi

# Install Grype if missing
if ! require_cmd grype; then
  info "Installing grype..."
  grype_raw="${GRYPE_VERSION#v}"
  grype_asset="grype_${grype_raw}_linux_${ARCH}.tar.gz"
  grype_checksums="grype_${grype_raw}_checksums.txt"
  grype_tmpdir="$(mktemp -d)"
  CLEANUP_DIRS+=("${grype_tmpdir}")
  download_https \
    "https://github.com/anchore/grype/releases/download/${GRYPE_VERSION}/${grype_asset}" \
    "${grype_tmpdir}/${grype_asset}"
  download_https \
    "https://github.com/anchore/grype/releases/download/${GRYPE_VERSION}/${grype_checksums}" \
    "${grype_tmpdir}/${grype_checksums}"
  grype_hash="$(checksum_for "${grype_tmpdir}/${grype_checksums}" "${grype_asset}")"
  verify_sha256 "${grype_tmpdir}/${grype_asset}" "${grype_hash}"
  tar -xzf "${grype_tmpdir}/${grype_asset}" -C "${grype_tmpdir}" grype
  install -m 0755 "${grype_tmpdir}/grype" /usr/local/bin/grype
fi

# Install Flux controllers
if ! kubectl get ns flux-system >/dev/null 2>&1; then
  info "Installing Flux controllers..."
  flux install --timeout=10m
else
  info "Flux already installed"
fi
apply_foundations_contract_marker "self-hosted"

step "4/6  Kyverno"
need_kyverno_install="false"
if ! kubectl get ns kyverno >/dev/null 2>&1; then
  need_kyverno_install="true"
fi
if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  need_kyverno_install="true"
fi

if [[ "${need_kyverno_install}" == "true" ]]; then
  info "Installing Kyverno..."
  # Use the vendored manifest only when its version label matches the pin.
  # Reads app.kubernetes.io/version from the first matching line (awk exits early to
  # avoid SIGPIPE on a large file under pipefail).
  VENDORED_KYVERNO_VER="$(awk '/app\.kubernetes\.io\/version:/{print $2; exit}' \
    "${ROOT_DIR}/cluster/policies/kyverno-install.yaml" 2>/dev/null || true)"
  if [[ "${VENDORED_KYVERNO_VER}" == "${KYVERNO_VERSION}" ]]; then
    info "Kyverno ${KYVERNO_VERSION}: vendored manifest"
    # Split CRDs from other resources to avoid annotation size issues
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("${tmpdir}")
    crd_file="${tmpdir}/crds.yaml"
    rest_file="${tmpdir}/rest.yaml"
    awk -v crd="${crd_file}" -v rest="${rest_file}" '
      function flush() {
        if (doc == "") return;
        if (is_crd) { printf "---\n%s", doc >> crd } else { printf "---\n%s", doc >> rest }
        doc=""; is_crd=0;
      }
      /^---/ { flush(); next }
      { doc = doc $0 "\n"; if ($1 == "kind:" && $2 == "CustomResourceDefinition") is_crd=1 }
      END { flush() }
    ' "${ROOT_DIR}/cluster/policies/kyverno-install.yaml"
    if [[ -s "${crd_file}" ]]; then
      if ! kubectl create -f "${crd_file}" 2>/tmp/kyverno-crd.err; then
        if ! grep -q "AlreadyExists" /tmp/kyverno-crd.err; then
          cat /tmp/kyverno-crd.err >&2
          exit 1
        fi
      fi
    fi
    kubectl apply --server-side --force-conflicts -f "${rest_file}"
  else
    info "Kyverno ${KYVERNO_VERSION}: upstream release manifest (vendored is ${VENDORED_KYVERNO_VER:-none})"
    kubectl apply --server-side --force-conflicts -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
  fi
else
  info "Kyverno already installed"
fi

# Wait for Kyverno CRDs to be established before applying policies
kubectl wait --for=condition=Established crd/clusterpolicies.kyverno.io --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=condition=Established crd/policies.kyverno.io --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=condition=available deployment/kyverno-admission-controller -n kyverno --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=condition=available deployment/kyverno-background-controller -n kyverno --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=condition=available deployment/kyverno-cleanup-controller -n kyverno --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=condition=available deployment/kyverno-reports-controller -n kyverno --timeout=120s >/dev/null 2>&1 || true

step "5/6  Policies"
info "Applying baseline policies..."
# shellcheck source=bootstrap/lib/policies.sh
source "${ROOT_DIR}/bootstrap/lib/policies.sh"
apply_policies_with_retry || { fail "Baseline policies are not in place; refusing to continue"; exit 1; }

# Overlay rendered policies from config/rendered/ if `make configure` has been run.
# These rendered files replace the two ClusterPolicies (restrict-registries,
# require-signed-images) with customer-specific versions; the baseline presence
# check above still guards the full policy set.
RENDERED_POLICIES="${ROOT_DIR}/config/rendered"
if [[ -f "${RENDERED_POLICIES}/restrict-registries.yaml" && \
      -f "${RENDERED_POLICIES}/require-signed-images.yaml" ]]; then
  info "Applying rendered policies from config/rendered/ (operator-configured)..."
  kubectl apply -f "${RENDERED_POLICIES}/restrict-registries.yaml"
  kubectl apply -f "${RENDERED_POLICIES}/require-signed-images.yaml"
  info "Rendered registry/signing policies applied."
else
  info "Using default policies (run 'make configure' to customize registry/image signing)."
fi

step "6/6  GitOps Bootstrap"
info "Bootstrapping GitOps sync..."
GIT_URL="${RATHSTED_GIT_URL:-$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)}"
if [[ -z "$GIT_URL" ]]; then
  echo "No git remote found. Set RATHSTED_GIT_URL to your repo URL." >&2
  exit 1
fi
if [[ "$GIT_URL" == git@*:* ]]; then
  host_part="${GIT_URL#git@}"
  host="${host_part%%:*}"
  path_part="${host_part#*:}"
  GIT_URL="ssh://git@${host}/${path_part}"
fi

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("${tmpdir}")

SECRET_REF=""
if [[ -n "${RATHSTED_GIT_SSH_KEY:-}" ]]; then
  info "Configuring Flux GitRepository auth (SSH key)"
  # Pinned GitHub host keys — avoids MITM risk from runtime key fetching.
  # Source: https://github.blog/changelog/2023-03-23-we-updated-our-rsa-ssh-host-key/
  KNOWN_HOSTS="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
  cred_tmpdir="$(mktemp -d)"
  chmod 700 "${cred_tmpdir}"
  CLEANUP_DIRS+=("${cred_tmpdir}")
  # Write key to file — preserves exactly one trailing newline; never on argv.
  printf '%s\n' "${RATHSTED_GIT_SSH_KEY%$'\n'}" > "${cred_tmpdir}/identity"
  chmod 600 "${cred_tmpdir}/identity"
  kubectl_args=(
    create secret generic rathsted-git-auth
    -n flux-system
    --from-file=identity="${cred_tmpdir}/identity"
    --from-literal=known_hosts="${KNOWN_HOSTS}"
  )
  if [[ -n "${RATHSTED_GIT_SSH_PASSPHRASE:-}" ]]; then
    printf '%s' "${RATHSTED_GIT_SSH_PASSPHRASE}" > "${cred_tmpdir}/identity_passphrase"
    chmod 600 "${cred_tmpdir}/identity_passphrase"
    kubectl_args+=(--from-file=identity_passphrase="${cred_tmpdir}/identity_passphrase")
  fi
  kubectl_args+=(--dry-run=client -o yaml)
  kubectl "${kubectl_args[@]}" | kubectl apply -f -
  SECRET_REF=$'  secretRef:\n    name: rathsted-git-auth'
elif [[ -n "${RATHSTED_GIT_TOKEN:-}" ]]; then
  info "Configuring Flux GitRepository auth (HTTPS token)"
  cred_tmpdir="$(mktemp -d)"
  chmod 700 "${cred_tmpdir}"
  CLEANUP_DIRS+=("${cred_tmpdir}")
  printf '%s' "x-access-token" > "${cred_tmpdir}/username"
  printf '%s' "${RATHSTED_GIT_TOKEN}" > "${cred_tmpdir}/password"
  chmod 600 "${cred_tmpdir}/username" "${cred_tmpdir}/password"
  kubectl create secret generic rathsted-git-auth \
    -n flux-system \
    --from-file=username="${cred_tmpdir}/username" \
    --from-file=password="${cred_tmpdir}/password" \
    --dry-run=client -o yaml | kubectl apply -f -
  SECRET_REF=$'  secretRef:\n    name: rathsted-git-auth'
fi

# Pin the Flux GitRepository to the release tag when HEAD is exactly on one,
# so reconciliation follows the pinned artifact instead of a moving branch.
# Override with RATHSTED_GIT_REF (e.g. "tag: v1.0.3" or "branch: main").
GIT_REF="${RATHSTED_GIT_REF:-}"
if [[ -z "${GIT_REF}" ]]; then
  if _tag="$(git -C "${ROOT_DIR}" describe --tags --exact-match 2>/dev/null)"; then
    GIT_REF="tag: ${_tag}"
  else
    GIT_REF="branch: main"
  fi
fi

TMPL="${ROOT_DIR}/cluster/gitops/sync/gitrepository.yaml.tmpl" \
OUT="$tmpdir/gitrepository.yaml" \
GIT_URL="${GIT_URL}" \
GIT_REF="${GIT_REF}" \
SECRET_REF="${SECRET_REF}" \
python3 - <<'PY'
import os
from pathlib import Path

tmpl = Path(os.environ["TMPL"])
out = Path(os.environ["OUT"])
git_url = os.environ["GIT_URL"]
git_ref = os.environ["GIT_REF"]
secret_ref = os.environ.get("SECRET_REF", "")

text = tmpl.read_text()
text = text.replace("REPLACE_GIT_URL", git_url)
text = text.replace("REPLACE_GIT_REF", git_ref)
text = text.replace("__SECRET_REF__", secret_ref)
out.write_text(text)
PY

kubectl apply -f "$tmpdir/gitrepository.yaml"
kubectl apply -f "${ROOT_DIR}/cluster/gitops/sync/kustomization.yaml"

info "Done. Use ./bootstrap/verify.sh to validate."
