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
#  12. the supported-OS gate (bootstrap/lib/os.sh) accepts Ubuntu
#      22.04/24.04/26.04, Debian 12/13 and Rocky/Alma/RHEL 9/10, and refuses
#      other releases, CentOS Stream, and an os-release with no VERSION_ID
#  13. on an EL10 host whose kernel cannot resolve nft_compat and an xt_
#      module, the matching *-modules-extra build of the kernel's own package
#      (kernel, kernel-64k, kernel-debug, ...) is installed (RHEL 10 moved those
#      modules there), and a failed install is a clear stop; modules that
#      already resolve, a kernel no package owns, EL9 and Debian-family hosts
#      are left alone
#  14. verify records the host's SELinux mode (getenforce, or "not present")
#      and Secure Boot state (mokutil, else the EFI variable, else "not EFI")
#      in its Environment section, so compat evidence carries both
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

section "12. supported-OS gate"
OSDIR="${WORK}/os-release"
mkdir -p "$OSDIR"
# os_case <expect: ok|refuse> <family-or-empty> <ID> [VERSION_ID]
os_case() {
  local expect="$1" family="$2" id="$3" ver="${4-}" f out rc
  f="${OSDIR}/${id}-${ver:-none}"
  { echo "ID=${id}"; [[ -n "$ver" ]] && echo "VERSION_ID=\"${ver}\""; echo "PRETTY_NAME=\"${id} ${ver}\""; } > "$f"
  set +e
  out="$(env -i HOME="$WORK" PATH=/usr/bin:/bin ROOT_DIR="$ROOT_DIR" bash -c '
    set -euo pipefail
    source "${ROOT_DIR}/bootstrap/lib/os.sh"
    detect_supported_os "$1"
    echo "FAMILY=${OS_FAMILY}"' _ "$f" 2>&1 </dev/null)"
  rc=$?
  set -e
  if [[ "$expect" == ok ]]; then
    if [[ "$rc" -eq 0 ]] && grep -qx "FAMILY=${family}" <<<"$out"; then pass "accepts ${id} ${ver} (${family} family)"
    else fail "${id} ${ver}: expected ${family}, rc=$rc: $(tr '\n' ' ' <<<"$out")"; fi
  else
    if [[ "$rc" -ne 0 ]] && grep -q 'Unsupported OS' <<<"$out" && grep -q 'Ubuntu 22.04/24.04/26.04' <<<"$out" \
       && ! grep -qE 'unbound variable|command not found' <<<"$out"; then pass "refuses ${id} ${ver:-without VERSION_ID} and names the supported releases"
    else fail "${id} ${ver:-without VERSION_ID}: expected a refusal, rc=$rc: $(tr '\n' ' ' <<<"$out")"; fi
  fi
}
os_case ok debian ubuntu 22.04
os_case ok debian ubuntu 24.04
os_case ok debian ubuntu 26.04
os_case ok debian debian 12
os_case ok debian debian 13
os_case ok rhel rocky 9.6
os_case ok rhel rocky 10.0
os_case ok rhel rocky 10.1
os_case ok rhel almalinux 9.7
os_case ok rhel almalinux 10.0
os_case ok rhel rhel 9.6
os_case ok rhel rhel 10.1
os_case refuse "" ubuntu 20.04
os_case refuse "" ubuntu 25.10
os_case refuse "" debian 11
os_case refuse "" debian ""
os_case refuse "" rocky 8.10
os_case refuse "" almalinux 8.10
os_case refuse "" rhel 8.10
os_case refuse "" rocky 11.0
os_case refuse "" fedora 43
os_case refuse "" arch ""
os_case refuse "" centos 9
os_case refuse "" centos 10
f="${OSDIR}/centos-10"
out="$(env -i HOME="$WORK" PATH=/usr/bin:/bin ROOT_DIR="$ROOT_DIR" bash -c 'source "${ROOT_DIR}/bootstrap/lib/os.sh"; detect_supported_os "$1"' _ "$f" 2>&1 </dev/null || true)"
if grep -q 'CentOS Stream' <<<"$out"; then pass "the refusal names CentOS Stream as not supported"
else fail "the refusal does not name CentOS Stream: $out"; fi

section "13. EL10 kernel-modules-extra for k3s"
KBIN="${WORK}/kbin"
mkdir -p "$KBIN"
# Fakes, driven by env; every call is logged to $FAKE_STATE/kme_calls.
#   FAKE_UNAME   uname -r output
#   FAKE_MODS    present | missing  (modprobe -n -q resolves the modules)
#   FAKE_KOWNER  "NAME VERSION-RELEASE.ARCH" printed by rpm -qf --qf, or
#                "none" when no package owns the kernel
#   FAKE_KME     installed | missing  (rpm -q of the extra package)
#   FAKE_DNF     ok | fail
cat > "${KBIN}/uname" <<'FAKE'
#!/bin/sh
echo "$FAKE_UNAME"
FAKE
cat > "${KBIN}/modprobe" <<'FAKE'
#!/bin/sh
echo "modprobe $*" >> "${FAKE_STATE}/kme_calls"
[ "$FAKE_MODS" = present ]
FAKE
cat > "${KBIN}/rpm" <<'FAKE'
#!/bin/sh
echo "rpm $*" >> "${FAKE_STATE}/kme_calls"
if [ "$1" = -qf ]; then
  [ "$FAKE_KOWNER" = none ] && exit 1
  printf '%b\n' "$FAKE_KOWNER"; exit 0
fi
[ "$FAKE_KME" = installed ]
FAKE
cat > "${KBIN}/dnf" <<'FAKE'
#!/bin/sh
echo "dnf $*" >> "${FAKE_STATE}/kme_calls"
[ "$FAKE_DNF" != fail ]
FAKE
chmod +x "${KBIN}/uname" "${KBIN}/modprobe" "${KBIN}/rpm" "${KBIN}/dnf"
X86_UNAME="6.12.0-55.el10.x86_64"
X86_OWNER="kernel-core 6.12.0-55.el10.x86_64"
# kme <family> <VERSION_ID> <FAKE_MODS> <FAKE_KME> <FAKE_DNF> [FAKE_UNAME] [FAKE_KOWNER]
kme() {
  : > "${FAKE_STATE}/kme_calls"
  set +e
  OUT="$(env -i HOME="$WORK" PATH="${KBIN}:/usr/bin:/bin" ROOT_DIR="$ROOT_DIR" FAKE_STATE="$FAKE_STATE" \
    FAKE_MODS="$3" FAKE_KME="$4" FAKE_DNF="$5" FAKE_UNAME="${6:-$X86_UNAME}" FAKE_KOWNER="${7:-$X86_OWNER}" \
    OS_FAMILY="$1" OS_VERSION_ID="$2" bash -c '
    set -euo pipefail
    source "${ROOT_DIR}/bootstrap/lib/os.sh"
    ensure_k3s_kernel_modules' 2>&1 </dev/null)"
  RC=$?
  set -e
  KCALLS="$(cat "${FAKE_STATE}/kme_calls")"
}
kme rhel 10.0 missing missing ok
if [[ "$RC" -eq 0 ]] && grep -qx 'dnf install -y kernel-modules-extra-6.12.0-55.el10.x86_64' <<<"$KCALLS"; then
  pass "EL10, modules missing: installs kernel-modules-extra for the running kernel"
else fail "EL10 missing modules: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS") out: $OUT"; fi
kme rhel 10.0 missing missing ok "6.12.0-55.el10.aarch64+64k" "kernel-64k-core 6.12.0-55.el10.aarch64"
if [[ "$RC" -eq 0 ]] && grep -qx 'dnf install -y kernel-64k-modules-extra-6.12.0-55.el10.aarch64' <<<"$KCALLS"; then
  pass "EL10 64k variant kernel: installs the matching kernel-64k-modules-extra build"
else fail "EL10 64k kernel: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS") out: $OUT"; fi
kme rhel 10.1 missing missing ok "6.12.0-55.el10.x86_64+debug" "kernel-debug-core 6.12.0-55.el10.x86_64"
if [[ "$RC" -eq 0 ]] && grep -qx 'dnf install -y kernel-debug-modules-extra-6.12.0-55.el10.x86_64' <<<"$KCALLS"; then
  pass "EL10 debug variant kernel: installs kernel-debug-modules-extra"
else fail "EL10 debug kernel: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS") out: $OUT"; fi
kme rhel 10.0 missing missing ok "$X86_UNAME" "kernel-core 6.12.0-55.el10.x86_64\\nkernel-core 6.12.0-55.el10.x86_64"
if [[ "$RC" -eq 0 && "$(tail -1 <<<"$KCALLS")" == 'dnf install -y kernel-modules-extra-6.12.0-55.el10.x86_64' ]] \
   && ! grep -qx 'kernel-core.*' <<<"$KCALLS"; then
  pass "EL10 when rpm -qf prints more than one owner line: uses the first"
else fail "EL10 two owner lines: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS") out: $OUT"; fi
kme rhel 10.0 present missing ok
if [[ "$RC" -eq 0 ]] && ! grep -qE '^(rpm|dnf) ' <<<"$KCALLS"; then pass "EL10, modules already resolve: no rpm or dnf call"
else fail "EL10 modules present: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS")"; fi
if grep -q '^modprobe -n -q nft_compat' <<<"$KCALLS" && grep -qE '^modprobe -n -q xt_' <<<"$KCALLS"; then
  pass "EL10, modules present: checked nft_compat and an xt_ module with modprobe -n -q"
else fail "EL10: no modprobe dry run for nft_compat and an xt_ module: $(tr '\n' '|' <<<"$KCALLS")"; fi
kme rhel 10.1 missing installed ok
if [[ "$RC" -eq 0 ]] && ! grep -q '^dnf ' <<<"$KCALLS"; then pass "EL10 with the package already installed: no dnf call"
else fail "EL10 installed: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS")"; fi
kme rhel 10.0 missing missing fail
if [[ "$RC" -ne 0 ]] && grep -q 'kernel-modules-extra-6.12.0-55.el10.x86_64' <<<"$OUT" && ! grep -q 'command not found' <<<"$OUT"; then
  pass "EL10 when dnf cannot install it: fails and names the package"
else fail "EL10 dnf failure: rc=$RC out: $OUT"; fi
kme rhel 10.0 missing missing fail "6.12.0-55.el10.aarch64+64k" "kernel-64k-core 6.12.0-55.el10.aarch64"
if [[ "$RC" -ne 0 ]] && grep -q 'kernel-64k-modules-extra-6.12.0-55.el10.aarch64' <<<"$OUT"; then
  pass "EL10 64k variant when dnf fails: fails and names the variant package"
else fail "EL10 64k dnf failure: rc=$RC out: $OUT"; fi
kme rhel 10.0 missing missing ok "$X86_UNAME" none
if [[ "$RC" -eq 0 ]] && ! grep -q '^dnf ' <<<"$KCALLS" && grep -q 'not a distribution package' <<<"$OUT"; then
  pass "EL10 on a kernel no package owns (VM platform or custom kernel): skips with a message, no dnf call"
else fail "EL10 unowned kernel: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS") out: $OUT"; fi
kme rhel 9.6 missing missing ok
if [[ "$RC" -eq 0 && -z "$KCALLS" ]]; then pass "EL9: no check (the modules are in kernel-modules-core)"
else fail "EL9: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS")"; fi
kme debian 13 missing missing ok
if [[ "$RC" -eq 0 && -z "$KCALLS" ]]; then pass "Debian family: no modprobe, rpm or dnf call"
else fail "Debian family: rc=$RC calls: $(tr '\n' '|' <<<"$KCALLS")"; fi
if grep -nE '^[[:space:]]*ensure_k3s_kernel_modules' "${ROOT_DIR}/bootstrap/install.sh" >/dev/null; then
  k="$(grep -nE '^[[:space:]]*ensure_k3s_kernel_modules' "${ROOT_DIR}/bootstrap/install.sh" | head -1 | cut -d: -f1)"
  i="$(grep -nE 'bash "\$\{k3s_tmpdir\}/k3s-install.sh"' "${ROOT_DIR}/bootstrap/install.sh" | head -1 | cut -d: -f1)"
  if [[ -n "$i" && "$k" -lt "$i" ]]; then pass "install.sh ensures the kernel modules before it runs the k3s installer"
  else fail "install.sh: ensure_k3s_kernel_modules line $k, k3s installer line ${i:-none}"; fi
else fail "install.sh does not call ensure_k3s_kernel_modules"; fi

section "14. SELinux mode and Secure Boot state"
SBIN="${WORK}/sbin"; mkdir -p "$SBIN"
FW="${WORK}/fw"
# Only the tools the functions need, so a host's own getenforce or mokutil
# (GitHub's Ubuntu runners ship mokutil) cannot answer instead of the fakes.
TOOLS="${WORK}/tools"; mkdir -p "$TOOLS"
for t in bash od tr; do ln -sf "$(command -v "$t")" "${TOOLS}/${t}"; done
# hs <getenforce output or ""> <mokutil output or ""> <efivar byte or "" or noefi>
hs() {
  rm -rf "${SBIN:?}" "${FW:?}"; mkdir -p "$SBIN"
  [[ -n "$1" ]] && printf '#!/bin/sh\necho %s\n' "$1" > "${SBIN}/getenforce"
  [[ -n "$2" ]] && printf '#!/bin/sh\necho "%s"\n' "$2" > "${SBIN}/mokutil"
  chmod +x "$SBIN"/* 2>/dev/null || true
  if [[ "$3" != noefi ]]; then
    mkdir -p "${FW}/efi/efivars"
    [[ -n "$3" ]] && printf "\x07\x00\x00\x00\x${3}" > "${FW}/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  fi
  OUT="$(env -i HOME="$WORK" PATH="${SBIN}:${TOOLS}" ROOT_DIR="$ROOT_DIR" FW="$FW" "${TOOLS}/bash" -c '
    set -euo pipefail
    source "${ROOT_DIR}/bootstrap/lib/os.sh"
    echo "selinux=$(host_selinux_mode)"
    echo "secureboot=$(host_secure_boot "$FW")"' 2>&1 </dev/null || true)"
}
hs Enforcing "SecureBoot enabled" 01
if grep -qx 'selinux=Enforcing' <<<"$OUT" && grep -qx 'secureboot=enabled' <<<"$OUT"; then pass "getenforce and mokutil: Enforcing, enabled"
else fail "getenforce/mokutil: $OUT"; fi
hs Permissive "" 00
if grep -qx 'selinux=Permissive' <<<"$OUT" && grep -qx 'secureboot=disabled' <<<"$OUT"; then pass "no mokutil: reads the SecureBoot EFI variable (disabled)"
else fail "efivar disabled: $OUT"; fi
hs "" "" 01
if grep -qx 'selinux=not present' <<<"$OUT" && grep -qx 'secureboot=enabled' <<<"$OUT"; then pass "no getenforce: 'not present'; EFI variable enabled"
else fail "no getenforce: $OUT"; fi
hs "" "" noefi
if grep -qx 'secureboot=not EFI' <<<"$OUT"; then pass "no EFI firmware: 'not EFI'"
else fail "no EFI: $OUT"; fi
hs "" "" ""
if grep -qx 'secureboot=unknown' <<<"$OUT"; then pass "EFI without a readable SecureBoot variable: 'unknown'"
else fail "EFI no var: $OUT"; fi
if grep -q 'SELinux:.*host_selinux_mode' "${ROOT_DIR}/bootstrap/verify.sh" && grep -q 'Secure Boot:.*host_secure_boot' "${ROOT_DIR}/bootstrap/verify.sh"; then
  pass "verify.sh prints both in its Environment section"
else fail "verify.sh does not print the SELinux mode and Secure Boot state"; fi

# ─── Summary ───
printf "\n${BOLD}Results: ${GREEN}${PASS} passed${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
  printf "${BOLD}, ${RED}${FAIL} failed${RESET}\n\n"
  exit 1
else
  printf "${BOLD}, 0 failed${RESET}\n\n"
fi
