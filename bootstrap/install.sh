#!/usr/bin/env bash
set -euo pipefail

# Ensure /usr/local/bin is on PATH (not always present on RHEL-family minimal installs)
export PATH="/usr/local/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_CONFIG="${ROOT_DIR}/cluster/k3s/config.yaml"
# Version pins (overridable via env vars for version matrix testing)
K3S_VERSION="${RATHSTED_K3S_VERSION:-v1.35.1+k3s1}"
KYVERNO_VERSION="${RATHSTED_KYVERNO_VERSION:-v1.17.1}"
FLUX_VERSION="${RATHSTED_FLUX_VERSION:-2.8.1}"
COSIGN_VERSION="${RATHSTED_COSIGN_VERSION:-v3.0.5}"
SYFT_VERSION="${RATHSTED_SYFT_VERSION:-v1.42.1}"
GRYPE_VERSION="${RATHSTED_GRYPE_VERSION:-v0.109.0}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

info() { echo "[rathsted] $*"; }
fail() { echo "[FAIL] $*" >&2; }
step() { printf '\n━━━ %s ━━━\n\n' "$1"; }

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

# Dependencies
for bin in curl awk sed git python3; do
  require_cmd "$bin" || { echo "Missing required tool: $bin" >&2; exit 1; }
 done

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
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_EXEC="--config ${K3S_CONFIG}" sh -
else
  info "k3s already running"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

step "3/6  Flux + Supply Chain Tools"
if ! require_cmd flux; then
  info "Installing Flux CLI..."
  curl -s https://fluxcd.io/install.sh | FLUX_VERSION="${FLUX_VERSION}" bash
fi

# Install Cosign, Syft, Grype if missing
if ! require_cmd cosign; then
  info "Installing cosign..."
  COSIGN_ARCH="$(uname -m)"
  case "${COSIGN_ARCH}" in
    x86_64)  COSIGN_ARCH="amd64" ;;
    aarch64) COSIGN_ARCH="arm64" ;;
  esac
  curl -sSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${COSIGN_ARCH}" -o /usr/local/bin/cosign
  chmod +x /usr/local/bin/cosign
fi
if ! require_cmd syft; then
  info "Installing syft..."
  if ! curl -sSL https://raw.githubusercontent.com/anchore/syft/main/install.sh | bash -s -- -b /usr/local/bin "${SYFT_VERSION}"; then
    fail "Pinned syft version ${SYFT_VERSION} not available. Check docs/versions.md for the current pin."
    exit 1
  fi
fi
if ! require_cmd grype; then
  info "Installing grype..."
  if ! curl -sSL https://raw.githubusercontent.com/anchore/grype/main/install.sh | bash -s -- -b /usr/local/bin "${GRYPE_VERSION}"; then
    fail "Pinned grype version ${GRYPE_VERSION} not available. Check docs/versions.md for the current pin."
    exit 1
  fi
fi

# Install Flux controllers
if ! kubectl get ns flux-system >/dev/null 2>&1; then
  info "Installing Flux controllers..."
  flux install --timeout=10m
else
  info "Flux already installed"
fi

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
  if grep -q "^apiVersion:" "${ROOT_DIR}/cluster/policies/kyverno-install.yaml" 2>/dev/null; then
    # Split CRDs from other resources to avoid annotation size issues
    tmpdir=$(mktemp -d)
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
    rm -rf "${tmpdir}"
  else
    kubectl apply --server-side --force-conflicts -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
  fi
else
  info "Kyverno already installed"
fi

# Wait for Kyverno CRDs to be established before applying policies
kubectl wait --for=condition=Established crd/clusterpolicies.kyverno.io --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=condition=Established crd/policies.kyverno.io --timeout=120s >/dev/null 2>&1 || true

step "5/6  Policies"
info "Applying baseline policies..."
kubectl apply -k "${ROOT_DIR}/policies"

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
trap 'rm -rf "$tmpdir"' EXIT

SECRET_REF=""
if [[ -n "${RATHSTED_GIT_SSH_KEY:-}" ]]; then
  info "Configuring Flux GitRepository auth (SSH key)"
  require_cmd ssh-keyscan || { echo "ssh-keyscan required for SSH auth" >&2; exit 1; }
  KNOWN_HOSTS="$(ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null)"
  kubectl create secret generic rathsted-git-auth \
    -n flux-system \
    --from-literal=identity="${RATHSTED_GIT_SSH_KEY}" \
    ${RATHSTED_GIT_SSH_PASSPHRASE:+--from-literal=identity_passphrase="${RATHSTED_GIT_SSH_PASSPHRASE}"} \
    --from-literal=known_hosts="${KNOWN_HOSTS}" \
    --dry-run=client -o yaml | kubectl apply -f -
  SECRET_REF=$'  secretRef:\n    name: rathsted-git-auth'
elif [[ -n "${RATHSTED_GIT_TOKEN:-}" ]]; then
  info "Configuring Flux GitRepository auth (HTTPS token)"
  kubectl create secret generic rathsted-git-auth \
    -n flux-system \
    --from-literal=username="x-access-token" \
    --from-literal=password="${RATHSTED_GIT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  SECRET_REF=$'  secretRef:\n    name: rathsted-git-auth'
fi

TMPL="${ROOT_DIR}/cluster/gitops/sync/gitrepository.yaml.tmpl" \
OUT="$tmpdir/gitrepository.yaml" \
GIT_URL="${GIT_URL}" \
SECRET_REF="${SECRET_REF}" \
python3 - <<'PY'
import os
from pathlib import Path

tmpl = Path(os.environ["TMPL"])
out = Path(os.environ["OUT"])
git_url = os.environ["GIT_URL"]
secret_ref = os.environ.get("SECRET_REF", "")

text = tmpl.read_text()
text = text.replace("REPLACE_GIT_URL", git_url)
text = text.replace("__SECRET_REF__", secret_ref)
out.write_text(text)
PY

kubectl apply -f "$tmpdir/gitrepository.yaml"
kubectl apply -f "${ROOT_DIR}/cluster/gitops/sync/kustomization.yaml"

info "Done. Use ./bootstrap/verify.sh to validate." 
