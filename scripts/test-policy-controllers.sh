#!/usr/bin/env bash
# test-policy-controllers.sh: container-level policies deny non-compliant Pod
# controllers at admission, not only their Pods, without a cluster.
#
# Found 2026-11-18: disallow-privileged, drop-all-capabilities, require-seccomp
# and require-readonly-rootfs iterate request.object.spec.containers with
# foreach; disallow-host-namespaces and restrict-hostpath match spec.hostNetwork
# and spec.volumes with conditional anchors. Each listed Pod and the
# controllers in one rule, which turns Kyverno autogen off, so on a Deployment
# the foreach list is empty and the anchors find nothing: a privileged,
# hostNetwork Deployment was admitted and only its Pods were denied later, by
# the ReplicaSet controller.
#
# kyverno test (CLI v1.19.1) reports an expected result whose rule produced no
# response as Pass/Excluded, so tests/kyverno/controllers/kyverno-test.yaml
# alone cannot catch a rule that never runs. This script counts real responses
# from kyverno apply:
#
#   1. each bad-* fixture (Pod, Deployment, StatefulSet, DaemonSet, Job,
#      CronJob, ReplicationController) fails every rule of every policy above,
#      under the rule name Kyverno gives it: <rule> for Pod, autogen-<rule>
#      for Deployment, StatefulSet, DaemonSet, Job and ReplicationController,
#      autogen-cronjob-<rule> for CronJob
#   1b. each badinit-* fixture (compliant main container, violating
#      initContainer) fails every rule of the four container-level policies
#      under the same rule names, so dropping initContainers from a policy
#      fails the check
#   2. each good-* fixture passes every rule: the pass count equals rules x
#      fixtures, so a rule that is skipped or never evaluated fails the check
#   3. each policy matches Pod only and pins autogen to the controllers the
#      rule used to list plus ReplicationController, as the default autogen
#      of the other Pod policies does (ReplicaSet is in Kyverno's
#      resourceFilters): DaemonSet,Deployment,Job,StatefulSet,
#      ReplicationController,CronJob
#   4. the controller manifests Foundations ships (examples, the app-runtime
#      profile, the GitOps demo app, plus EXTRA_MANIFESTS) are admitted by
#      these policies with the repo's PolicyExceptions (plus EXTRA_EXCEPTIONS),
#      which name the autogen rules; only exceptions in the kyverno namespace
#      count (Kyverno ignores the others, kyverno apply does not) and any other
#      fails the check; the exception set is load-bearing: some policy admits
#      the manifests only with it
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="${ROOT}/tests/kyverno/controllers/resources"

PASS=0
FAIL=0

GREEN='\033[32m' RED='\033[31m' BOLD='\033[1m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN='' RED='' BOLD='' RESET=''; }

pass() { printf '%b✓%b %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS + 1)); }
fail() { printf '%b✗%b %s\n' "$RED" "$RESET" "$1" >&2; FAIL=$((FAIL + 1)); }

command -v kyverno >/dev/null 2>&1 || { echo "kyverno CLI not found" >&2; exit 1; }

# policy file (without .yaml) and its rule names
POLICIES=(
  "disallow-privileged:privileged"
  "drop-all-capabilities:require-drop-all,restrict-added-capabilities"
  "require-seccomp:seccomp-profile"
  "require-readonly-rootfs:readonly-root-filesystem"
  "disallow-host-namespaces:host-namespaces"
  "restrict-hostpath:hostpath"
)
# fixture suffix and kind
KINDS=(pod:Pod deployment:Deployment statefulset:StatefulSet daemonset:DaemonSet job:Job cronjob:CronJob
  replicationcontroller:ReplicationController)
AUTOGEN="DaemonSet,Deployment,Job,StatefulSet,ReplicationController,CronJob"

rule_name() {
  case "$1" in
    Pod) printf '%s' "$2" ;;
    CronJob) printf 'autogen-cronjob-%s' "$2" ;;
    *) printf 'autogen-%s' "$2" ;;
  esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for entry in "${POLICIES[@]}"; do
  policy="${entry%%:*}"
  IFS=',' read -r -a rules <<<"${entry#*:}"
  file="${ROOT}/policies/${policy}.yaml"

  # 3. Pod-only match, explicit autogen controllers (grep, no PyYAML: the
  # public CI runner does not install it)
  if grep -qxF "    pod-policies.kyverno.io/autogen-controllers: ${AUTOGEN}" "$file" \
    && grep -qE '^ +- Pod$' "$file" \
    && ! grep -qE '^ +- (Deployment|StatefulSet|DaemonSet|Job|CronJob|ReplicaSet|ReplicationController)$' "$file"
  then pass "${policy}: every rule matches Pod only; autogen-controllers is ${AUTOGEN}"
  else fail "${policy}: rules must match Pod only with autogen-controllers ${AUTOGEN}"; fi

  qualities=(bad good)
  # container-level policies: badinit-* fixtures (compliant main container,
  # violating initContainer) must be denied too
  case "$policy" in disallow-host-namespaces|restrict-hostpath) ;; *) qualities+=(badinit) ;; esac
  for quality in "${qualities[@]}"; do
    args=()
    for k in "${KINDS[@]}"; do args+=(-r "${RES}/${quality}-${k%%:*}.yaml"); done
    out="${WORK}/${policy}-${quality}.txt"
    kyverno apply "$file" "${args[@]}" --remove-color >"$out" 2>&1 || true
    summary="$(grep -E '^pass: [0-9]+, fail: [0-9]+' "$out" || true)"
    if [[ -z "$summary" ]]; then
      fail "${policy} ${quality}: kyverno apply printed no summary"
      sed 's/^/    /' "$out" >&2
      continue
    fi
    npass="$(sed -E 's/^pass: ([0-9]+), fail: ([0-9]+).*/\1/' <<<"$summary")"
    nfail="$(sed -E 's/^pass: ([0-9]+), fail: ([0-9]+).*/\2/' <<<"$summary")"
    want=$(( ${#rules[@]} * ${#KINDS[@]} ))

    if [[ "$quality" == good ]]; then
      if [[ "$nfail" -eq 0 && "$npass" -eq "$want" ]]; then
        pass "${policy}: compliant Pod and controllers admitted (${npass}/${want} rule passes)"
      else
        fail "${policy}: compliant fixtures want ${want} passes, 0 fails; got ${summary}"
      fi
      continue
    fi

    # 1. bad, badinit: every (kind, rule) pair fails under its rule name
    if [[ "$nfail" -ne "$want" ]]; then
      fail "${policy}: non-compliant fixtures want ${want} fails; got ${summary}"
    fi
    for k in "${KINDS[@]}"; do
      kind="${k#*:}"
      name="${quality}-${k%%:*}"
      for r in "${rules[@]}"; do
        rn="$(rule_name "$kind" "$r")"
        # kyverno apply prints the failing resource, then one line per rule
        if awk -v res="default/${kind}/${name} failed:" -v rn="$rn" '
            index($0, "-> resource " res) { inres = 1; next }
            /^policy / { inres = 0 }
            inres && $0 ~ ("^[0-9]+ - " rn " ") { found = 1 }
            END { exit !found }' "$out"; then
          pass "${policy}: ${kind} ${name} denied by ${rn}"
        else
          fail "${policy}: ${kind} ${name} not denied by ${rn}"
        fi
      done
    done
  done
done

# 4. shipped controllers admitted with the shipped exceptions.
# EXTRA_MANIFESTS and EXTRA_EXCEPTIONS (space-separated paths relative to the
# repo root) add files to both lists.
read -r -a extra_m <<<"${EXTRA_MANIFESTS:-}"
read -r -a extra_e <<<"${EXTRA_EXCEPTIONS:-}"
MANIFESTS=(
  examples/customer-instance/cluster/apps/example-app.yaml
  examples/hello-gitops-app/deployment.yaml
  profiles/app-runtime/demo-api.yaml
  profiles/app-runtime/demo-worker.yaml
  profiles/app-runtime/nats.yaml
  profiles/app-runtime/postgres.yaml
  profiles/app-runtime/smoke-test.yaml
  profiles/app-runtime/traefik.yaml
  ${extra_m[@]+"${extra_m[@]}"}
)
EXCEPTION_FILES=(
  profiles/app-runtime/policy-exception.yaml
  cluster/gitops/apps/hello-gitops-registry-exception.yaml
  ${extra_e[@]+"${extra_e[@]}"}
)
for f in "${MANIFESTS[@]}" "${EXCEPTION_FILES[@]}"; do
  [[ -f "${ROOT}/${f}" ]] || fail "${f}: listed for check 4 but missing"
done
printf '\n%bcheck 4: %s controller manifest files, %s exception files%b\n' \
  "$BOLD" "${#MANIFESTS[@]}" "${#EXCEPTION_FILES[@]}" "$RESET"
# A Makefile that defines extra lists means this tree has more manifests than
# the built-in ones; running the script directly skips them.
if [[ -z "${EXTRA_MANIFESTS:-}${EXTRA_EXCEPTIONS:-}" ]] \
  && grep -qE '^POLICY_TEST_EXTRA_(MANIFESTS|EXCEPTIONS) *:?=' "${ROOT}/Makefile" 2>/dev/null; then
  printf '%bWARNING%b EXTRA_MANIFESTS and EXTRA_EXCEPTIONS are unset, but the Makefile lists extra ones (POLICY_TEST_EXTRA_*): those manifests are SKIPPED. Run make policy-test.\n' "$RED" "$RESET" >&2
fi
# kyverno apply --exception wants files holding only PolicyExceptions:
# keep the PolicyException documents of each file
: >"${WORK}/exceptions.yaml"
for e in "${EXCEPTION_FILES[@]}"; do
  [[ -f "${ROOT}/${e}" ]] || continue
  # Kyverno runs with --exceptionNamespace=kyverno: an exception in any other
  # namespace is ignored in the cluster, while kyverno apply --exception
  # honours it. Keep only exceptions in kyverno and fail on any other.
  if ! awk -v src="$e" '
    function flush() {
      if (doc ~ /\nkind: PolicyException\n/) {
        if (ns == "kyverno") printf "---%s", doc
        else { printf "%s: PolicyException %s is in namespace \"%s\", not kyverno: Kyverno ignores it\n", src, name, ns > "/dev/stderr"; bad = 1 }
      }
      doc = "\n"; ns = ""; name = ""; meta = 0
    }
    BEGIN { doc = "\n" }
    /^---/ { flush(); next }
    /^metadata:/ { meta = 1 }
    /^[a-z]/ && !/^metadata:/ { meta = 0 }
    meta && /^  namespace:/ { ns = $2; gsub(/["\047]/, "", ns) }
    meta && /^  name:/ { name = $2 }
    { doc = doc $0 "\n" }
    END { flush(); exit bad }' "${ROOT}/${e}" >>"${WORK}/exceptions.yaml" 2>"${WORK}/ns.err"; then
    fail "$(cat "${WORK}/ns.err")"
  fi
done
if grep -q '^kind: PolicyException$' "${WORK}/exceptions.yaml"; then
  pass "$(grep -c '^kind: PolicyException$' "${WORK}/exceptions.yaml") shipped PolicyExceptions loaded; ${#MANIFESTS[@]} controller manifests"
else
  fail "no shipped PolicyException found"
fi
margs=()
for m in "${MANIFESTS[@]}"; do
  if [[ -f "${ROOT}/${m}" ]]; then margs+=(-r "${ROOT}/${m}"); fi
done
denied_without=0
for entry in "${POLICIES[@]}"; do
  policy="${entry%%:*}"
  file="${ROOT}/policies/${policy}.yaml"
  out="${WORK}/${policy}-shipped.txt"
  kyverno apply "$file" ${margs[@]+"${margs[@]}"} --exception "${WORK}/exceptions.yaml" --remove-color >"$out" 2>&1 || true
  summary="$(grep -E '^pass: [0-9]+, fail: [0-9]+' "$out" || true)"
  admitted=0
  if [[ -n "$summary" && "$summary" == *"fail: 0, warn: 0, error: 0"* ]] && ! grep -q '^policy ' "$out"; then
    admitted=1
    pass "${policy}: shipped controllers admitted with the shipped exceptions (${summary% })"
  else
    fail "${policy}: shipped controllers denied with the shipped exceptions"
    grep -E '^policy |^[0-9]+ - |^pass:|rror' "$out" | sed 's/^/    /' >&2
  fi
  out="${WORK}/${policy}-shipped-noexc.txt"
  kyverno apply "$file" ${margs[@]+"${margs[@]}"} --remove-color >"$out" 2>&1 || true
  if [[ "$admitted" -eq 1 ]] && grep -q '^policy ' "$out"; then denied_without=$((denied_without + 1)); fi
done
if [[ "$denied_without" -gt 0 ]]; then
  pass "${denied_without} policies admit the shipped controllers only with the exceptions (the exceptions are load-bearing)"
else
  fail "no policy needs the exceptions to admit the shipped controllers: the exception check proves nothing"
fi

printf '\n%bResults: %b%s passed%b' "$BOLD" "$GREEN" "$PASS" "$RESET"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%b, %b%s failed%b\n\n' "$BOLD" "$RED" "$FAIL" "$RESET"
  exit 1
else
  printf '%b, 0 failed%b\n\n' "$BOLD" "$RESET"
fi
