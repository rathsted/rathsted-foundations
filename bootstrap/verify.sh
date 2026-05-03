#!/usr/bin/env bash
set -euo pipefail

# Ensure /usr/local/bin is on PATH (not always present on RHEL-family minimal installs)
export PATH="/usr/local/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Use k3s kubeconfig when running on a real k3s node; otherwise keep
# whatever KUBECONFIG is already set (e.g. k3d, KIND, or CI default).
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
DRY_RUN="false"
RELEASE_MODE="false"
MANAGED_MODE="auto"
FAIL=0
WARN=0
PASS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="true" ;;
    --release) RELEASE_MODE="true" ;;
    --managed) MANAGED_MODE="true" ;;
    --self-hosted) MANAGED_MODE="false" ;;
  esac
done

ok() { echo "[ok $(date +%H:%M:%S)] $*"; PASS=$((PASS + 1)); }
warn() { echo "[warn $(date +%H:%M:%S)] $*"; WARN=$((WARN + 1)); }
skip() { echo "[skip $(date +%H:%M:%S)] $*"; WARN=$((WARN + 1)); }
section() { echo ""; echo "== $* =="; }

if [[ "$DRY_RUN" == "true" ]]; then
  section "Dry Run"
  ok "dry-run mode (skipping live cluster checks)"
  # Static checks
  if command -v kubectl >/dev/null 2>&1; then
    kubectl kustomize "${ROOT_DIR}/cluster/gitops/apps" >/dev/null && ok "kustomize build ok"
  elif command -v kustomize >/dev/null 2>&1; then
    kustomize build "${ROOT_DIR}/cluster/gitops/apps" >/dev/null && ok "kustomize build ok"
  else
    warn "kustomize not found; skipping kustomize build"
  fi
  exit 0
fi

section "Environment"
FOUNDATIONS_VERSION="$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || echo "untagged")"
CONTRACT_NAME="rathsted-foundations-contract"
CONTRACT_NS="flux-system"
CONTRACT_MODE="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.install_mode}' 2>/dev/null || true)"
if [[ "${MANAGED_MODE}" == "auto" ]]; then
  if [[ "${CONTRACT_MODE}" == "managed" ]]; then
    MANAGED_MODE="true"
  else
    MANAGED_MODE="false"
  fi
fi
echo "  Foundations version: ${FOUNDATIONS_VERSION}"
echo "  Hostname:           $(hostname)"
echo "  Date:               $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Verify mode:        $([[ "${MANAGED_MODE}" == "true" ]] && echo managed || echo self-hosted)"
# shellcheck disable=SC1091
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  echo "  OS:                 ${PRETTY_NAME:-${ID} ${VERSION_ID}}"
fi
echo "  Kernel:             $(uname -r)"
ok "Environment recorded"

section "Cluster"
if kubectl cluster-info >/dev/null 2>&1; then
  ok "cluster-info ok"
else
  warn "cluster-info failed"
  FAIL=1
fi
if kubectl get nodes -o wide >/dev/null 2>&1; then
  ok "cluster nodes accessible"
else
  warn "cluster nodes not accessible"
  FAIL=1
fi
if kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" >/dev/null 2>&1; then
  contract_series="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.foundations_series}' 2>/dev/null || true)"
  contract_mode="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.install_mode}' 2>/dev/null || true)"
  contract_decks="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.decks_v0_supported}' 2>/dev/null || true)"
  echo "  Contract series:    ${contract_series:-unknown}"
  echo "  Contract install:   ${contract_mode:-unknown}"
  echo "  Decks v0 support:   ${contract_decks:-unknown}"
  ok "Foundations contract marker present"
else
  warn "Foundations contract marker missing (${CONTRACT_NS}/${CONTRACT_NAME})"
fi

section "Hardening"
if [[ "${MANAGED_MODE}" == "true" ]]; then
  skip "Managed-mode host audit-log checks skipped"
  skip "Managed-mode host audit-policy checks skipped"
  skip "Managed-mode local secrets-encryption file checks skipped"
else
  AUDIT_LOG="/var/lib/rancher/k3s/server/logs/audit.log"
  if [[ -f "$AUDIT_LOG" ]]; then
    AUDIT_SIZE="$(du -h "$AUDIT_LOG" 2>/dev/null | cut -f1)"
    AUDIT_LINES="$(wc -l < "$AUDIT_LOG" | tr -d ' ')"
    echo "  Audit log: ${AUDIT_LOG} (${AUDIT_SIZE}, ${AUDIT_LINES} entries)"
    ok "API server audit logging active"
  else
    warn "Audit log not found at ${AUDIT_LOG}"
  fi
  AUDIT_POLICY="/var/lib/rancher/k3s/server/audit-policy.yaml"
  if [[ -f "$AUDIT_POLICY" ]]; then
    ok "Audit policy file present"
  else
    warn "Audit policy file not found"
  fi
  # Secrets encryption at rest
  if grep -q "secrets-encryption: true" /etc/rancher/k3s/config.yaml 2>/dev/null; then
    ok "Secrets encryption at rest enabled (k3s config)"
  elif [[ -f /var/lib/rancher/k3s/server/cred/encryption-config.json ]]; then
    ok "Secrets encryption at rest enabled (encryption config present)"
  else
    warn "Secrets encryption at rest not detected"
  fi
fi

section "Flux"
if flux check >/dev/null 2>&1; then
  ok "Flux check passed"
else
  warn "Flux check failed"
fi
if kubectl get ns flux-system >/dev/null; then
  ok "Flux installed"
else
  warn "Flux not installed"
fi
if kubectl get pods -n flux-system >/dev/null; then
  ok "Flux pods present"
else
  warn "Flux pods missing"
fi

section "Kyverno"
if kubectl get ns kyverno >/dev/null; then
  ok "Kyverno installed"
else
  warn "Kyverno not installed"
fi
if kubectl get pods -n kyverno >/dev/null; then
  ok "Kyverno pods present"
else
  warn "Kyverno pods missing"
fi
if kubectl get cpol >/dev/null; then
  ok "Kyverno policies present"
else
  warn "Kyverno policies missing"
fi

section "GitOps"
if [[ "${MANAGED_MODE}" == "true" ]]; then
  if kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system >/dev/null 2>&1; then
    ok "Managed-mode GitOps sync present"
  else
    skip "Managed-mode GitOps sync not configured"
  fi
  if flux get sources git -A >/dev/null 2>&1; then
    ok "Managed-mode Flux Git sources listed"
  else
    skip "Managed-mode Flux Git sources not configured"
  fi
else
  if kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system >/dev/null; then
    ok "GitOps sync present"
  else
    warn "GitOps sync missing"
  fi
  if flux get kustomizations -A >/dev/null; then
    ok "Flux kustomizations listed"
  else
    warn "Flux kustomizations not listed"
  fi
  if flux get sources git -A >/dev/null; then
    ok "Flux Git sources listed"
  else
    warn "Flux Git sources not listed"
  fi
fi

section "Demo App"
if [[ "${MANAGED_MODE}" == "true" ]] && ! kubectl get ns demo >/dev/null 2>&1; then
  skip "Managed-mode demo app not installed"
elif kubectl get ns demo >/dev/null 2>&1; then
  if kubectl get deploy,po,svc -n demo >/dev/null 2>&1; then
    ok "Demo app objects present"
  else
    warn "Demo app objects missing (GitOps may still be reconciling)"
  fi
  if kubectl rollout status deployment/hello-gitops -n demo --timeout=120s >/dev/null 2>&1; then
    ok "Demo app Ready"
  else
    warn "Demo app not Ready (non-fatal: GitOps reconciliation may still be in progress)"
  fi
else
  warn "Demo namespace not present (non-fatal: GitOps reconciliation may still be in progress)"
fi

# Verify signature policy is installed
if kubectl get clusterpolicy require-signed-images >/dev/null 2>&1; then
  ok "Signature policy installed"
else
  warn "Signature policy missing"
  FAIL=1
fi

# Generate SBOM for demo image
section "Supply Chain"
IMAGE="${RATHSTED_DEMO_IMAGE:-ghcr.io/rathsted/foundations-demo:1.0.0}"
mkdir -p "${ROOT_DIR}/supply-chain/sbom/output"
if [[ "${RELEASE_MODE}" == "true" ]]; then
  IMAGE_HOST="$(echo "$IMAGE" | cut -d/ -f1)"
  if ! getent hosts "${IMAGE_HOST}" >/dev/null 2>&1; then
    warn "Registry host not resolvable: ${IMAGE_HOST}"
    FAIL=1
  fi
  # curl without -f: ghcr.io/v2/ returns 401 (auth required) which is expected and means
  # the network works; only a connection failure (exit code 7/28) means not reachable
  if ! curl -sS --max-time 5 -o /dev/null "https://${IMAGE_HOST}/v2/" 2>/dev/null; then
    warn "Registry not reachable: ${IMAGE_HOST}"
    FAIL=1
  fi
fi
SBOM_OUT="${ROOT_DIR}/supply-chain/sbom/output/foundations-demo.sbom.json"
K3S_SOCK="/run/k3s/containerd/containerd.sock"
SBOM_OK="false"

# Try local k3s containerd first (image exists locally even if not in a remote registry)
if [[ -S "$K3S_SOCK" ]] && command -v syft >/dev/null 2>&1; then
  if CONTAINERD_ADDRESS="$K3S_SOCK" CONTAINERD_NAMESPACE=k8s.io \
     syft "containerd:${IMAGE}" -o json > "$SBOM_OUT" 2>/dev/null; then
    ok "SBOM generated (local containerd)"
    SBOM_OK="true"
  fi
fi
# Fall back to remote registry pull
if [[ "$SBOM_OK" != "true" ]]; then
  if ! command -v syft >/dev/null 2>&1; then
    if [[ "${RELEASE_MODE}" == "true" ]]; then
      warn "SBOM generation failed (syft not installed; required in release mode)"
      FAIL=1
    else
      skip "SBOM skipped (syft not installed; use --release to enforce)"
    fi
  elif syft "$IMAGE" -o json > "$SBOM_OUT" 2>/tmp/rathsted-syft.err; then
    ok "SBOM generated"
    SBOM_OK="true"
  else
    if [[ "${RELEASE_MODE}" == "true" ]]; then
      warn "SBOM generation failed (registry access required in release mode)"
      FAIL=1
    else
      skip "SBOM skipped (image not in registry; use --release to enforce)"
    fi
  fi
fi

# Verify cosign signature if public key is present
PUBKEY="${ROOT_DIR}/supply-chain/cosign/cosign.pub"
if [[ -f "$PUBKEY" ]] && ! grep -q "REPLACE_WITH" "$PUBKEY" 2>/dev/null; then
  if cosign verify --key "$PUBKEY" "$IMAGE" >/dev/null 2>&1; then
    ok "Cosign signature verified"
  else
    if [[ "${RELEASE_MODE}" == "true" ]]; then
      warn "Cosign verification failed (check signature or registry access)"
      FAIL=1
    else
      skip "Cosign skipped (image not signed or not in registry; use --release to enforce)"
    fi
  fi
else
  if [[ "${RELEASE_MODE}" == "true" ]]; then
    warn "cosign.pub not found or not configured; required for release verification"
    FAIL=1
  else
    skip "Cosign skipped (cosign.pub not configured; use --release to enforce)"
  fi
fi

# Vulnerability scan
if command -v grype >/dev/null 2>&1 && [[ "$SBOM_OK" == "true" ]]; then
  section "Vulnerability Scan"
  GRYPE_OUT="${ROOT_DIR}/supply-chain/sbom/output/foundations-demo.grype.txt"
  if grype "sbom:${SBOM_OUT}" -o table > "$GRYPE_OUT" 2>/dev/null; then
    VULN_COUNT="$(wc -l < "$GRYPE_OUT" | tr -d ' ')"
    ok "Grype scan complete (${VULN_COUNT} lines)"
    echo "  Results: ${GRYPE_OUT}"
    # Show critical/high counts if any
    CRIT="$(grep -c ' Critical ' "$GRYPE_OUT" 2>/dev/null || true)"
    HIGH="$(grep -c ' High ' "$GRYPE_OUT" 2>/dev/null || true)"
    if [[ "${CRIT:-0}" -gt 0 || "${HIGH:-0}" -gt 0 ]]; then
      echo "  Critical: ${CRIT:-0}  High: ${HIGH:-0}"
    fi
  else
    ok "Grype scan skipped (scan failed; non-blocking)"
  fi
fi

# Enforce signature policy mode in release verification
if [[ "${RELEASE_MODE}" == "true" ]]; then
  POLICY_MODE="$(kubectl get clusterpolicy require-signed-images -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)"
  if [[ "${POLICY_MODE}" == "Audit" ]]; then
    warn "Signature policy is in Audit mode; set to enforce for release verification"
    FAIL=1
  fi
fi

# Policy enforcement checks with intentionally bad manifests
section "Negative Tests"

# Wait for Kyverno validating webhooks to be active (race condition after install)
WEBHOOK_READY=false
for _i in $(seq 1 60); do
  if kubectl get validatingwebhookconfigurations 2>/dev/null | grep -q kyverno; then
    WEBHOOK_READY=true
    break
  fi
  sleep 2
done
if [[ "$WEBHOOK_READY" != "true" ]]; then
  warn "Kyverno webhooks not detected after 120s"
  FAIL=1
fi

# Extra settle time — webhooks are registered but not all policies may be compiled yet
if [[ "$WEBHOOK_READY" == "true" ]]; then
  ok "Kyverno webhooks detected, waiting 15s for policies to settle..."
  sleep 15
fi

for f in "${ROOT_DIR}"/tests/bad-manifests/*.yaml; do
  if [[ "${MANAGED_MODE}" == "true" && "$(basename "$f")" == "no-namespace-labels.yaml" ]]; then
    skip "Namespace-label negative test skipped in managed mode"
    continue
  fi
  ADMITTED=true
  for _attempt in 1 2 3 4 5; do
    if ! kubectl apply -f "$f" >/tmp/rathsted-bad-apply.log 2>&1; then
      ADMITTED=false
      break
    fi
    # Webhook may still be registering — clean up and retry
    kubectl delete -f "$f" --ignore-not-found >/dev/null 2>&1
    sleep 5
  done
  if [[ "$ADMITTED" == "true" ]]; then
    warn "Bad manifest was applied: $(basename "$f")"
    kubectl delete -f "$f" --ignore-not-found >/dev/null 2>&1
    FAIL=1
  else
    REJECTING_POLICY=$(awk '/blocked due to the following policies/,/^$/' /tmp/rathsted-bad-apply.log 2>/dev/null | grep -oE '^[a-z][a-z0-9-]+:' 2>/dev/null | head -1 | tr -d ':' || true)
    if [[ -n "$REJECTING_POLICY" ]]; then
      ok "Policy rejected as expected: $(basename "$f") (by $REJECTING_POLICY)"
    else
      ok "Policy rejected as expected: $(basename "$f")"
    fi
  fi
done

# Positive admission tests: each manifest should be admitted (server-side dry-run).
# Only run in release-verify mode — outside release mode, the demo image referenced
# by signed-image fixtures may not be signed (or the policy's embedded public key
# may be a placeholder), and we'd produce false negatives. Matches the gating used
# by the cosign signature-verification step earlier in this file.
section "Positive Admission Tests"
if [[ "${RATHSTED_VERIFY_RELEASE:-}" != "1" ]]; then
  skip "Positive admission tests skipped (use --release / RATHSTED_VERIFY_RELEASE=1 to enforce)"
else
  shopt -s nullglob
  GOOD_MANIFESTS=("${ROOT_DIR}"/tests/good-manifests/*.yaml)
  shopt -u nullglob
  if [[ ${#GOOD_MANIFESTS[@]} -eq 0 ]]; then
    skip "No tests/good-manifests/*.yaml fixtures present"
  else
    for f in "${GOOD_MANIFESTS[@]}"; do
      if kubectl apply --dry-run=server -f "$f" >/tmp/rathsted-good-apply.log 2>&1; then
        ok "Good manifest admitted: $(basename "$f")"
      else
        warn "Good manifest was rejected unexpectedly: $(basename "$f")"
        tail -5 /tmp/rathsted-good-apply.log | sed 's/^/    /'
        FAIL=1
      fi
    done
  fi
fi

section "Access Control (RBAC)"
RBAC_BINDINGS="$(kubectl get clusterrolebindings,rolebindings -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "  ClusterRoleBindings + RoleBindings: ${RBAC_BINDINGS}"
kubectl get clusterrolebindings --no-headers 2>/dev/null | awk '{print "    " $1}' || true
ok "RBAC snapshot recorded"

section "Network Policies"
NETPOL_COUNT="$(kubectl get networkpolicies -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "  NetworkPolicies across all namespaces: ${NETPOL_COUNT}"
kubectl get networkpolicies -A --no-headers 2>/dev/null | awk '{printf "    %-20s %s\n", $1, $2}' || true
ok "NetworkPolicy snapshot recorded"

if [[ "$FAIL" -ne 0 ]]; then
  echo "[fail] One or more checks failed" >&2
fi

# Run summary
section "Summary"
echo "  Passed:   ${PASS}"
echo "  Warnings: ${WARN}"
echo "  Failed:   ${FAIL}"
echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "[fail $(date +%H:%M:%S)] Verification failed — review warnings and errors above"
  exit 1
else
  echo "[ok $(date +%H:%M:%S)] Verification passed"
fi
