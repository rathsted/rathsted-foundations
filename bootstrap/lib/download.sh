#!/usr/bin/env bash
# bootstrap/lib/download.sh — sourced by installer scripts; provides verified
# download helpers.  Compatible with bash 3.2+; set -euo pipefail safe.
#
# Functions exposed:
#   verify_sha256  FILE EXPECTED   — exits 0 iff EXPECTED is 64 hex chars and
#                                    matches FILE; non-zero with a clear stderr
#                                    message otherwise.
#   checksum_for   CHECKSUMS ASSET — print the hash for an EXACT asset name
#                                    (lines: "<hash>  <name>" or "<hash>  *<name>");
#                                    non-zero if the asset is absent.
#   download_https URL OUT         — fetch URL to OUT with safe curl flags.

verify_sha256() {
  local file="$1" expected="$2"
  # Reject empty or malformed hash (must be exactly 64 lowercase hex chars).
  if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'verify_sha256: expected hash is not 64 lowercase hex chars: "%s"\n' \
      "${expected:-<empty>}" >&2
    return 1
  fi
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'verify_sha256: checksum mismatch for %s\n  expected: %s\n  actual:   %s\n' \
      "$(basename "${file}")" "${expected}" "${actual}" >&2
    return 1
  fi
}

checksum_for() {
  local checksums_file="$1" asset="$2"
  local hash
  # Handle both "hash  name" and "hash  *name" (BSD-style) formats.
  hash="$(awk -v asset="${asset}" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == asset) { print $1; exit }
    }
  ' "${checksums_file}")"
  if [[ -z "${hash}" ]]; then
    printf 'checksum_for: asset "%s" not found in %s\n' "${asset}" "${checksums_file}" >&2
    return 1
  fi
  printf '%s\n' "${hash}"
}

download_https() {
  local url="$1" dest="$2"
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    -o "${dest}" "${url}"
}
