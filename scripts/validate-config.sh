#!/usr/bin/env bash
# validate-config.sh — confirm rendered config/rendered/ is consistent with
# config/customer.env and that the rendered state is complete.
#
# Checks:
#   1. customer.env parses cleanly (safe loader)
#   2. RATHSTED_IMAGE is under RATHSTED_REGISTRY
#   3. rendered YAML is structurally valid (parser-based, via validate-rendered.py):
#      - restrict-registries.yaml is a ClusterPolicy with correct anyPattern
#      - require-signed-images.yaml is a ClusterPolicy with correct imageReferences
#      - demo-overlay/kustomization.yaml has correct newName + newTag/digest
#   4. rendered require-signed-images.yaml has no REPLACE_WITH_COSIGN_PUBLIC_KEY
#      placeholder (only enforced when --release flag is passed)
#   5. rendered files are not stale relative to customer.env
#
# Usage:
#   ./scripts/validate-config.sh
#   ./scripts/validate-config.sh --release   # also require cosign key to be applied
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not found in PATH" >&2
  echo "  Install it, or run: make doctor" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER="${ROOT_DIR}/scripts/lib/load-config.py"
VALIDATOR="${ROOT_DIR}/scripts/lib/validate-rendered.py"
CUSTOMER_ENV="${ROOT_DIR}/config/customer.env"
RENDERED_DIR="${ROOT_DIR}/config/rendered"

RELEASE_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--release" ]] && RELEASE_MODE=true
done

PASS=0
FAIL=0
GREEN='\033[32m' RED='\033[31m' BOLD='\033[1m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN='' RED='' BOLD='' RESET=''; }

ok()   { printf "${GREEN}✓${RESET} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}✗${RESET} %s\n" "$1" >&2; FAIL=$((FAIL + 1)); }

# ─── 1. customer.env must exist and parse cleanly ───
if [[ ! -f "$CUSTOMER_ENV" ]]; then
  fail "config/customer.env not found — run 'make configure' first"
  exit 1
fi

REGISTRY=""
IMAGE=""
while IFS='=' read -r k v; do
  [[ -z "$k" ]] && continue
  v="${v#\'}" v="${v%\'}"
  case "$k" in
    RATHSTED_REGISTRY) REGISTRY="$v" ;;
    RATHSTED_IMAGE)    IMAGE="$v" ;;
  esac
done < <(python3 "$LOADER" "$CUSTOMER_ENV")

if [[ -z "$REGISTRY" || -z "$IMAGE" ]]; then
  fail "customer.env is missing RATHSTED_REGISTRY or RATHSTED_IMAGE"
  exit 1
fi
ok "customer.env parsed (registry=${REGISTRY}, image=${IMAGE})"

# ─── 2. image is under registry ───
if [[ "$IMAGE" == "$REGISTRY"/* || "$IMAGE" == localhost/* ]]; then
  ok "RATHSTED_IMAGE (${IMAGE}) is under RATHSTED_REGISTRY (${REGISTRY})"
else
  fail "RATHSTED_IMAGE (${IMAGE}) is not under RATHSTED_REGISTRY (${REGISTRY}) — re-run make configure"
fi

# ─── 3. structural YAML validation ───
_validator_out="$(python3 "$VALIDATOR" "$RENDERED_DIR" "$REGISTRY" "$IMAGE" 2>&1)" && _validator_rc=0 || _validator_rc=$?
if [[ $_validator_rc -eq 0 ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ok "${line#ok  }"
  done <<< "$_validator_out"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    fail "${line#ERROR: }"
  done <<< "$_validator_out"
fi

# ─── 4. cosign key placeholder check (release mode only) ───
RENDERED_SIGNING="${RENDERED_DIR}/require-signed-images.yaml"
if $RELEASE_MODE; then
  if [[ ! -f "$RENDERED_SIGNING" ]]; then
    fail "config/rendered/require-signed-images.yaml not found — run 'make configure'"
  elif grep -q "REPLACE_WITH_COSIGN_PUBLIC_KEY" "$RENDERED_SIGNING" 2>/dev/null; then
    fail "require-signed-images.yaml still has cosign key placeholder — run supply-chain/cosign/update-policy.sh"
  else
    ok "cosign public key applied to require-signed-images.yaml"
  fi
fi

# ─── 5. staleness check — rendered files must be newer than customer.env ───
RENDERED_RESTRICT="${RENDERED_DIR}/restrict-registries.yaml"
if [[ -f "$RENDERED_RESTRICT" && -f "$RENDERED_SIGNING" ]]; then
  if [[ "$RENDERED_RESTRICT" -ot "$CUSTOMER_ENV" ]] || \
     [[ "$RENDERED_SIGNING"  -ot "$CUSTOMER_ENV" ]]; then
    fail "config/rendered/ files are older than customer.env — re-run make configure"
  else
    ok "Rendered files are up to date with customer.env"
  fi
fi

# ─── Summary ───
printf "\n${BOLD}validate-config: ${GREEN}${PASS} passed${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
  printf "${BOLD}, ${RED}${FAIL} failed${RESET}\n\n"
  exit 1
else
  printf "${BOLD}, 0 failed${RESET}\n\n"
fi
