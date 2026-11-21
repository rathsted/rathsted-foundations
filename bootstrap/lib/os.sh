#!/usr/bin/env bash
# bootstrap/lib/os.sh: sourced by install.sh and scripts/doctor.sh; the
# supported host OS list and the per-release host preparation k3s needs.
# Compatible with bash 3.2+; set -euo pipefail safe.
#
# Functions exposed:
#   detect_supported_os [FILE]  : read FILE (default /etc/os-release) and set
#                                 OS_ID, OS_VERSION_ID and OS_FAMILY
#                                 (debian | rhel). Returns non-zero with an
#                                 "Unsupported OS" message on stderr for any
#                                 release outside SUPPORTED_OS_TEXT.
#   ensure_k3s_kernel_modules   : on an EL10 host whose running kernel cannot
#                                 resolve nft_compat and xt_conntrack, install
#                                 the modules-extra build of that kernel's own
#                                 package (kernel, kernel-64k, kernel-debug,
#                                 ...). RHEL 10 moved those modules out of
#                                 kernel-modules-core. No-op elsewhere.

SUPPORTED_OS_TEXT="Ubuntu 22.04/24.04/26.04, Debian 12/13, Rocky/Alma/RHEL 9/10"

detect_supported_os() {
  local file="${1:-/etc/os-release}" major
  OS_ID="" OS_VERSION_ID="" OS_FAMILY=""
  if [[ ! -r "${file}" ]]; then
    echo "Unsupported OS: ${file} not found. Supported: ${SUPPORTED_OS_TEXT}." >&2
    return 1
  fi
  # Read in a subshell so the file's other variables stay out of the caller.
  # shellcheck disable=SC1090
  OS_ID="$(ID=""; . "${file}" >/dev/null 2>&1; echo "${ID:-}")"
  # shellcheck disable=SC1090
  OS_VERSION_ID="$(VERSION_ID=""; . "${file}" >/dev/null 2>&1; echo "${VERSION_ID:-}")"
  major="${OS_VERSION_ID%%.*}"
  case "${OS_ID}:${OS_VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) OS_FAMILY="debian" ;;
    debian:12|debian:13) OS_FAMILY="debian" ;;
    rocky:*|almalinux:*|rhel:*)
      case "${major}" in
        9|10) OS_FAMILY="rhel" ;;
      esac
      ;;
  esac
  if [[ -z "${OS_FAMILY}" ]]; then
    echo "Unsupported OS: ${OS_ID:-unknown} ${OS_VERSION_ID:-(no VERSION_ID)}. Supported: ${SUPPORTED_OS_TEXT}. Not supported: CentOS Stream, Fedora, and releases older than Ubuntu 22.04, Debian 12 or EL9." >&2
    return 1
  fi
}

ensure_k3s_kernel_modules() {
  local kver owner name vra pkg
  [[ "${OS_FAMILY:-}" == "rhel" && "${OS_VERSION_ID%%.*}" == "10" ]] || return 0
  # Nothing to do when the running kernel already resolves the modules.
  if modprobe -n -q nft_compat >/dev/null 2>&1 && modprobe -n -q xt_conntrack >/dev/null 2>&1; then
    return 0
  fi
  # The running kernel's build, not the newest: modules for a kernel that has
  # not booted yet cannot be loaded until a reboot.
  kver="$(uname -r)"
  # Only a distribution kernel has a matching package; a VM platform's own
  # kernel (OrbStack, WSL2) or a custom build has none, so leave it alone.
  if ! owner="$(rpm -qf --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' "/usr/lib/modules/${kver}/vmlinuz" 2>/dev/null)"; then
    echo "[rathsted] Kernel ${kver} is not a distribution package; skipping kernel-modules-extra"
    return 0
  fi
  # kernel-core -> kernel-modules-extra, kernel-64k-core ->
  # kernel-64k-modules-extra, and so on. VERSION-RELEASE.ARCH drops the
  # +64k/+debug suffix that uname -r carries.
  owner="${owner%%$'\n'*}"
  name="${owner%% *}" vra="${owner#* }"
  if [[ "${name}" != *-core || -z "${vra}" || "${vra}" == "${owner}" ]]; then
    echo "Kernel ${kver} is owned by '${owner}', not a *-core package; install its modules-extra package (k3s needs nft_compat and the xt_ matches) and rerun." >&2
    return 1
  fi
  pkg="${name%-core}-modules-extra-${vra}"
  if rpm -q "${pkg}" >/dev/null 2>&1; then
    return 0
  fi
  echo "[rathsted] Installing ${pkg} (RHEL 10 keeps nft_compat and the xt_ matches k3s needs there)"
  if ! dnf install -y "${pkg}"; then
    echo "Could not install ${pkg}. k3s needs it on RHEL 10; install it for the running kernel, or update the kernel and reboot, then rerun." >&2
    return 1
  fi
}

# host_selinux_mode: getenforce's answer (Enforcing, Permissive, Disabled),
# or "not present" on a host without SELinux userspace.
host_selinux_mode() {
  if command -v getenforce >/dev/null 2>&1; then
    getenforce 2>/dev/null || echo "unknown"
  else
    echo "not present"
  fi
}

# host_secure_boot [FIRMWARE_DIR]: "enabled" or "disabled" from mokutil, else
# from the SecureBoot EFI variable (its fifth byte), "not EFI" on BIOS boot,
# or "unknown". FIRMWARE_DIR defaults to /sys/firmware.
host_secure_boot() {
  local fw="${1:-/sys/firmware}" out var byte
  if command -v mokutil >/dev/null 2>&1 && out="$(mokutil --sb-state 2>/dev/null)"; then
    case "${out}" in
      *"SecureBoot enabled"*) echo "enabled"; return 0 ;;
      *"SecureBoot disabled"*) echo "disabled"; return 0 ;;
    esac
  fi
  [[ -d "${fw}/efi" ]] || { echo "not EFI"; return 0; }
  var="${fw}/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  byte="$(od -An -t u1 -j 4 -N 1 "${var}" 2>/dev/null | tr -d ' ' || true)"
  case "${byte}" in
    1) echo "enabled" ;;
    0) echo "disabled" ;;
    *) echo "unknown" ;;
  esac
}
