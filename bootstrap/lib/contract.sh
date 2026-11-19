#!/usr/bin/env bash
# Foundations contract marker helpers for bootstrap/install-managed.sh.
#
# Sourced, not executed. Callers must set ROOT_DIR.
# Kept in one place so scripts/test-topology-contract.sh can exercise the
# rendering against a fake kubectl, without a cluster.
#
# resolve_contract_topology           — validate topology env, set CONTRACT_* globals
# render_foundations_contract_marker  — print the ConfigMap manifest
# check_contract_node_count           — live node count inside the contract range
# apply_foundations_contract_marker   — check node count, render, kubectl apply
#
# Topology is selected with FOUNDATIONS_CONTRACT_TOPOLOGY_MODE:
#
#   single-node (default)  topology_support_level=baseline  nodes 1-1
#   managed-3-node-v1      topology_support_level=bounded   nodes 3-3
#                          (managed install mode only)
#
# FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL, FOUNDATIONS_SUPPORTED_NODE_MIN,
# FOUNDATIONS_SUPPORTED_NODE_MAX and FOUNDATIONS_MULTI_NODE_FOUNDATIONS_SUPPORTED
# are accepted so callers can state what they expect, but they must match the
# selected mode. They cannot widen a contract.

# $1: install mode (managed | self-hosted)
# Sets CONTRACT_TOPOLOGY_MODE, CONTRACT_TOPOLOGY_LEVEL, CONTRACT_NODE_MIN,
# CONTRACT_NODE_MAX. Returns non-zero with a message on stderr when the
# requested settings are unknown or inconsistent.
resolve_contract_topology() {
  local install_mode="$1"
  local multi_node name want got
  CONTRACT_TOPOLOGY_MODE="${FOUNDATIONS_CONTRACT_TOPOLOGY_MODE:-single-node}"
  case "${CONTRACT_TOPOLOGY_MODE}" in
    single-node)
      CONTRACT_TOPOLOGY_LEVEL="baseline"; CONTRACT_NODE_MIN="1"; CONTRACT_NODE_MAX="1"; multi_node="false" ;;
    managed-3-node-v1)
      if [[ "${install_mode}" != "managed" ]]; then
        echo "topology managed-3-node-v1 requires the managed install path (bootstrap/install-managed.sh), not ${install_mode}" >&2
        return 1
      fi
      CONTRACT_TOPOLOGY_LEVEL="bounded"; CONTRACT_NODE_MIN="3"; CONTRACT_NODE_MAX="3"; multi_node="true" ;;
    *)
      echo "unsupported FOUNDATIONS_CONTRACT_TOPOLOGY_MODE: ${CONTRACT_TOPOLOGY_MODE} (expected single-node or managed-3-node-v1)" >&2
      return 1 ;;
  esac
  for name in FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL FOUNDATIONS_SUPPORTED_NODE_MIN \
              FOUNDATIONS_SUPPORTED_NODE_MAX FOUNDATIONS_MULTI_NODE_FOUNDATIONS_SUPPORTED; do
    got="${!name:-}"
    [[ -z "${got}" ]] && continue
    case "${name}" in
      FOUNDATIONS_TOPOLOGY_SUPPORT_LEVEL)          want="${CONTRACT_TOPOLOGY_LEVEL}" ;;
      FOUNDATIONS_SUPPORTED_NODE_MIN)              want="${CONTRACT_NODE_MIN}" ;;
      FOUNDATIONS_SUPPORTED_NODE_MAX)              want="${CONTRACT_NODE_MAX}" ;;
      FOUNDATIONS_MULTI_NODE_FOUNDATIONS_SUPPORTED) want="${multi_node}" ;;
    esac
    if [[ "${got}" != "${want}" ]]; then
      echo "${name}=${got} does not match topology ${CONTRACT_TOPOLOGY_MODE} (expects ${want})" >&2
      return 1
    fi
  done
}

# Print the flux-system/rathsted-foundations-contract ConfigMap.
# $1: install mode (managed | self-hosted)
render_foundations_contract_marker() {
  local install_mode="$1"
  local foundations_version contract_version
  resolve_contract_topology "${install_mode}" || return 1
  foundations_version="$(git -C "${ROOT_DIR}" describe --tags --always 2>/dev/null || echo "untagged")"
  contract_version="v1"
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rathsted-foundations-contract
  namespace: flux-system
data:
  contract_version: "${contract_version}"
  foundations_version: "${foundations_version}"
  foundations_series: "2.x"
  install_mode: "${install_mode}"
  decks_v0_supported: "true"
  policy_exception_support: "true"
  topology_mode: "${CONTRACT_TOPOLOGY_MODE}"
  topology_support_level: "${CONTRACT_TOPOLOGY_LEVEL}"
  supported_node_min: "${CONTRACT_NODE_MIN}"
  supported_node_max: "${CONTRACT_NODE_MAX}"
EOF
}

# $1: install mode (managed | self-hosted)
# A multi-node contract is only published on a cluster whose live node count
# is inside its supported range. The single-node default is not enforced here,
# so existing managed installs behave as before. Safe to call in preflight,
# before anything is installed.
check_contract_node_count() {
  local node_count
  resolve_contract_topology "$1" || return 1
  [[ "${CONTRACT_TOPOLOGY_MODE}" == "single-node" ]] && return 0
  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ ! "${node_count}" =~ ^[0-9]+$ ]] \
    || (( node_count < CONTRACT_NODE_MIN || node_count > CONTRACT_NODE_MAX )); then
    echo "topology ${CONTRACT_TOPOLOGY_MODE} supports ${CONTRACT_NODE_MIN}-${CONTRACT_NODE_MAX} nodes; cluster has ${node_count:-unknown}. Refusing to publish the contract." >&2
    return 1
  fi
}

# $1: install mode (managed | self-hosted)
# Client-side apply keeps data keys it never applied, such as r3_jurisdiction
# (patched in by bootstrap/lib/jurisdiction.sh); kubectl replace or a forced
# server-side apply of this manifest would drop it.
apply_foundations_contract_marker() {
  local manifest
  check_contract_node_count "$1" || return 1
  manifest="$(render_foundations_contract_marker "$1")" || return 1
  printf '%s\n' "${manifest}" | kubectl apply -f -
}
