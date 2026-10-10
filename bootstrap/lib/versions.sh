#!/usr/bin/env bash
# bootstrap/lib/versions.sh — installed-vs-pinned version check for k3s and Kyverno.
#
# Sourced, not executed.  set -euo pipefail safe, bash 3.2 compatible.
# No caller-defined functions are required.
#
# Callers must export (or have in their environment):
#   KYVERNO_VERSION  — the pinned Kyverno release tag (e.g. v1.19.1)
#   K3S_VERSION      — the pinned k3s release tag (e.g. v1.35.9+k3s1)
# Either may be unset or empty; that component's check is then skipped.
#
# check_installed_versions:
#   Queries kubectl for the running Kyverno image tag and the k3s kubelet version.
#   Returns 0 when every installed component matches its pin, or when nothing
#   is installed (kubectl unreachable, fresh host).
#   Returns 1 and prints diagnostics to stderr when any installed version
#   differs from its pin.  Never aborts under set -e when kubectl is unavailable.
#
# Flux is out of scope for this check — there is no single reliable version
# source that works across self-hosted and managed clusters.

check_installed_versions() {
  local mismatch=0

  # Short-circuit when kubectl is not on PATH — nothing to check.
  command -v kubectl >/dev/null 2>&1 || return 0

  # ── Kyverno ──────────────────────────────────────────────────────────────
  # kubectl exits non-zero (NotFound) when Kyverno is not installed.
  # Using 'if var="$(cmd)"; then' exempts the assignment from set -e so that
  # a NotFound error does not abort the caller's script.
  local kyverno_image kyverno_installed
  if kyverno_image="$(kubectl get deploy kyverno-admission-controller \
      -n kyverno \
      -o jsonpath='{.spec.template.spec.containers[0].image}' \
      2>/dev/null)"; then
    # Strip @digest if present ("repo:tag@sha256:..." → "repo:tag"), then extract tag.
    kyverno_image="${kyverno_image%%@*}"
    kyverno_installed="${kyverno_image##*:}"
    if [[ -n "${KYVERNO_VERSION:-}" && "${kyverno_installed}" != "${KYVERNO_VERSION:-}" ]]; then
      mismatch=1
      printf '  Kyverno: installed=%s  pinned=%s\n' \
        "${kyverno_installed}" "${KYVERNO_VERSION:-}" >&2
    fi
  fi
  # else: NotFound or kubectl unreachable — Kyverno not installed, nothing to compare

  # ── k3s ──────────────────────────────────────────────────────────────────
  # kubectl exits 0 with empty stdout when no nodes exist.
  # '|| k3s_installed=""' handles connection failure without aborting under set -e.
  local k3s_installed
  k3s_installed="$(kubectl get nodes \
    -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' \
    2>/dev/null)" || k3s_installed=""
  if [[ -n "${k3s_installed}" ]]; then
    # Compare only when the kubeletVersion looks like a k3s release (contains '+k3s').
    # Managed-cluster kubelets (EKS, GKE, AKS, etc.) use other version strings
    # and are intentionally excluded from this check.
    if [[ "${k3s_installed}" == *"+k3s"* && -n "${K3S_VERSION:-}" ]]; then
      if [[ "${k3s_installed}" != "${K3S_VERSION:-}" ]]; then
        mismatch=1
        printf '  k3s: installed=%s  pinned=%s\n' \
          "${k3s_installed}" "${K3S_VERSION:-}" >&2
      fi
    fi
  fi
  # else: empty → cluster unreachable or no nodes yet — not installed

  if [[ "${mismatch}" -ne 0 ]]; then
    printf 'Version mismatch detected (see above).\n' >&2
    printf 'In-place upgrades are not supported in 2.0.x; reinstall on a clean host (see docs/upgrade-guide.md)\n' >&2
    return 1
  fi
  return 0
}
