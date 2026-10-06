#!/usr/bin/env bash
# Shared Kyverno policy helpers for bootstrap/install.sh and bootstrap/verify.sh.
#
# Sourced, not executed. Callers must set ROOT_DIR and define info().
# Kept in one place so scripts/test-bootstrap-guards.sh can exercise the
# logic against a fake kubectl, without a cluster.
#
# expected_policy_names      — print one ClusterPolicy name per line (pure file read)
# policies_present           — return 0 iff every expected name is in the cluster
# apply_policies_with_retry  — apply with retry on any failure, then verify
# wait_for_policies_present  — retries policies_present to tolerate a transient listing lag

# Print the metadata.name of every ClusterPolicy listed under resources: in
# ${ROOT_DIR}/policies/kustomization.yaml.
# Pure file reading — no kubectl, no kustomize. Works with both macOS (BSD) and GNU awk.
expected_policy_names() {
  local kust="${ROOT_DIR}/policies/kustomization.yaml"
  local fname
  while IFS= read -r fname; do
    awk '/^metadata:/{m=1;next} m&&/^  name:/{print $2; exit}' "${ROOT_DIR}/policies/${fname}"
  done < <(awk '/^resources:/{r=1;next} r&&/^  - /{print $2}' "$kust")
}

# Return 0 iff every name from expected_policy_names exists in the cluster.
# Returns non-zero on an empty cluster or when any expected policy is missing.
# kubectl exits 0 with no stdout (and "No resources found" on stderr) when there
# are no ClusterPolicies — that counts as absent.
# Prints missing names to stderr so they appear in evidence logs.
policies_present() {
  local expected cluster name
  local -a missing=()

  expected="$(expected_policy_names | sort)"
  if [[ -z "$expected" ]]; then
    echo "[rathsted] policies_present: no expected policies found in kustomization.yaml" >&2
    return 1
  fi

  # kubectl get cpol -o name prints "clusterpolicy.kyverno.io/NAME" per line,
  # or nothing to stdout when no resources exist (exits 0, message goes to stderr).
  cluster="$(kubectl get cpol -o name 2>/dev/null | sed 's|clusterpolicy.kyverno.io/||' | sort)"

  while IFS= read -r name; do
    if ! printf '%s\n' "$cluster" | grep -qxF "$name"; then
      missing+=("$name")
    fi
  done <<<"$expected"

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[rathsted] policies_present: missing policies:" >&2
    printf '%s\n' "${missing[@]}" >&2
    return 1
  fi
  return 0
}

# Apply Kyverno policies with retry on ANY non-zero exit (not just timeouts).
# Real-world failure: exit 1 from "failed calling webhook ... no endpoints
# available for service kyverno-svc" while Kyverno is still starting up.
# After a successful apply, confirms with policies_present before returning 0.
# If the listing lags the apply (as seen on rocky:9, 2026-10-01: a policy
# reported "created" was absent from the listing taken straight afterwards),
# the function retries rather than treating the lag as a permanent failure.
#
# Configurable via env:
#   RATHSTED_POLICY_APPLY_ATTEMPTS   (default 10)
#   RATHSTED_POLICY_APPLY_DELAY      (seconds between retries, default 10)
apply_policies_with_retry() {
  local max_attempts="${RATHSTED_POLICY_APPLY_ATTEMPTS:-10}"
  local delay="${RATHSTED_POLICY_APPLY_DELAY:-10}"
  local attempt=1
  local rc

  while (( attempt <= max_attempts )); do
    info "Policy apply attempt $attempt/$max_attempts (timeout 60s)..."
    if timeout 60 kubectl apply -k "${ROOT_DIR}/policies"; then
      # Apply exited 0 — confirm the policies actually landed in the cluster.
      if policies_present; then
        return 0
      fi
      # The listing does not yet show all expected policies; this is the
      # read-after-write lag seen on rocky:9. Treat as retryable.
      info "Policies not all listed yet; retrying in ${delay}s..."
    else
      rc=$?
      info "Policy apply failed (exit $rc); retrying in ${delay}s..."
    fi
    if (( attempt < max_attempts )); then sleep "$delay"; fi
    (( attempt++ )) || true
  done

  echo "[rathsted] ERROR: Policies not in place after $max_attempts attempts" >&2
  return 1
}

# Lagging listing seen in compat on rocky:9 2026-10-01 and ubuntu:24.04-prev 2026-10-03.
# Retries policies_present up to RATHSTED_POLICY_PRESENT_ATTEMPTS times (default 5),
# sleeping RATHSTED_POLICY_PRESENT_DELAY seconds between checks (default 3).
# Returns 0 on first success; if that required more than one check, prints a line
# noting that a retry was needed. Returns 1 after the last failed check (missing names
# are printed to stderr by policies_present on each attempt).
# Uses no caller-defined functions (info is not available in verify.sh).
wait_for_policies_present() {
  local max_attempts="${RATHSTED_POLICY_PRESENT_ATTEMPTS:-5}"
  local delay="${RATHSTED_POLICY_PRESENT_DELAY:-3}"
  local attempt=1

  while (( attempt <= max_attempts )); do
    if policies_present; then
      if (( attempt > 1 )); then
        echo "[rathsted] policies listed on check ${attempt} of ${max_attempts} (retried; listing lagged)"
      fi
      return 0
    fi
    if (( attempt < max_attempts )); then
      sleep "$delay"
    fi
    (( attempt++ )) || true
  done

  return 1
}
