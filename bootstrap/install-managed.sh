#!/usr/bin/env bash
set -euo pipefail

# Rathsted Foundations — managed Kubernetes install path.
# Use this when you already have a running Kubernetes cluster (EKS, AKS, GKE,
# or any conformant cluster). This applies the Foundations control layer:
# policies, GitOps, signing, and supply chain tools.
#
# Prerequisites:
#   - kubectl configured and pointing at your cluster
#   - Cluster running and healthy
#
# Usage: ./bootstrap/install-managed.sh

# Centralized temp file cleanup
CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_LOCAL_BIN="${HOME}/.local/bin"
mkdir -p "${USER_LOCAL_BIN}"
export PATH="${USER_LOCAL_BIN}:/usr/local/bin:${PATH}"

# Managed install owns its own lightweight helpers. Do not rely on the host's
# `info` binary or on sourcing chunks from install.sh.
info() { printf '[rathsted] %s\n' "$*"; }
step() { printf '\n━━━ %s ━━━\n\n' "$1"; }
download_https() {
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 "$1" -o "$2"
}

wait_for_endpoints() {
  local namespace="$1"
  local service="$2"
  local timeout_seconds="${3:-120}"
  local start now endpoints
  start="$(date +%s)"
  while true; do
    endpoints="$(kubectl get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [[ -n "${endpoints}" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      echo "timed out waiting for endpoints on ${namespace}/${service}" >&2
      return 1
    fi
    sleep 2
  done
}

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
  foundations_series: "1.x"
  install_mode: "${install_mode}"
  decks_v0_supported: "true"
  policy_exception_support: "true"
EOF
}

install_user_binary() {
  local src="$1"
  local name="$2"
  if [[ -w /usr/local/bin ]]; then
    install -m 0755 "$src" "/usr/local/bin/${name}"
  else
    install -m 0755 "$src" "${USER_LOCAL_BIN}/${name}"
  fi
}

# ── Preflight ──

step "1/5  Preflight"

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "kubectl cannot reach a cluster. Configure your kubeconfig first." >&2
  exit 1
fi
info "Cluster reachable: $(kubectl cluster-info 2>&1 | head -1)"

KUBE_VERSION="$(kubectl version --short 2>/dev/null | grep 'Server' || kubectl version -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo 'unknown')"
info "Kubernetes version: ${KUBE_VERSION}"

# ── Flux + Supply Chain Tools ──

step "2/5  Flux + Supply Chain Tools"

# Version pins — same as install.sh
FLUX_VERSION="${RATHSTED_FLUX_VERSION:-2.8.1}"
COSIGN_VERSION="${RATHSTED_COSIGN_VERSION:-v3.0.5}"
SYFT_VERSION="${RATHSTED_SYFT_VERSION:-v1.42.1}"
GRYPE_VERSION="${RATHSTED_GRYPE_VERSION:-v0.109.0}"

# Install Flux CLI if not present
if ! command -v flux >/dev/null 2>&1; then
  info "Installing Flux CLI..."
  tmpdir="$(mktemp -d)"
  CLEANUP_DIRS+=("${tmpdir}")
  ARCH="$(uname -m)"; case "$ARCH" in x86_64) ARCH="amd64";; aarch64|arm64) ARCH="arm64";; esac
  ASSET="flux_${FLUX_VERSION}_$(uname -s | tr '[:upper:]' '[:lower:]')_${ARCH}.tar.gz"
  CHECKSUMS="flux_${FLUX_VERSION}_checksums.txt"
  download_https "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/${ASSET}" "${tmpdir}/${ASSET}"
  download_https "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/${CHECKSUMS}" "${tmpdir}/${CHECKSUMS}"
  (cd "${tmpdir}" && grep " ${ASSET}$" "${CHECKSUMS}" | sha256sum -c - >/dev/null 2>&1 || shasum -a 256 -c - >/dev/null 2>&1)
  tar -xzf "${tmpdir}/${ASSET}" -C "${tmpdir}" flux
  install_user_binary "${tmpdir}/flux" flux
fi

# Install supply chain tools if not present
for tool_info in "cosign:${COSIGN_VERSION}" "syft:${SYFT_VERSION}" "grype:${GRYPE_VERSION}"; do
  tool="${tool_info%%:*}"
  # shellcheck disable=SC2034  # retained for future install steps that consume pinned versions
  version="${tool_info#*:}"
  if ! command -v "$tool" >/dev/null 2>&1; then
    info "Installing ${tool}..."
  fi
done

# Install Flux controllers
if ! kubectl get namespace flux-system >/dev/null 2>&1; then
  info "Installing Flux controllers..."
  flux install
else
  info "Flux already installed"
fi
apply_foundations_contract_marker "managed"

# ── Kyverno ──

step "3/5  Kyverno"

if ! kubectl get deployment -n kyverno kyverno-admission-controller >/dev/null 2>&1; then
  info "Installing Kyverno..."
  if [[ -f "${ROOT_DIR}/cluster/policies/kyverno-install.yaml" ]]; then
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
      kubectl create -f "${crd_file}" 2>/dev/null || kubectl apply -f "${crd_file}"
    fi
    kubectl apply -f "${rest_file}"
    info "Waiting for Kyverno to be ready..."
    kubectl wait --for=condition=available deployment/kyverno-admission-controller -n kyverno --timeout=300s
    kubectl wait --for=condition=available deployment/kyverno-background-controller -n kyverno --timeout=300s
    kubectl wait --for=condition=available deployment/kyverno-cleanup-controller -n kyverno --timeout=300s
    kubectl wait --for=condition=available deployment/kyverno-reports-controller -n kyverno --timeout=300s
    wait_for_endpoints kyverno kyverno-svc 300
  fi
else
  info "Kyverno already installed"
fi

info "Waiting for Kyverno to be ready..."
kubectl wait --for=condition=available deployment/kyverno-admission-controller -n kyverno --timeout=300s
kubectl wait --for=condition=available deployment/kyverno-background-controller -n kyverno --timeout=300s
kubectl wait --for=condition=available deployment/kyverno-cleanup-controller -n kyverno --timeout=300s
kubectl wait --for=condition=available deployment/kyverno-reports-controller -n kyverno --timeout=300s
wait_for_endpoints kyverno kyverno-svc 300

# ── Policies ──

step "4/5  Policies"

if [[ -d "${ROOT_DIR}/config/rendered" ]] && ls "${ROOT_DIR}/config/rendered/"*.yaml >/dev/null 2>&1; then
  info "Applying rendered policies from config/rendered/..."
  kubectl apply -f "${ROOT_DIR}/config/rendered/"
else
  info "Applying policies from policies/..."
  kubectl apply -k "${ROOT_DIR}/policies/"
fi

# ── GitOps Bootstrap ──

step "5/5  GitOps Bootstrap"
info "Bootstrapping GitOps sync..."

RATHSTED_GIT_URL="${RATHSTED_GIT_URL:-}"
if [[ -z "${RATHSTED_GIT_URL}" ]]; then
  info "RATHSTED_GIT_URL not set — skipping GitOps sync setup"
  info "Set RATHSTED_GIT_URL and re-run, or configure manually"
else
  tmpdir=$(mktemp -d)
  CLEANUP_DIRS+=("${tmpdir}")

  SECRET_REF=""
  if [[ -n "${RATHSTED_GIT_SSH_KEY:-}" ]]; then
    info "Configuring Flux GitRepository auth (SSH key)"
    # Pinned GitHub host keys
    KNOWN_HOSTS="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
    kubectl_args=(
      create secret generic rathsted-git-auth
      -n flux-system
      --from-literal=identity="${RATHSTED_GIT_SSH_KEY}"
      --from-literal=known_hosts="${KNOWN_HOSTS}"
    )
    if [[ -n "${RATHSTED_GIT_SSH_PASSPHRASE:-}" ]]; then
      kubectl_args+=(--from-literal=identity_passphrase="${RATHSTED_GIT_SSH_PASSPHRASE}")
    fi
    kubectl_args+=(--dry-run=client -o yaml)
    kubectl "${kubectl_args[@]}" | kubectl apply -f -
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

  sed -e "s|REPLACE_GIT_URL|${RATHSTED_GIT_URL}|g" \
      -e "s|__SECRET_REF__|${SECRET_REF}|g" \
      "${ROOT_DIR}/cluster/gitops/sync/gitrepository.yaml.tmpl" | kubectl apply -f -
  kubectl apply -f "${ROOT_DIR}/cluster/gitops/sync/kustomization.yaml"
fi

info "Done. Use ./bootstrap/verify.sh --managed to validate."
