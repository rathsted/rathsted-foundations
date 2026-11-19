#!/usr/bin/env bash
set -euo pipefail

# Read-only audit of the namespace jurisdiction labels: every namespace in one
# convention.
# Lists each namespace with owner, environment, rathsted.io/jurisdiction and
# rathsted.io/operator-control. A namespace outside kube-system, kube-public
# and kube-node-lease conforms when all four are set, the jurisdiction is
# ca, us or fr, and operator-control equals the value the live
# require-namespace-labels policy stamps. When RATHSTED_JURISDICTION is set,
# or the install recorded one in flux-system/rathsted-foundations-contract,
# flux-system, kyverno and default must also declare that jurisdiction.
# Exits 0 when everything conforms, 1 when anything does not, 2 when the
# namespaces or the policy cannot be read. Changes nothing.
#
# Usage: ./bootstrap/jurisdiction-audit.sh   (or: make jurisdiction-audit)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
# shellcheck source=bootstrap/lib/jurisdiction.sh
source "${ROOT_DIR}/bootstrap/lib/jurisdiction.sh"
expect="${RATHSTED_JURISDICTION:-}"
if [[ -z "${expect}" ]]; then
  expect="$(recorded_jurisdiction)" || exit 2
fi
rc=0
jurisdiction_audit ${expect:+"$expect"} || rc=$?
exit "$rc"
