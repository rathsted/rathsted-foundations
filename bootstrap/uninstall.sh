#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  else
    echo "sudo is required to uninstall." >&2
    exit 1
  fi
fi

if systemctl is-active --quiet k3s; then
  /usr/local/bin/k3s-uninstall.sh
fi

rm -rf /etc/rancher/k3s
