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
    kubectl kustomize "${ROOT_DIR}/cluster/gitops/apps" >/dev/null \
      && kubectl kustomize "${ROOT_DIR}/cluster/gitops/workloads" >/dev/null && ok "kustomize build ok"
  elif command -v kustomize >/dev/null 2>&1; then
    kustomize build "${ROOT_DIR}/cluster/gitops/apps" >/dev/null \
      && kustomize build "${ROOT_DIR}/cluster/gitops/workloads" >/dev/null && ok "kustomize build ok"
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
node_count="unknown"
if kubectl get nodes -o wide >/dev/null 2>&1; then
  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "  Cluster nodes:      ${node_count}"
  ok "cluster nodes accessible"
else
  warn "cluster nodes not accessible"
  FAIL=1
fi
if kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" >/dev/null 2>&1; then
  contract_series="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.foundations_series}' 2>/dev/null || true)"
  contract_mode="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.install_mode}' 2>/dev/null || true)"
  contract_decks="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.decks_v0_supported}' 2>/dev/null || true)"
  contract_topology="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.topology_mode}' 2>/dev/null || true)"
  contract_topology_level="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.topology_support_level}' 2>/dev/null || true)"
  contract_node_min="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.supported_node_min}' 2>/dev/null || true)"
  contract_node_max="$(kubectl get configmap "${CONTRACT_NAME}" -n "${CONTRACT_NS}" -o jsonpath='{.data.supported_node_max}' 2>/dev/null || true)"
  echo "  Contract series:    ${contract_series:-unknown}"
  echo "  Contract install:   ${contract_mode:-unknown}"
  echo "  Decks v0 support:   ${contract_decks:-unknown}"
  echo "  Topology:           ${contract_topology:-unknown} (supported nodes ${contract_node_min:-?}-${contract_node_max:-?})"
  echo "  Topology support:   ${contract_topology_level:-unknown}"
  ok "Foundations contract marker present"
  if [[ "${node_count}" =~ ^[0-9]+$ && "${contract_node_min}" =~ ^[0-9]+$ && "${contract_node_max}" =~ ^[0-9]+$ ]]; then
    if (( node_count < contract_node_min || node_count > contract_node_max )); then
      # A multi-node contract is an explicit support claim: a cluster outside
      # its range fails. The single-node baseline only warns, as before.
      if [[ "${contract_topology}" == "single-node" ]]; then
        warn "Cluster node count ${node_count} is outside the topology contract (${contract_node_min}-${contract_node_max})"
      else
        warn "Cluster node count ${node_count} is outside the ${contract_topology} contract (${contract_node_min}-${contract_node_max})"
        FAIL=1
      fi
    else
      ok "Cluster node count ${node_count} matches the ${contract_topology:-unknown} contract"
      if [[ "${contract_topology_level}" == "bounded" ]]; then
        ok "Topology support is bounded: HA, failover and stateful node-loss survivability are out of scope"
      fi
    fi
  else
    warn "Cannot compare cluster node count (${node_count}) with the topology contract (${contract_node_min:-?}-${contract_node_max:-?})"
  fi
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
# shellcheck source=bootstrap/lib/policies.sh
source "${ROOT_DIR}/bootstrap/lib/policies.sh"
if wait_for_policies_present; then
  ok "Kyverno policies present"
else
  warn "Kyverno policies missing"
  FAIL=1
fi
# Informational: record images actually running in the kyverno namespace so
# compat logs capture reality, not just the pin.  Safe under set -euo pipefail:
# the subshell error is suppressed; an empty result is silently skipped.
kyverno_imgs="$(kubectl get deploy -n kyverno \
  -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
  2>/dev/null)" || kyverno_imgs=""
while IFS= read -r img; do
  if [[ -n "$img" ]]; then
    echo "[info $(date +%H:%M:%S)] kyverno image: $img"
  fi
done <<<"$kyverno_imgs"

# Flux Kustomization readiness. rathsted-sync (the policies) is judged here,
# before the R3 section: the operator-control check trusts the stamp only
# once rathsted-sync has applied, and this waits for that on a just-installed
# cluster (RATHSTED_GITOPS_READY_ATTEMPTS, RATHSTED_GITOPS_READY_DELAY). The
# verdict is printed in the GitOps section. Self-hosted installs always
# configure GitOps, so a missing rathsted-sync counts there.
# shellcheck source=bootstrap/lib/gitops.sh
source "${ROOT_DIR}/bootstrap/lib/gitops.sh"
GITOPS_EXPECTED="true"
[[ "${MANAGED_MODE}" == "true" ]] && GITOPS_EXPECTED="false"
section "GitOps Readiness"
echo "[info $(date +%H:%M:%S)] reading flux-system/rathsted-sync before the namespace label checks; the verdict is in the GitOps section"
gitops_sync_rc=0
gitops_kustomization_verify_check rathsted-sync "${RELEASE_MODE}" true "${GITOPS_EXPECTED}" || gitops_sync_rc=$?
GITOPS_SYNC_MSG="${GITOPS_VERIFY_MSG}"

section "Namespace Jurisdiction Labels"
# shellcheck source=bootstrap/lib/jurisdiction.sh
source "${ROOT_DIR}/bootstrap/lib/jurisdiction.sh"
# Every namespace in one convention. A gap fails verify when
# RATHSTED_JURISDICTION is set, when the install recorded r3_jurisdiction in
# the contract marker (the installer then promised the labels), or under
# --release. Otherwise it warns, so installs made without a jurisdiction
# (every install before this check existed, and clusters with namespaces
# Foundations does not own, such as kind's local-path-storage) keep verifying
# as before. An audit that cannot run always fails.
r3_rc=0
jurisdiction_verify_check "${RELEASE_MODE}" || r3_rc=$?
case "${r3_rc}" in
  0) ok "${R3_VERIFY_MSG}" ;;
  1) warn "${R3_VERIFY_MSG}" ;;
  *) warn "${R3_VERIFY_MSG}"; FAIL=1 ;;
esac
# Declared operator-control: the stamped rathsted.io/operator-control must
# equal RATHSTED_OPERATOR_CONTROL in verify's environment, else the value the
# install recorded as r3_operator_control. Neither: a warning naming the
# stamped value (also under --release). A mismatch or a read error fails.
r3_rc=0
operator_control_verify_check "${RELEASE_MODE}" || r3_rc=$?
case "${r3_rc}" in
  0) ok "${R3_VERIFY_MSG}" ;;
  1) warn "${R3_VERIFY_MSG}" ;;
  *) warn "${R3_VERIFY_MSG}"; FAIL=1 ;;
esac

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

# rathsted-sync not Ready fails in every mode: the policies' self-heal
# depends on it (v2.0.0 to v2.0.2 shipped with it permanently not Ready).
case "${gitops_sync_rc}" in
  0) ok "${GITOPS_SYNC_MSG}" ;;
  1) warn "${GITOPS_SYNC_MSG}" ;;
  3) echo "[info $(date +%H:%M:%S)] ${GITOPS_SYNC_MSG}" ;;
  *) warn "${GITOPS_SYNC_MSG}"; FAIL=1 ;;
esac

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
# rathsted-apps (the workloads): after the demo rollout wait, so the two share
# it. Not Ready warns, fails under --release: user workloads failing must not
# hide, but they are not the platform's guarantee. It dependsOn rathsted-sync,
# so it is not waited for when rathsted-sync is not ok.
gitops_apps_rc=0
if [[ "${gitops_sync_rc}" -eq 0 ]]; then
  gitops_kustomization_verify_check rathsted-apps "${RELEASE_MODE}" false "${GITOPS_EXPECTED}" || gitops_apps_rc=$?
else
  RATHSTED_GITOPS_READY_ATTEMPTS=1 gitops_kustomization_verify_check rathsted-apps "${RELEASE_MODE}" false "${GITOPS_EXPECTED}" || gitops_apps_rc=$?
fi
case "${gitops_apps_rc}" in
  0) ok "${GITOPS_VERIFY_MSG}" ;;
  1) warn "${GITOPS_VERIFY_MSG}" ;;
  3) echo "[info $(date +%H:%M:%S)] ${GITOPS_VERIFY_MSG}" ;;
  *) warn "${GITOPS_VERIFY_MSG}"; FAIL=1 ;;
esac

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
  # Human-readable table for the evidence artifact (never blocks on its own).
  grype "sbom:${SBOM_OUT}" -o table > "$GRYPE_OUT" 2>/dev/null || true
  CRIT="$(grep -c ' Critical ' "$GRYPE_OUT" 2>/dev/null || true)"
  HIGH="$(grep -c ' High ' "$GRYPE_OUT" 2>/dev/null || true)"
  echo "  Results: ${GRYPE_OUT}"
  echo "  Critical: ${CRIT:-0}  High: ${HIGH:-0}"
  if [[ "${RELEASE_MODE}" == "true" ]]; then
    # Release gate: block on High+ severity. Time-boxed exceptions live in
    # .grype.yaml at the repo root; grype exits non-zero when a finding at or
    # above the threshold remains after those ignores are applied.
    if grype "sbom:${SBOM_OUT}" --fail-on high -q -o table >/dev/null 2>&1; then
      ok "Grype release gate passed (no High+ findings after .grype.yaml ignores)"
    else
      warn "Grype release gate: High/Critical vulnerabilities present (see ${GRYPE_OUT}); fix them, or add a time-boxed exception in .grype.yaml"
      FAIL=1
    fi
  else
    ok "Grype scan complete (informational; the High+ release gate applies under --release)"
  fi
else
  # Under --release the gate is required: a missing grype or SBOM means we cannot
  # prove the shipped image is clean, so refuse to pass rather than skip silently.
  if [[ "${RELEASE_MODE}" == "true" ]]; then
    warn "Vulnerability gate cannot run (grype or SBOM unavailable); required for --release"
    FAIL=1
  else
    skip "Grype scan skipped (grype or SBOM unavailable)"
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
if [[ "${RELEASE_MODE}" != "true" && "${RATHSTED_VERIFY_RELEASE:-}" != "1" ]]; then
  skip "Positive admission tests skipped (use --release to enforce)"
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
