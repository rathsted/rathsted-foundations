#!/usr/bin/env bash
# update-policy.sh — inject cosign public key into the rendered signing policy.
#
# Run this after generating or rotating your cosign keypair:
#   cosign generate-key-pair
#   mv cosign.pub supply-chain/cosign/cosign.pub
#   ./supply-chain/cosign/update-policy.sh
#
# The rendered policy lives at config/rendered/require-signed-images.yaml.
# If it does not exist yet, run make configure first.
# Tracked policy source files (policies/templates/*) are never modified.
#
# NOTE: the policy actually APPLIED by `policies/kustomization.yaml` is the
# committed `policies/require-signed-images.yaml`, NOT config/rendered/. After
# rotating the keypair, sync the applied policy and commit it:
#   scripts/check-signing-key.py --sync
# CI (`make verify-signing-key`, ci.yml) fails if the applied policy key ever
# drifts from supply-chain/cosign/cosign.pub.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUB="${ROOT_DIR}/supply-chain/cosign/cosign.pub"
RENDERED="${ROOT_DIR}/config/rendered/require-signed-images.yaml"
TMPL="${ROOT_DIR}/policies/templates/require-signed-images.yaml.tmpl"
LOADER="${ROOT_DIR}/scripts/lib/load-config.py"
CUSTOMER_ENV="${ROOT_DIR}/config/customer.env"

if [[ ! -f "$PUB" ]]; then
  echo "cosign.pub not found at $PUB" >&2
  exit 1
fi

# Ensure config/rendered/ exists and the policy has been rendered
if [[ ! -f "$RENDERED" ]]; then
  echo "Rendered policy not found: ${RENDERED}" >&2
  echo "Run 'make configure' first to render policies from templates." >&2
  exit 1
fi

# If customer.env exists, re-render from template first to keep imageReferences
# in sync. Uses the safe loader — never sources the file.
if [[ -f "$CUSTOMER_ENV" ]] && [[ -f "$LOADER" ]]; then
  REGISTRY=""
  while IFS='=' read -r _k _v; do
    [[ -z "$_k" ]] && continue
    _v="${_v#\'}" _v="${_v%\'}"
    [[ "$_k" == "RATHSTED_REGISTRY" ]] && REGISTRY="$_v"
  done < <(python3 "$LOADER" "$CUSTOMER_ENV")

  if [[ -n "$REGISTRY" ]]; then
    python3 - "$TMPL" "$RENDERED" "$REGISTRY" <<'PY'
import sys
from pathlib import Path
tmpl_path, out_path, registry = sys.argv[1], sys.argv[2], sys.argv[3]
Path(out_path).write_text(Path(tmpl_path).read_text().replace("{{RATHSTED_REGISTRY}}", registry))
PY
    echo "Re-rendered config/rendered/require-signed-images.yaml for registry: ${REGISTRY}/*"
  fi
fi

# Inject the public key into the rendered policy
PUB_FILE="$PUB" POLICY_FILE="$RENDERED" python3 - <<'PY'
import os, re
from pathlib import Path

pub   = Path(os.environ["PUB_FILE"])
policy = Path(os.environ["POLICY_FILE"])

text     = policy.read_text(encoding="utf-8")
pub_text = pub.read_text(encoding="utf-8").strip().splitlines()

start = "-----BEGIN PUBLIC KEY-----"
end   = "-----END PUBLIC KEY-----"

if pub_text[0].startswith(start) and pub_text[-1].endswith(end.split("-----")[1]):
    body = "\n".join(pub_text[1:-1]).strip()
else:
    body = "\n".join(pub_text).strip()

if "REPLACE_WITH_COSIGN_PUBLIC_KEY" not in text:
    raise SystemExit(
        "Placeholder not found in rendered policy — run 'make configure' to re-render."
    )

m = re.search(r'^( *)REPLACE_WITH_COSIGN_PUBLIC_KEY', text, re.MULTILINE)
indent = m.group(1) if m else "                      "
indented_body = ("\n" + indent).join(body.splitlines())

text = re.sub(
    r'( *)REPLACE_WITH_COSIGN_PUBLIC_KEY',
    lambda match: match.group(1) + indented_body,
    text,
    flags=re.MULTILINE,
)
policy.write_text(text, encoding="utf-8")
print("Updated config/rendered/require-signed-images.yaml with cosign public key")
PY
