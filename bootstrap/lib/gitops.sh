#!/usr/bin/env bash
# Flux Kustomization readiness for bootstrap/verify.sh.
#
# Sourced, not executed. Uses only kubectl, sed, tr, sleep and bash builtins,
# so a test can exercise it against a fake kubectl.
#
# gitops_kustomization_verify_check <name> <release> <policies> <expected>
#   verify.sh's verdict on flux-system/<name>. Sets GITOPS_VERIFY_MSG.
#
# Found on v2.0.0 to v2.0.2: rathsted-sync stayed Ready=False (a denied demo
# Deployment blocked its batch), so Flux never applied the policies, and
# verify passed because it only listed the Kustomizations.

# RATHSTED_GITOPS_READY_ATTEMPTS: 1-120 reads (default 24).
# RATHSTED_GITOPS_READY_DELAY: 0-60 seconds between reads (default 5).
# Checked with regexes only: bash would evaluate any other value as an
# arithmetic expression.
_GITOPS_ATTEMPTS_RE='^([1-9]|[1-9][0-9]|1[01][0-9]|120)$'
_GITOPS_DELAY_RE='^([0-9]|[1-5][0-9]|60)$'

# $1: name. Prints the Kustomization's fields, '|'-separated:
#   suspend|generation|observedGeneration|Ready|lastApplied|lastAttempted|
#   sourceKind|sourceNamespace|sourceName|Ready message
# Returns 3 when it does not exist, 4 when Flux's CRD is absent, 2 on any
# other read error (the error on stderr).
_gitops_ks_read() {
  local out err errf rc=0
  errf="$(mktemp)" || return 2
  out="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io "$1" -n flux-system -o \
    jsonpath='{.spec.suspend}{"|"}{.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.lastAppliedRevision}{"|"}{.status.lastAttemptedRevision}{"|"}{.spec.sourceRef.kind}{"|"}{.spec.sourceRef.namespace}{"|"}{.spec.sourceRef.name}{"|"}{.status.conditions[?(@.type=="Ready")].message}' \
    2>"$errf")" || rc=$?
  err="$(cat "$errf")"
  rm -f "$errf"
  if [[ "$rc" -ne 0 ]]; then
    [[ "$err" == *"doesn't have a resource type"* ]] && return 4
    [[ "$err" == *NotFound* ]] && return 3
    echo "[rathsted] cannot read flux-system/$1: ${err}" >&2
    return 2
  fi
  printf '%s' "$out"
}

# $1 kind, $2 namespace, $3 name: sets _GITOPS_SRC_REV to the source's
# artifact revision. Returns 1 when the kind is not a Flux source this knows,
# 2 when the read fails (kubectl's error in _GITOPS_SRC_ERR). Called
# directly, not in $(...), so the caller sees both.
_GITOPS_SRC_REV=""
_GITOPS_SRC_ERR=""
_gitops_source_revision() {
  local res errf rc=0
  _GITOPS_SRC_REV=""
  _GITOPS_SRC_ERR=""
  case "$1" in
    GitRepository) res=gitrepositories.source.toolkit.fluxcd.io ;;
    OCIRepository) res=ocirepositories.source.toolkit.fluxcd.io ;;
    Bucket) res=buckets.source.toolkit.fluxcd.io ;;
    *) return 1 ;;
  esac
  errf="$(mktemp)" || { _GITOPS_SRC_ERR="mktemp failed"; return 2; }
  _GITOPS_SRC_REV="$(kubectl get "$res" "$3" -n "${2:-flux-system}" -o jsonpath='{.status.artifact.revision}' 2>"$errf")" || rc=$?
  _GITOPS_SRC_ERR="$(tr '\n' ' ' < "$errf")"
  rm -f "$errf"
  [[ "$rc" -eq 0 ]] || return 2
}

# $1: name (rathsted-sync or rathsted-apps). $2: release mode (true|false).
# $3: policies (true for rathsted-sync: not Ready fails in every mode, since
#     the policies' self-heal depends on it; false: not Ready warns, fails
#     under --release). $4: expected (true when GitOps must be configured,
#     i.e. self-hosted: a missing Kustomization warns, fails under --release).
# Re-reads until Ready with a lastAppliedRevision equal to the source's
# artifact revision at the current generation, up to
# RATHSTED_GITOPS_READY_ATTEMPTS times, RATHSTED_GITOPS_READY_DELAY seconds
# apart, so a just-installed cluster has time to reconcile. A suspended
# Kustomization is judged at once: it does not change by itself, and its
# Ready status may predate the suspension.
# Returns 0 (ok), 1 (warn), 2 (fail) or 3 (not checked: no Flux CRD, or not
# found where GitOps is not expected; behaviour as before this check).
# shellcheck disable=SC2034  # GITOPS_VERIFY_MSG is read by the caller (verify.sh)
gitops_kustomization_verify_check() {
  local name="$1" release="${2:-false}" policies="${3:-false}" expected="${4:-false}"
  local max="${RATHSTED_GITOPS_READY_ATTEMPTS:-24}" delay="${RATHSTED_GITOPS_READY_DELAY:-5}"
  local ks="flux-system/${name}" n=1 rc line susp gen obs ready applied attempted skind sns sname msg srev="" src_rc strict=2
  local what="Flux does not apply or self-heal the policies"
  [[ "$policies" == "true" ]] || what="Flux does not apply the workloads"
  if ! [[ "$max" =~ $_GITOPS_ATTEMPTS_RE ]]; then
    GITOPS_VERIFY_MSG="RATHSTED_GITOPS_READY_ATTEMPTS must be a whole number from 1 to 120"
    return 2
  fi
  if ! [[ "$delay" =~ $_GITOPS_DELAY_RE ]]; then
    GITOPS_VERIFY_MSG="RATHSTED_GITOPS_READY_DELAY must be a whole number of seconds from 0 to 60"
    return 2
  fi
  # Not Ready or suspended: policies always fail; workloads warn, fail under --release.
  [[ "$policies" == "true" || "$release" == "true" ]] || strict=1
  while true; do
    rc=0
    line="$(_gitops_ks_read "$name")" || rc=$?
    case "$rc" in
      0) ;;
      4)
        GITOPS_VERIFY_MSG="Flux Kustomization CRD not installed; ${ks} readiness not checked"
        return 3 ;;
      3)
        if [[ "$expected" != "true" ]]; then
          GITOPS_VERIFY_MSG="${ks} not found (GitOps not configured); readiness not checked"
          return 3
        fi
        GITOPS_VERIFY_MSG="${ks} not found, but this install configures GitOps: ${what}. Re-apply cluster/gitops/sync/kustomization.yaml"
        [[ "$release" == "true" ]] && return 2
        return 1 ;;
      *)
        GITOPS_VERIFY_MSG="Cannot read ${ks}, so cannot tell whether Flux applied it"
        return 2 ;;
    esac
    IFS='|' read -r susp gen obs ready applied attempted skind sns sname msg <<<"$(printf '%s' "$line" | tr '\n' ' ')"
    if [[ "$susp" == "true" ]]; then
      GITOPS_VERIFY_MSG="${ks} is suspended: ${what} until 'flux resume kustomization ${name}' (last applied ${applied:-nothing})"
      return "$strict"
    fi
    if [[ "$ready" == "True" && -n "$applied" ]]; then
      src_rc=0
      _gitops_source_revision "$skind" "$sns" "$sname" || src_rc=$?
      srev="${_GITOPS_SRC_REV}"
      if [[ "$src_rc" -eq 1 ]]; then
        GITOPS_VERIFY_MSG="${ks} Ready, applied ${applied} (source kind ${skind:-?} not known to this check, so ${sname:-?} revision not compared)"
        return 0
      fi
      # A known source whose revision is unknown: warn, fail under --release.
      if [[ "$src_rc" -ne 0 || -z "$srev" ]]; then
        if [[ "$src_rc" -ne 0 ]]; then
          GITOPS_VERIFY_MSG="${ks} Ready, applied ${applied}, but ${skind}/${sname} revision cannot be read, so it is not known to be current: ${_GITOPS_SRC_ERR:-no error text}"
        else
          GITOPS_VERIFY_MSG="${ks} Ready, applied ${applied}, but ${skind}/${sname} has no artifact revision, so it is not known to be current"
        fi
        [[ "$release" == "true" ]] && return 2
        return 1
      fi
      if [[ "$applied" == "$srev" && ( -z "$obs" || "$obs" == "$gen" ) ]]; then
        GITOPS_VERIFY_MSG="${ks} Ready, applied ${applied} (the current ${skind}/${sname} revision)"
        return 0
      fi
    fi
    (( n >= max )) && break
    [[ "$n" -eq 1 ]] && echo "[rathsted] waiting for ${ks} to be Ready (up to ${max} checks, ${delay}s apart)" >&2
    sleep "$delay"
    n=$((n + 1))
  done
  if [[ "$ready" == "True" && -n "$applied" ]]; then
    if [[ "$applied" != "$srev" ]]; then
      GITOPS_VERIFY_MSG="${ks} Ready, but applied ${applied} while ${skind}/${sname} is at ${srev}; Flux has not applied the current revision yet"
    else
      GITOPS_VERIFY_MSG="${ks} Ready at ${applied}, but not yet reconciled at generation ${gen} (observed ${obs})"
    fi
    [[ "$release" == "true" ]] && return 2
    return 1
  fi
  GITOPS_VERIFY_MSG="${ks} not Ready after ${max} checks (Ready=${ready:-none}, last applied ${applied:-nothing}, last attempted ${attempted:-nothing}): ${msg:-no message}. ${what}. Raise RATHSTED_GITOPS_READY_ATTEMPTS if it is still reconciling"
  return "$strict"
}
