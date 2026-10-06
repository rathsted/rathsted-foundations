#!/usr/bin/env bash
set -euo pipefail

# Customer Instance Bootstrap
# Clones/updates the pinned Foundations version, runs its install, then applies customer workloads.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_env_file() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
allowed = set(sys.argv[2:])
key_re = re.compile(r"^[A-Z][A-Z0-9_]*$")
value_re = re.compile(r"^[A-Za-z0-9._:/@+\-]+$")

for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit(f"{path}:{lineno}: invalid line")
    key, value = line.split("=", 1)
    key = key.strip()
    value = value.strip()
    if key not in allowed:
        raise SystemExit(f"{path}:{lineno}: unexpected key {key}")
    if not key_re.match(key):
        raise SystemExit(f"{path}:{lineno}: invalid key format")
    if not value or not value_re.match(value):
        raise SystemExit(f"{path}:{lineno}: invalid value for {key}")
    print(f"{key}={value}")
PY
}

while IFS='=' read -r key value; do
  export "$key=$value"
done < <(
  load_env_file "${SCRIPT_DIR}/foundations-version.env" FOUNDATIONS_VERSION FOUNDATIONS_REPO
  load_env_file "${SCRIPT_DIR}/values.env" CUSTOMER_NAMESPACE CUSTOMER_REGISTRY CUSTOMER_GIT_URL CUSTOMER_JURISDICTION
)

case "${CUSTOMER_JURISDICTION:-}" in
  ca|us|fr) ;;
  *) echo "values.env: CUSTOMER_JURISDICTION must be ca, us or fr (got '${CUSTOMER_JURISDICTION:-}')" >&2; exit 1 ;;
esac

FOUNDATIONS_DIR="${SCRIPT_DIR}/.foundations"

echo "[customer] Foundations version: ${FOUNDATIONS_VERSION}"
echo "[customer] Foundations repo: ${FOUNDATIONS_REPO}"

# Clone or update Foundations at the pinned version
if [[ -d "${FOUNDATIONS_DIR}/.git" ]]; then
  echo "[customer] Updating Foundations checkout..."
  git -C "${FOUNDATIONS_DIR}" fetch origin
  git -C "${FOUNDATIONS_DIR}" checkout "${FOUNDATIONS_VERSION}"
else
  echo "[customer] Cloning Foundations at ${FOUNDATIONS_VERSION}..."
  git clone --branch "${FOUNDATIONS_VERSION}" "${FOUNDATIONS_REPO}" "${FOUNDATIONS_DIR}"
fi

# Run Foundations bootstrap
echo "[customer] Running Foundations install..."
sudo "${FOUNDATIONS_DIR}/bootstrap/install.sh"

# Create or update the customer namespace with the labels the
# require-namespace-labels policy checks at admission. They must be present
# on create: an unlabelled namespace is rejected before it can be labelled.
# rathsted.io/operator-control is stamped by the platform; don't set it.
echo "[customer] Ensuring customer namespace: ${CUSTOMER_NAMESPACE}"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CUSTOMER_NAMESPACE}
  labels:
    owner: customer
    environment: production
    rathsted.io/jurisdiction: ${CUSTOMER_JURISDICTION}
EOF

# Apply customer workloads
if [[ -f "${SCRIPT_DIR}/cluster/apps/kustomization.yaml" ]]; then
  echo "[customer] Applying customer workloads..."
  kubectl apply -k "${SCRIPT_DIR}/cluster/apps/"
else
  echo "[customer] No customer workloads found (cluster/apps/kustomization.yaml missing)"
fi

# Run verification
echo "[customer] Running Foundations verification..."
"${FOUNDATIONS_DIR}/bootstrap/verify.sh"

echo "[customer] Bootstrap complete"
