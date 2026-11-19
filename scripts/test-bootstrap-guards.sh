#!/usr/bin/env bash
# test-bootstrap-guards.sh — policy-apply and policy-presence guards, without a cluster.
#
# Exercises bootstrap/lib/policies.sh against a fake kubectl so the fail-open
# paths found on rocky:9 (2026-09-21) stay fixed:
#
#   1. expected_policy_names reads the ClusterPolicy names from policies/
#   2. policies_present is false on an empty cluster ("No resources found", exit 0)
#   3. policies_present is false when only some policies landed
#   4. apply_policies_with_retry retries a transient "no endpoints" failure
#   5. apply_policies_with_retry returns non-zero when every attempt fails
#   6. apply_policies_with_retry returns non-zero when apply "succeeds" but
#      the policies are not in the cluster
#   7. the exhausted-retries path reports cleanly (no "command not found")
#   8. a policy that is listed a moment after apply is waited for, not
#      treated as missing (compat rocky:9, 2026-10-01: require-resources was
#      "created" but absent from the listing taken straight afterwards)
#   9. verify's presence check waits out a lagging listing the same way, says
#      so in its output, and still fails when a policy never appears
#      (compat ubuntu:24.04-prev, 2026-10-03: require-seccomp absent from one
#      listing two minutes after a clean install)
#  10. apply_policies_with_retry applies ${ROOT_DIR}/policies by default and
#      the directory it is given otherwise (a RATHSTED_OPERATOR_CONTROL render)
#  11. verify's --release vulnerability gate reports a blocked or missing scan
#      as a warning, sets FAIL=1 and carries on to the Summary (it called
#      `fail`, which only install.sh defines: under set -e verify died there
#      with "command not found" and never printed its Summary)
#
# Usage:
#   ./scripts/test-bootstrap-guards.sh

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

# ─── Fake binaries: kubectl, timeout, sleep ───
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"

# kubectl behaviour is driven by env:
#   FAKE_APPLY   ok | fail | timeout | fail-then-ok:N
#   FAKE_CPOL    all | none | partial | lag:N
#                (lag:N — the first N listings omit require-resources, then all)
# Every `apply -k` call is counted in $FAKE_STATE/apply_calls.
cat > "${FAKE_BIN}/kubectl" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "apply" && "$2" == "-k" ]]; then
  n=$(( $(cat "${FAKE_STATE}/apply_calls" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "${FAKE_STATE}/apply_calls"
  echo "$3" >> "${FAKE_STATE}/apply_dirs"
  no_endpoints='Error from server (InternalError): Internal error occurred: failed calling webhook "mutate-policy.kyverno.svc": no endpoints available for service "kyverno-svc"'
  case "$FAKE_APPLY" in
    ok)      exit 0 ;;
    fail)    echo "$no_endpoints" >&2; exit 1 ;;
    timeout) exit 124 ;;
    fail-then-ok:*)
      if (( n <= ${FAKE_APPLY#fail-then-ok:} )); then echo "$no_endpoints" >&2; exit 1; fi
      exit 0 ;;
  esac
fi
if [[ "$1" == "get" && ( "$2" == "cpol" || "$2" == "clusterpolicies" || "$2" == "clusterpolicies.kyverno.io" ) ]]; then
  case "$FAKE_CPOL" in
    none)    echo "No resources found" >&2 ;;
    partial) printf 'clusterpolicy.kyverno.io/%s\n' require-non-root disallow-privileged ;;
    all)     sed 's|^|clusterpolicy.kyverno.io/|' "${FAKE_STATE}/all_names" ;;
    lag:*)
      g=$(( $(cat "${FAKE_STATE}/get_calls" 2>/dev/null || echo 0) + 1 ))
      echo "$g" > "${FAKE_STATE}/get_calls"
      if (( g <= ${FAKE_CPOL#lag:} )); then
        grep -vx 'require-resources' "${FAKE_STATE}/all_names" | sed 's|^|clusterpolicy.kyverno.io/|'
      else
        sed 's|^|clusterpolicy.kyverno.io/|' "${FAKE_STATE}/all_names"
      fi ;;
  esac
  exit 0
fi
# Anything else (waits, rollout status, get pods/endpoints) succeeds quietly.
exit 0
FAKE
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "${FAKE_BIN}/timeout"
printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/sleep"
chmod +x "${FAKE_BIN}"/*

export FAKE_STATE="${WORK}/state"
mkdir -p "$FAKE_STATE"

# The real names, from the policy files themselves — independent of the code under test.
EXPECTED_NAMES="$(for f in $(awk '/^resources:/{r=1;next} r&&/^  - /{print $2}' "${ROOT_DIR}/policies/kustomization.yaml"); do
  awk '/^metadata:/{m=1;next} m&&/^  name:/{print $2; exit}' "${ROOT_DIR}/policies/${f}"
done | sort)"
printf '%s\n' "$EXPECTED_NAMES" > "${FAKE_STATE}/all_names"

# Run a helper from the library in a clean subshell with the fake PATH.
# Captures combined output in $OUT and the return code in $RC.
run_lib() {
  local apply="$1" cpol="$2"; shift 2
  rm -f "${FAKE_STATE}/apply_calls" "${FAKE_STATE}/get_calls" "${FAKE_STATE}/apply_dirs"
  set +e
  OUT="$(
    PATH="${FAKE_BIN}:${PATH}" FAKE_APPLY="$apply" FAKE_CPOL="$cpol" ROOT_DIR="$ROOT_DIR" \
      bash -c '
        set -euo pipefail
        info() { echo "[rathsted] $*"; }
        source "${ROOT_DIR}/bootstrap/lib/policies.sh"
        "$@"
      ' _ "$@" 2>&1
  )"
  RC=$?
  set -e
  CALLS="$(cat "${FAKE_STATE}/apply_calls" 2>/dev/null || echo 0)"
}

# ─── 1. expected_policy_names ───
section "1. expected_policy_names reads the policy files"
run_lib ok all expected_policy_names
if [[ "$RC" -eq 0 && "$(printf '%s\n' "$OUT" | sort)" == "$EXPECTED_NAMES" ]]; then
  pass "expected_policy_names lists all $(printf '%s\n' "$EXPECTED_NAMES" | wc -l | tr -d ' ') ClusterPolicies"
else
  fail "expected_policy_names (rc=$RC) printed: $(echo "$OUT" | tr '\n' ' ')"
fi

# ─── 2–3. policies_present ───
section "2. policies_present on an empty cluster"
run_lib ok none policies_present
if [[ "$RC" -ne 0 ]]; then pass "false when kubectl says 'No resources found' (exit 0)"
else fail "reported present on an empty cluster (false-positive enforced)"; fi

section "3. policies_present with only some policies"
run_lib ok partial policies_present
if [[ "$RC" -ne 0 ]]; then pass "false when 2 of the expected policies exist"
else fail "reported present with a partial policy set"; fi

run_lib ok all policies_present
if [[ "$RC" -eq 0 ]]; then pass "true when every expected policy exists"
else fail "reported absent with the full policy set (rc=$RC): $OUT"; fi

# ─── 4. transient failure is retried ───
section "4. apply_policies_with_retry retries a transient webhook failure"
run_lib fail-then-ok:2 all apply_policies_with_retry
if [[ "$RC" -eq 0 && "$CALLS" -eq 3 ]]; then pass "succeeds on attempt 3 after two 'no endpoints' errors"
else fail "expected rc=0 after 3 apply calls, got rc=$RC after $CALLS call(s)"; fi

# ─── 5. persistent failure is reported ───
section "5. apply_policies_with_retry fails when every attempt fails"
run_lib fail none apply_policies_with_retry
if [[ "$RC" -ne 0 ]]; then pass "returns non-zero"
else fail "returned 0 after a failed apply (install would print Done with no policies)"; fi
if [[ "$CALLS" -gt 1 ]]; then pass "retried ($CALLS attempts)"
else fail "gave up after $CALLS attempt(s) on a non-timeout error"; fi

# ─── 6. apply 'succeeds' but nothing landed ───
section "6. apply_policies_with_retry checks the policies actually exist"
run_lib ok none apply_policies_with_retry
if [[ "$RC" -ne 0 ]]; then pass "non-zero when apply exits 0 but no policies are present"
else fail "returned 0 with no policies in the cluster"; fi

run_lib ok all apply_policies_with_retry
if [[ "$RC" -eq 0 ]]; then pass "returns 0 when apply succeeds and all policies are present"
else fail "failed on a healthy apply (rc=$RC): $OUT"; fi

# ─── 7. exhausted path reports cleanly ───
section "7. exhausted retries report cleanly"
run_lib timeout none apply_policies_with_retry
if [[ "$RC" -ne 0 ]]; then pass "returns non-zero after repeated timeouts"
else fail "returned 0 after repeated timeouts"; fi
if ! grep -q "command not found" <<<"$OUT"; then pass "no 'command not found' on the failure path"
else fail "failure path calls an undefined function: $(grep 'command not found' <<<"$OUT" | head -1)"; fi

# ─── 8. listing lags the apply ───
section "8. apply_policies_with_retry waits for a policy that lists late"
run_lib ok lag:1 apply_policies_with_retry
if [[ "$RC" -eq 0 ]]; then pass "succeeds when require-resources appears on the next listing"
else fail "gave up on a policy that was created but not yet listed (rc=$RC)"; fi

run_lib ok lag:3 apply_policies_with_retry
if [[ "$RC" -eq 0 ]]; then pass "succeeds when the listing lags for several checks"
else fail "gave up while the listing was still catching up (rc=$RC)"; fi

# ─── 9. verify waits for a lagging listing ───
section "9. wait_for_policies_present (verify) tolerates listing lag"
run_lib ok all wait_for_policies_present
if [[ "$RC" -eq 0 ]] && ! grep -qi "retr" <<<"$OUT"; then pass "true at once when every policy is listed, no retry noted"
else fail "full policy set: rc=$RC output: $OUT"; fi

run_lib ok lag:2 wait_for_policies_present
if [[ "$RC" -eq 0 ]]; then pass "true when require-resources appears on the third check"
else fail "gave up on a lagging listing (rc=$RC)"; fi
if grep -qi "retr" <<<"$OUT"; then pass "notes in the output that a retry was needed"
else fail "a lagging listing passed silently; output: $OUT"; fi

run_lib ok none wait_for_policies_present
if [[ "$RC" -ne 0 ]]; then pass "false when the policies never appear"
else fail "reported present on an empty cluster"; fi
if grep -q "require-seccomp" <<<"$OUT"; then pass "names the missing policies when it gives up"
else fail "did not name the missing policies; output: $OUT"; fi

if grep -qE '^if wait_for_policies_present; then' "${ROOT_DIR}/bootstrap/verify.sh"; then
  pass "verify.sh uses wait_for_policies_present"
else fail "verify.sh does not use wait_for_policies_present"; fi

# ─── 10. which directory is applied ───
section "10. apply_policies_with_retry applies the given directory"
run_lib ok all apply_policies_with_retry
if [[ "$RC" -eq 0 && "$(cat "${FAKE_STATE}/apply_dirs")" == "${ROOT_DIR}/policies" ]]; then pass "no argument: applies \${ROOT_DIR}/policies (unchanged)"
else fail "default apply dir: rc=$RC dirs: $(cat "${FAKE_STATE}/apply_dirs" 2>/dev/null)"; fi
run_lib ok all apply_policies_with_retry "${WORK}/rendered"
if [[ "$RC" -eq 0 && "$(cat "${FAKE_STATE}/apply_dirs")" == "${WORK}/rendered" ]]; then pass "with a directory: applies that directory"
else fail "given apply dir: rc=$RC dirs: $(cat "${FAKE_STATE}/apply_dirs" 2>/dev/null)"; fi

# ─── 11. verify's vulnerability gate ───
section "11. verify --release vulnerability gate warns, sets FAIL and continues"
V="${ROOT_DIR}/bootstrap/verify.sh"
# verify.sh's own output helpers, then its vulnerability block, run as verify
# runs (set -euo pipefail) with ROOT_DIR in $WORK so nothing lands in the tree.
{
  grep -E '^(ok|warn|skip|section)\(\) ' "$V"
  awk '/^# Vulnerability scan/{f=1} /^# Enforce signature policy mode/{exit} f' "$V"
  echo 'echo "REACHED FAIL=${FAIL}"'
} > "${WORK}/vuln.sh"
mkdir -p "${WORK}/vroot/supply-chain/sbom/output" "${WORK}/vbin"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == --fail-on ]] && exit 1; done\nexit 0\n' > "${WORK}/vbin/grype"
chmod +x "${WORK}/vbin/grype"
# vuln <label> <PATH prefix> <SBOM_OK>
vuln() {
  local out
  out="$(env -i HOME="$WORK" PATH="$2:/usr/bin:/bin" ROOT_DIR="${WORK}/vroot" RELEASE_MODE=true SBOM_OK="$3" \
    SBOM_OUT="${WORK}/sbom.json" PASS=0 WARN=0 FAIL=0 bash -c 'set -euo pipefail; source "$0"' "${WORK}/vuln.sh" 2>&1)" || true
  if grep -q '^\[warn ' <<<"$out" && grep -q 'REACHED FAIL=1' <<<"$out" && ! grep -q 'command not found' <<<"$out"; then
    pass "$1: a [warn] line, FAIL=1, and verify carries on"
  else fail "$1: $(tr '\n' ' ' <<<"$out" | head -c 300)"; fi
}
vuln "grype finds High+ findings" "${WORK}/vbin" true
vuln "grype or SBOM unavailable" "${WORK}/nogrype" false

# ─── Summary ───
printf "\n${BOLD}Results: ${GREEN}${PASS} passed${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
  printf "${BOLD}, ${RED}${FAIL} failed${RESET}\n\n"
  exit 1
else
  printf "${BOLD}, 0 failed${RESET}\n\n"
fi
