#!/usr/bin/env bash
set -euo pipefail

# Preflight check: verify required tools, files, and runtime for Rathsted Foundations.
# Run via: make doctor

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
WARN=0
PASS=0

ok()   { echo "[ok]   $*"; PASS=$((PASS + 1)); }
warn() { echo "[warn] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
section() { echo ""; echo "== $* =="; }

check_cmd() {
  local cmd="$1"
  local note="${2:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd found ($(command -v "$cmd"))"
  else
    if [[ -n "$note" ]]; then
      fail "$cmd not found — $note"
    else
      fail "$cmd not found"
    fi
  fi
}

check_cmd_optional() {
  local cmd="$1"
  local note="${2:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd found ($(command -v "$cmd"))"
  else
    if [[ -n "$note" ]]; then
      warn "$cmd not found — $note"
    else
      warn "$cmd not found (optional)"
    fi
  fi
}

# --- Required tools ---
section "Required Tools"
check_cmd bash
check_cmd curl
check_cmd git
check_cmd make
check_cmd python3 "needed for GitOps template rendering"

# PyYAML is used by scripts/lib/validate-rendered.py (structural YAML validation)
if python3 -c "import yaml" 2>/dev/null; then
  ok "python3 pyyaml module available"
else
  fail "python3 pyyaml module not found — install with: pip install pyyaml"
fi

# --- Bootstrap tools (installed by install.sh, but useful to check) ---
section "Bootstrap Tools (installed by install.sh)"
check_cmd_optional kubectl "installed with k3s"
check_cmd_optional flux "installed by install.sh"
check_cmd_optional cosign "installed by install.sh"
check_cmd_optional syft "installed by install.sh"
check_cmd_optional grype "installed by install.sh"
check_cmd_optional kyverno "needed for make policy-test"

# --- Development tools (macOS host) ---
section "Development Tools (macOS host)"
check_cmd_optional orb "needed for make orbstack-e2e and make compat-test"
check_cmd_optional docker "needed for local registry workflows (make sign, make sbom)"
check_cmd_optional shellcheck "shell script linting"

# --- Key files ---
section "Key Files"

check_file() {
  local path="$1"
  local label="${2:-$1}"
  if [[ -e "$ROOT_DIR/$path" ]]; then
    ok "$label"
  else
    fail "$label missing ($path)"
  fi
}

check_file "bootstrap/install.sh" "install.sh"
check_file "bootstrap/verify.sh" "verify.sh"
check_file "bootstrap/uninstall.sh" "uninstall.sh"
check_file "cluster/k3s/config.yaml" "k3s config"
check_file "cluster/gitops/sync/gitrepository.yaml.tmpl" "GitOps template"
check_file "cluster/gitops/sync/kustomization.yaml" "GitOps kustomization"
check_file "policies/kustomization.yaml" "Policy kustomization"
check_file "Makefile" "Makefile"

# --- Git state ---
section "Git"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ok "inside git repo"
  BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
  ok "branch: $BRANCH"
  if git -C "$ROOT_DIR" diff --quiet 2>/dev/null; then
    ok "working tree clean"
  else
    warn "uncommitted changes in working tree"
  fi
else
  fail "not a git repository"
fi

# --- Environment ---
section "Environment"
if [[ -f "$ROOT_DIR/.env" ]]; then
  ok ".env file present"
else
  warn ".env file not found (optional — needed for SSH/token auth)"
fi

if [[ -n "${RATHSTED_GIT_URL:-}" ]]; then
  ok "RATHSTED_GIT_URL set"
else
  warn "RATHSTED_GIT_URL not set (will use git remote origin)"
fi

# --- OS detection (if running on Linux) ---
if [[ -f /etc/os-release ]]; then
  section "Host OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}" in
    ubuntu|debian|rocky|almalinux|rhel|centos)
      ok "Supported OS: ${ID} ${VERSION_ID}"
      ;;
    *)
      warn "Unsupported host OS: ${ID} ${VERSION_ID} (supported: Ubuntu 22.04/24.04, Debian 12, Rocky/Alma/RHEL 9)"
      ;;
  esac
fi

# --- Summary ---
section "Summary"
echo "  Passed:   ${PASS}"
echo "  Warnings: ${WARN}"
echo "  Failed:   ${FAIL}"
echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "[FAIL] ${FAIL} issue(s) found — fix before proceeding"
  exit 1
else
  echo "[ok] Environment ready"
fi
