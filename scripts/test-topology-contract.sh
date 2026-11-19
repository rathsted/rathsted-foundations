#!/usr/bin/env bash
# test-topology-contract.sh — Foundations contract marker rendering, without a cluster.
#
# Exercises bootstrap/lib/contract.sh against a fake kubectl. The marker
# flux-system/rathsted-foundations-contract is what Decks preflight reads to
# decide whether a substrate is supported, so its fields are a public contract:
#
#   1. the default render is the single-node baseline, field for field
#   2. apply_foundations_contract_marker sends the rendered manifest to kubectl
#   3. install-managed.sh publishes the marker through the library and checks
#      the requested topology in preflight, before installing anything
#   4. FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1 with the env Decks
#      sets (smoke-managed-app-core-bounded.sh) publishes the bounded contract
#   5. managed-3-node-v1 alone derives bounded / 3-3
#   6. inconsistent or unknown topology settings are refused, not published
#   7. the 3-node contract is only applied to a cluster with exactly 3 nodes
#
# Usage:
#   ./scripts/test-topology-contract.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

GREEN='\033[32m' RED='\033[31m' CYAN='\033[36m' BOLD='\033[1m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN='' RED='' CYAN='' BOLD='' RESET=''; }

section() { printf "\n${CYAN}${BOLD}── %s ──${RESET}\n" "$1"; }
pass()    { printf "${GREEN}✓${RESET} %s\n" "$1"; PASS=$((PASS + 1)); }
fail()    { printf "${RED}✗${RESET} %s\n" "$1" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ─── Fake kubectl ───
# `apply -f -` stores stdin in $FAKE_STATE/applied.
# `get nodes --no-headers` prints $FAKE_NODES node lines.
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/kubectl" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "apply" && "$2" == "-f" && "$3" == "-" ]]; then
  cat > "${FAKE_STATE}/applied"
  echo "configmap/rathsted-foundations-contract configured"
  exit 0
fi
if [[ "$1" == "get" && "$2" == "nodes" ]]; then
  for ((i = 1; i <= ${FAKE_NODES:-1}; i++)); do echo "node-${i}   Ready   <none>   1d   v1.33.1"; done
  exit 0
fi
exit 0
FAKE
chmod +x "${FAKE_BIN}/kubectl"
# The library runs with PATH set to FAKE_BIN only and HOME set to the scratch
# dir (bash may source ~/.bashrc when stdin is a socket, which can rewrite
# PATH), so a real kubectl on the host can never be reached. Link in the few
# real tools it needs.
for tool in bash git cat wc tr; do
  ln -s "$(command -v "$tool")" "${FAKE_BIN}/${tool}"
done

export FAKE_STATE="${WORK}/state"
mkdir -p "$FAKE_STATE"

# Run a library function in a clean env (no inherited FOUNDATIONS_* vars).
# Extra NAME=value arguments before "--" are exported into that env.
# Captures stdout in $OUT, stderr in $ERR, and the return code in $RC.
run_lib() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  rm -f "${FAKE_STATE}/applied"
  set +e
  OUT="$(
    env -i HOME="${WORK}" PATH="${FAKE_BIN}" FAKE_STATE="$FAKE_STATE" ROOT_DIR="$ROOT_DIR" \
      ${envs[@]+"${envs[@]}"} \
      bash -c '
        set -euo pipefail
        source "${ROOT_DIR}/bootstrap/lib/contract.sh"
        "$@"
      ' _ "$@" 2>"${WORK}/stderr"
  )"
  RC=$?
  set -e
  ERR="$(cat "${WORK}/stderr")"
}

# field <name>: value of data.<name> in $OUT (quotes stripped)
field() {
  awk -v k="$1" '$1 == k":" { v = $2; gsub(/"/, "", v); print v; exit }' <<<"$OUT"
}

# data_keys: sorted data.* key names in $OUT
data_keys() {
  awk '/^data:/{d=1; next} d && /^  [a-z0-9_]+:/{sub(/:.*/, ""); sub(/^  /, ""); print}' <<<"$OUT" | sort | tr '\n' ' '
}

expect_field() {
  local name="$1" want="$2" got
  got="$(field "$name")"
  if [[ "$got" == "$want" ]]; then pass "${name}=${want}"
  else fail "${name}: expected '${want}', got '${got:-<missing>}'"; fi
}

# ─── 1. default render ───
section "1. default render is the single-node baseline"
run_lib -- render_foundations_contract_marker managed
if [[ "$RC" -eq 0 ]]; then pass "renders (rc=0)"
else fail "render failed (rc=$RC): $ERR"; fi
expect_field install_mode managed
expect_field foundations_series 2.x
expect_field decks_v0_supported true
expect_field policy_exception_support true
expect_field topology_mode single-node
expect_field topology_support_level baseline
expect_field supported_node_min 1
expect_field supported_node_max 1
want_keys="contract_version decks_v0_supported foundations_series foundations_version install_mode policy_exception_support supported_node_max supported_node_min topology_mode topology_support_level "
if [[ "$(data_keys)" == "$want_keys" ]]; then pass "default key set unchanged"
else fail "default key set changed: $(data_keys)"; fi

# ─── 2. apply ───
section "2. apply_foundations_contract_marker sends the manifest to kubectl"
run_lib -- apply_foundations_contract_marker managed
if [[ "$RC" -eq 0 ]] && grep -q 'name: rathsted-foundations-contract' "${FAKE_STATE}/applied" 2>/dev/null \
  && grep -q 'topology_mode: "single-node"' "${FAKE_STATE}/applied"; then
  pass "kubectl apply -f - received the marker"
else fail "apply did not reach kubectl (rc=$RC): $ERR"; fi

# ─── 3. install-managed.sh wiring ───
section "3. install-managed.sh publishes through the library"
M="${ROOT_DIR}/bootstrap/install-managed.sh"
if grep -q 'bootstrap/lib/contract.sh' "$M" && grep -qE '^[[:space:]]*apply_foundations_contract_marker "managed"' "$M"; then
  pass "install-managed.sh sources lib/contract.sh and applies the managed marker"
else fail "install-managed.sh does not use lib/contract.sh"; fi
if ! grep -q '^apply_foundations_contract_marker()' "$M"; then pass "no inline copy of the marker in install-managed.sh"
else fail "install-managed.sh still defines its own marker"; fi
check_line="$(grep -nE '^check_contract_node_count "managed"' "$M" | head -1 | cut -d: -f1)"
flux_line="$(grep -nE '^[[:space:]]*flux install' "$M" | head -1 | cut -d: -f1)"
if [[ -n "$check_line" && -n "$flux_line" && "$check_line" -lt "$flux_line" ]]; then
  pass "install-managed.sh checks the topology contract before installing Flux"
else fail "install-managed.sh does not check the topology contract in preflight (check=${check_line:-none} flux=${flux_line:-none})"; fi

# ─── 4. bounded 3-node, as Decks requests it ───
section "4. managed-3-node-v1 with the Decks bounded-smoke env"
DECKS_ENV=(
  FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1
  FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL=bounded
  FOUNDATIONS_SUPPORTED_NODE_MIN=3
  FOUNDATIONS_SUPPORTED_NODE_MAX=3
  FOUNDATIONS_MULTI_NODE_FOUNDATIONS_SUPPORTED=true
)
run_lib "${DECKS_ENV[@]}" -- render_foundations_contract_marker managed
if [[ "$RC" -eq 0 ]]; then pass "renders (rc=0)"
else fail "render failed (rc=$RC): $ERR"; fi
expect_field install_mode managed
expect_field foundations_series 2.x
expect_field decks_v0_supported true
expect_field topology_mode managed-3-node-v1
expect_field topology_support_level bounded
expect_field supported_node_min 3
expect_field supported_node_max 3

# ─── 5. topology mode alone ───
section "5. managed-3-node-v1 alone derives the bounded contract"
run_lib FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1 -- render_foundations_contract_marker managed
expect_field topology_mode managed-3-node-v1
expect_field topology_support_level bounded
expect_field supported_node_min 3
expect_field supported_node_max 3

run_lib FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=single-node -- render_foundations_contract_marker managed
expect_field topology_mode single-node
expect_field topology_support_level baseline
expect_field supported_node_max 1

# ─── 6. refusals ───
section "6. inconsistent or unknown topology settings are refused"
refused() {
  local label="$1"; shift
  run_lib "$@" -- render_foundations_contract_marker "${INSTALL_MODE:-managed}"
  if [[ "$RC" -ne 0 && -z "$OUT" && -n "$ERR" ]]; then pass "refused: ${label}"
  else fail "published a marker for ${label} (rc=$RC): $(field topology_mode)"; fi
}
refused "unknown topology mode" FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-5-node-v9
refused "3-node with node max 5" FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1 FOUNDATIONS_SUPPORTED_NODE_MAX=5
refused "3-node with level ga" FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1 FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL=ga
refused "3-node with multi-node false" FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1 FOUNDATIONS_MULTI_NODE_FOUNDATIONS_SUPPORTED=false
refused "single-node widened to 3 nodes" FOUNDATIONS_SUPPORTED_NODE_MAX=3
refused "bounded level without a topology mode" FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL=bounded
INSTALL_MODE=self-hosted refused "3-node on the self-hosted install path" FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=managed-3-node-v1

# ─── 7. live node count ───
section "7. apply checks the live node count for the 3-node contract"
run_lib FAKE_NODES=3 "${DECKS_ENV[@]}" -- apply_foundations_contract_marker managed
if [[ "$RC" -eq 0 ]] && grep -q 'topology_mode: "managed-3-node-v1"' "${FAKE_STATE}/applied" 2>/dev/null; then
  pass "3-node contract applied on a 3-node cluster"
else fail "3-node contract not applied on a 3-node cluster (rc=$RC): $ERR"; fi

for n in 1 4; do
  run_lib FAKE_NODES="$n" "${DECKS_ENV[@]}" -- apply_foundations_contract_marker managed
  if [[ "$RC" -ne 0 && ! -f "${FAKE_STATE}/applied" ]] && grep -q "${n}" <<<"$ERR"; then
    pass "3-node contract refused on a ${n}-node cluster, nothing applied"
  else fail "3-node contract on a ${n}-node cluster: rc=$RC applied=$([[ -f "${FAKE_STATE}/applied" ]] && echo yes || echo no)"; fi
done

run_lib FAKE_NODES=3 -- apply_foundations_contract_marker managed
if [[ "$RC" -eq 0 ]] && grep -q 'topology_mode: "single-node"' "${FAKE_STATE}/applied" 2>/dev/null; then
  pass "default single-node marker still applies on a 3-node cluster (no new enforcement)"
else fail "default marker blocked on a 3-node cluster (rc=$RC): $ERR"; fi

run_lib FAKE_NODES=3 FOUNDATIONS_CONTRACT_TOPOLOGY_MODE=bogus -- apply_foundations_contract_marker managed
if [[ "$RC" -ne 0 && ! -f "${FAKE_STATE}/applied" ]]; then pass "invalid settings never reach kubectl apply"
else fail "invalid settings reached kubectl apply (rc=$RC)"; fi

# ─── Summary ───
printf "\n${BOLD}Results: ${GREEN}${PASS} passed${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
  printf "${BOLD}, ${RED}${FAIL} failed${RESET}\n\n"
  exit 1
else
  printf "${BOLD}, 0 failed${RESET}\n\n"
fi
