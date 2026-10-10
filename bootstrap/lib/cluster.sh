#!/usr/bin/env bash
# bootstrap/lib/cluster.sh — Kubernetes cluster readiness helpers.
# Source this file; do not execute directly.
# Compatible with bash 3.2+.  Safe under set -euo pipefail.

# wait_for_api — poll the Kubernetes API until /readyz responds successfully
# and at least one node reports Ready.
#
# Elapsed time is tracked by accumulating the fixed sleep interval so the
# function works correctly when sleep(1) is stubbed to a no-op (e.g. in CI
# behaviour tests).  date(1) and $SECONDS are not used.
#
# Environment:
#   RATHSTED_API_WAIT_SECONDS  total budget in seconds (default: 180)
#
# Returns:
#   0  API is ready and at least one node is Ready
#   1  timed out; a diagnostic is printed to stderr
wait_for_api() {
  local timeout="${RATHSTED_API_WAIT_SECONDS:-180}"
  local interval=2
  local elapsed=0

  # Phase 1 — wait for the API server to accept requests at /readyz.
  while true; do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      break
    fi
    if [[ "${elapsed}" -ge "${timeout}" ]]; then
      echo "[rathsted] Kubernetes API not ready after ${timeout}s — check k3s status" >&2
      return 1
    fi
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
  done

  # Phase 2 — wait for at least one node object to appear in the API.
  # On a fast host /readyz can pass before the node is registered, which
  # causes `kubectl wait --all` to fail immediately with "no resources found".
  local _nodes=""
  while [[ -z "${_nodes}" ]]; do
    _nodes="$(kubectl get nodes --no-headers 2>/dev/null || true)"
    if [[ -z "${_nodes}" ]]; then
      if [[ "${elapsed}" -ge "${timeout}" ]]; then
        echo "[rathsted] No cluster node appeared within ${timeout}s" >&2
        return 1
      fi
      sleep "${interval}"
      elapsed=$(( elapsed + interval ))
    fi
  done

  # Phase 3 — wait for the node to reach Ready condition.
  if ! kubectl wait --for=condition=Ready node --all \
      --timeout="${timeout}s" >/dev/null 2>&1; then
    echo "[rathsted] Nodes did not become Ready within ${timeout}s" >&2
    return 1
  fi
}
