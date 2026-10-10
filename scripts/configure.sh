#!/usr/bin/env bash
# configure.sh — set registry and image values, then render policies from templates.
#
# Usage:
#   ./scripts/configure.sh                         # interactive
#   ./scripts/configure.sh --registry ghcr.io/myorg --image ghcr.io/myorg/myapp:1.0.0
#   ./scripts/configure.sh --registry ghcr.io/myorg --image ghcr.io/myorg/myapp:1.0.0 --yes
#
# Rendered output goes to config/rendered/ (gitignored).
# Tracked source files (policies/*, examples/*) are never modified.
# This script is idempotent — re-running with new values re-renders output.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER="${ROOT_DIR}/scripts/lib/load-config.py"
FOUNDATIONS_ENV="${ROOT_DIR}/config/foundations.env"
CUSTOMER_ENV="${ROOT_DIR}/config/customer.env"
TMPL_DIR="${ROOT_DIR}/policies/templates"
RENDERED_DIR="${ROOT_DIR}/config/rendered"

if [[ -t 1 ]]; then
  B='\033[1m' G='\033[32m' Y='\033[33m' C='\033[36m' D='\033[2m' R='\033[31m' _0='\033[0m'
else
  B='' G='' Y='' C='' D='' R='' _0=''
fi

info() { printf "${D}[configure]${_0} %s\n" "$1"; }
ok()   { printf "${G}✓${_0} %s\n" "$1"; }
warn() { printf "${Y}⚠${_0} %s\n" "$1"; }
fail() { printf "${R}✗${_0} %s\n" "$1" >&2; exit 1; }

# ─── Parse flags ───
REGISTRY_ARG=""
IMAGE_ARG=""
YES=false
REGISTRY_SET=false
IMAGE_SET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY_ARG="$2"; REGISTRY_SET=true; shift 2 ;;
    --image)    IMAGE_ARG="$2";    IMAGE_SET=true;    shift 2 ;;
    --yes|-y)   YES=true;          shift   ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

# Explicit empty values are always an error — catch them early
$REGISTRY_SET && [[ -z "$REGISTRY_ARG" ]] && fail "--registry value must not be empty"
$IMAGE_SET    && [[ -z "$IMAGE_ARG"    ]] && fail "--image value must not be empty"

# ─── Load current values via safe parser ───
CURRENT_REGISTRY=""
CURRENT_IMAGE=""

_load_env() {
  local file="$1"
  local out
  out="$(python3 "$LOADER" "$file")" || exit 1
  # Safe eval: loader only emits KEY='single-quoted-value' lines for known keys
  local k v
  while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    v="${v#\'}" v="${v%\'}"     # strip surrounding single quotes
    case "$k" in
      RATHSTED_REGISTRY) CURRENT_REGISTRY="$v" ;;
      RATHSTED_IMAGE)    CURRENT_IMAGE="$v" ;;
    esac
  done <<< "$out"
}

if [[ -f "$CUSTOMER_ENV" ]]; then
  _load_env "$CUSTOMER_ENV"
fi
if [[ -z "$CURRENT_REGISTRY" || -z "$CURRENT_IMAGE" ]]; then
  _load_env "$FOUNDATIONS_ENV"
fi

# ─── Prompt for values if not supplied via flags ───
if [[ -n "$REGISTRY_ARG" ]]; then
  NEW_REGISTRY="$REGISTRY_ARG"
elif [[ "$YES" == "true" ]]; then
  [[ -z "$CURRENT_REGISTRY" ]] && fail "No registry configured. Re-run without --yes and provide a value."
  NEW_REGISTRY="$CURRENT_REGISTRY"
else
  printf "\n${B}Registry prefix${_0} (current: ${C}%s${_0})\n" "$CURRENT_REGISTRY"
  printf "  All workload images must come from this prefix.\n"
  printf "  Examples: ghcr.io/your-org  registry.example.com/team  localhost\n"
  printf "${B}Enter registry [%s]: ${_0}" "$CURRENT_REGISTRY"
  read -r NEW_REGISTRY </dev/tty
  NEW_REGISTRY="${NEW_REGISTRY:-$CURRENT_REGISTRY}"
fi

if [[ -n "$IMAGE_ARG" ]]; then
  NEW_IMAGE="$IMAGE_ARG"
elif [[ "$YES" == "true" ]]; then
  NEW_IMAGE="$CURRENT_IMAGE"
else
  DEFAULT_IMAGE="${NEW_REGISTRY}/nginx:1.29.7-alpine"
  if [[ "$CURRENT_IMAGE" != docker.io/library/* ]]; then
    DEFAULT_IMAGE="$CURRENT_IMAGE"
  fi
  printf "\n${B}Demo/verification image${_0} (current: ${C}%s${_0})\n" "$CURRENT_IMAGE"
  printf "  Used by: make sign, make sbom, make verify-release.\n"
  printf "  Must be under the registry prefix above.\n"
  printf "${B}Enter image [%s]: ${_0}" "$DEFAULT_IMAGE"
  read -r NEW_IMAGE </dev/tty
  NEW_IMAGE="${NEW_IMAGE:-$DEFAULT_IMAGE}"
fi

# ─── Validate via safe loader (strict char allowlist) ───
VALIDATED="$(python3 "$LOADER" /dev/stdin <<EOF
RATHSTED_REGISTRY=${NEW_REGISTRY}
RATHSTED_IMAGE=${NEW_IMAGE}
EOF
)" || fail "Validation failed — check registry and image values above."

# Re-read validated values (loader may have normalised them)
while IFS='=' read -r k v; do
  [[ -z "$k" ]] && continue
  v="${v#\'}" v="${v%\'}"
  case "$k" in
    RATHSTED_REGISTRY) NEW_REGISTRY="$v" ;;
    RATHSTED_IMAGE)    NEW_IMAGE="$v" ;;
  esac
done <<< "$VALIDATED"

# Confirm image is under registry
if [[ "$NEW_IMAGE" != "$NEW_REGISTRY"/* && "$NEW_IMAGE" != localhost/* ]]; then
  fail "Image '${NEW_IMAGE}' is not under registry '${NEW_REGISTRY}'. Use a matching image."
fi

# ─── Write customer.env (plain KEY=value, no shell syntax) ───
printf 'RATHSTED_REGISTRY=%s\nRATHSTED_IMAGE=%s\n' \
  "$NEW_REGISTRY" "$NEW_IMAGE" > "$CUSTOMER_ENV"
ok "Wrote ${CUSTOMER_ENV}"

# ─── Render to config/rendered/ (never touches tracked policy files) ───
mkdir -p "$RENDERED_DIR"

python3 - "$TMPL_DIR" "$RENDERED_DIR" "$NEW_REGISTRY" <<'PY'
import sys
from pathlib import Path

tmpl_dir, out_dir, registry = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
for tmpl in tmpl_dir.glob("*.yaml.tmpl"):
    out = out_dir / tmpl.name.removesuffix(".tmpl")
    out.write_text(tmpl.read_text().replace("{{RATHSTED_REGISTRY}}", registry))
PY

ok "Rendered policies to config/rendered/  (registry: ${NEW_REGISTRY}/*)"
info "Tracked policy templates in policies/templates/ are unchanged."

# ─── Write kustomize overlay for the demo workload ───
# Use Python to split the OCI reference correctly so host:port/path:tag
# is handled without ambiguity (cut -d: breaks on port numbers).
OVERLAY_DIR="${RENDERED_DIR}/demo-overlay"
mkdir -p "$OVERLAY_DIR"
python3 - "$NEW_IMAGE" "$OVERLAY_DIR/kustomization.yaml" <<'PY'
import sys, re
from pathlib import Path

image, out_path = sys.argv[1], sys.argv[2]

# Split an OCI image reference into (name, tag, digest) components.
# Rules:
#   digest  — @sha256:<64 hex chars> at the end; name is everything before @
#   tag     — last colon that appears after the final slash (so port colons are ignored)
#   neither — reject; a mutable image reference is not allowed

digest_match = re.search(r'@(sha256:[a-f0-9]{64})$', image)
if digest_match:
    name_part   = image[:digest_match.start()]
    digest_part = digest_match.group(1)   # sha256:abc... (no leading @)
    tag_part    = None
else:
    digest_part = None
    tag_match = re.search(r':([a-zA-Z0-9._\-]+)$', image)
    if tag_match and tag_match.start() > image.rfind('/'):
        name_part = image[:tag_match.start()]
        tag_part  = tag_match.group(1)
    else:
        raise SystemExit(
            "Image must include an explicit tag or digest; refusing mutable latest/default references."
        )

# Build the images entry.  Kustomize digest pinning uses `digest:` not `newTag: @sha256:...`
if digest_part:
    image_entry = (
        f"  - name: nginx\n"
        f"    newName: {name_part}\n"
        f"    digest: {digest_part}"
    )
else:
    image_entry = (
        f"  - name: nginx\n"
        f"    newName: {name_part}\n"
        f'    newTag: "{tag_part}"'
    )

kustomization = f"""apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../examples/hello-gitops-app
images:
{image_entry}
"""
Path(out_path).write_text(kustomization)
PY
ok "Wrote config/rendered/demo-overlay/kustomization.yaml  (image: ${NEW_IMAGE})"
info "examples/hello-gitops-app/deployment.yaml is unchanged."

# ─── Remind about cosign key ───
PUBKEY="${ROOT_DIR}/supply-chain/cosign/cosign.pub"
if [[ ! -f "$PUBKEY" ]] || grep -q "REPLACE_WITH" "$PUBKEY" 2>/dev/null; then
  printf "\n${Y}Next:${_0} generate a cosign keypair and apply it to the signing policy:\n"
  printf "  cosign generate-key-pair\n"
  printf "  mv cosign.pub %s\n" "$PUBKEY"
  printf "  mv cosign.key %s/supply-chain/cosign/cosign.key\n" "$ROOT_DIR"
  printf "  %s/supply-chain/cosign/update-policy.sh\n\n" "$ROOT_DIR"
else
  printf "\n${G}cosign.pub already configured.${_0} Re-apply if you rotated the key:\n"
  printf "  %s/supply-chain/cosign/update-policy.sh\n\n" "$ROOT_DIR"
fi

printf "${G}━━━ Configuration complete ━━━${_0}\n"
printf "  Registry : ${C}%s${_0}\n" "$NEW_REGISTRY"
printf "  Image    : ${C}%s${_0}\n" "$NEW_IMAGE"
printf "  Rendered : ${C}%s${_0}\n\n" "$RENDERED_DIR"
printf "Run ${B}make install${_0} to apply to the cluster, or ${B}make verify${_0} if already installed.\n\n"
printf "${Y}Note:${_0} install.sh applies these rendered registry/signature policies during\n"
printf "bootstrap only. Flux then reconciles the default policies from git and may\n"
printf "restore the default ghcr.io/rathsted/* allowlist at its next reconcile. For\n"
printf "persistent custom registries, carry equivalent policy changes in your GitOps\n"
printf "source. A tracked-overlay workflow is planned.\n\n"
