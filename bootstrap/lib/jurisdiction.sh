#!/usr/bin/env bash
# R3 namespace label helpers for bootstrap/install.sh, bootstrap/install-managed.sh,
# bootstrap/verify.sh and bootstrap/jurisdiction-audit.sh.
#
# Sourced, not executed. Uses only kubectl, git, sed, awk, grep, tr, sleep, mktemp, cat, cp, mkdir,
# rm and bash builtins, so a test can exercise it against a fake kubectl.
#
# validate_rathsted_jurisdiction   : RATHSTED_JURISDICTION is unset or one of ca, us, fr,
#                                    and the retry knobs are valid
# validate_rathsted_operator_control : RATHSTED_OPERATOR_CONTROL is unset or one of
#                                    R3_OPERATOR_CONTROLS
# validate_rathsted_git_url [url]  : the GitOps URL embeds no credentials
# r3_gitops_url, r3_gitops_ref_spec : the GitOps URL and ref the installers use
# check_gitops_operator_control    : on a path that bootstraps GitOps, the declared
#                                    value equals the literal at the commit Git
#                                    will apply: the enabled operator-control
#                                    component, else the policy's (fails closed)
# gitops_operator_control_gate <euid> : install.sh's form, with the sudo marker
# render_operator_control_policies <dir> : kustomization over a copy of policies/
#                                    that stamps RATHSTED_OPERATOR_CONTROL
# stamped_operator_control         : the operator-control value the live policy stamps
# recorded_jurisdiction            : the jurisdiction the install recorded, if any
# recorded_operator_control        : the operator-control the install recorded, if any
# declare_operator_control         : record the declared operator-control, or warn when unset
# apply_platform_namespace_labels  : label the platform namespaces, or warn when unset
# jurisdiction_audit [expected]    : list every namespace's R3 labels; read-only
# jurisdiction_verify_check <release> : verify.sh's verdict on the audit
# operator_control_verify_check <release> : verify.sh's verdict on the stamped value
#
# The R3 convention (policies/require-namespace-labels.yaml): every namespace
# outside R3_SYSTEM_NAMESPACES has owner, environment, rathsted.io/jurisdiction
# in R3_JURISDICTIONS, and rathsted.io/operator-control equal to the value the
# live policy stamps (a cluster fact, so the enum alone is not enough).

R3_JURISDICTIONS=(ca us fr)
R3_OPERATOR_CONTROLS=(customer domestic-provider foreign-provider rathsted)
# Excluded by both require-namespace-labels rules; keep the two lists equal.
R3_SYSTEM_NAMESPACES=(kube-system kube-public kube-node-lease)
# Namespaces Foundations creates (flux-system, kyverno) or relies on and never
# removes (default). Workload namespaces carry their own labels in Git.
RATHSTED_PLATFORM_NAMESPACES=(flux-system kyverno default)
# Where the install records the declared jurisdiction (key r3_jurisdiction) and
# operator-control (key r3_operator_control).
R3_CONTRACT_NS=flux-system
R3_CONTRACT_NAME=rathsted-foundations-contract
# Removes a stale declaration. Legitimate only when the record no longer says
# who controls the operator (see docs/upgrade-guide.md); verify then warns
# that the stamp is undeclared instead of failing on the old value.
R3_REMOVE_OPCTL_CMD="kubectl patch configmap rathsted-foundations-contract -n flux-system --type json -p '[{\"op\":\"remove\",\"path\":\"/data/r3_operator_control\"}]'"

# $1: value, rest: allowed set. Exact match only.
_r3_in() {
  local v="$1" a
  shift
  for a in "$@"; do [[ "$v" == "$a" ]] && return 0; done
  return 1
}

# RATHSTED_LABEL_ATTEMPTS: 1-20 (default 3). RATHSTED_LABEL_DELAY: 0-300 seconds
# (default 5). Checked with regexes only: bash would evaluate any other value
# as an arithmetic expression, array subscripts and command substitution included.
_R3_ATTEMPTS_RE='^([1-9]|1[0-9]|20)$'
_R3_DELAY_RE='^([0-9]|[1-9][0-9]|[12][0-9][0-9]|300)$'
_r3_knobs_ok() {
  local a="${RATHSTED_LABEL_ATTEMPTS:-3}" d="${RATHSTED_LABEL_DELAY:-5}" ok=0
  if ! [[ "$a" =~ $_R3_ATTEMPTS_RE ]]; then
    echo "[rathsted] RATHSTED_LABEL_ATTEMPTS must be a whole number from 1 to 20" >&2
    ok=1
  fi
  if ! [[ "$d" =~ $_R3_DELAY_RE ]]; then
    echo "[rathsted] RATHSTED_LABEL_DELAY must be a whole number of seconds from 0 to 300" >&2
    ok=1
  fi
  return "$ok"
}

# Run "$@" up to RATHSTED_LABEL_ATTEMPTS times, RATHSTED_LABEL_DELAY seconds
# apart. Writes go through the Kyverno webhook, which can fail transiently
# ("failed calling webhook").
_r3_retry() {
  _r3_knobs_ok || return 1
  local max="${RATHSTED_LABEL_ATTEMPTS:-3}" delay="${RATHSTED_LABEL_DELAY:-5}" n=1
  while true; do
    "$@" && return 0
    (( n >= max )) && return 1
    sleep "$delay"
    n=$((n + 1))
  done
}

# Returns 0 when RATHSTED_JURISDICTION is unset or empty, or exactly one of
# R3_JURISDICTIONS, and the retry knobs are valid. Never calls kubectl:
# installers run it before anything else.
validate_rathsted_jurisdiction() {
  local v="${RATHSTED_JURISDICTION:-}"
  _r3_knobs_ok || return 1
  [[ -z "$v" ]] && return 0
  _r3_in "$v" "${R3_JURISDICTIONS[@]}" && return 0
  echo "[rathsted] RATHSTED_JURISDICTION='${v}' is not allowed; use one of: ca, us, fr (or leave it unset)" >&2
  return 1
}

# Returns 0 when RATHSTED_OPERATOR_CONTROL is unset or empty, or exactly one of
# R3_OPERATOR_CONTROLS. Never calls kubectl: installers run it before anything else.
validate_rathsted_operator_control() {
  local v="${RATHSTED_OPERATOR_CONTROL:-}"
  [[ -z "$v" ]] && return 0
  _r3_in "$v" "${R3_OPERATOR_CONTROLS[@]}" && return 0
  echo "[rathsted] RATHSTED_OPERATOR_CONTROL='${v}' is not allowed; use one of: customer, domestic-provider, foreign-provider, rathsted (or leave it unset)" >&2
  return 1
}

# The GitOps URL ($1, else RATHSTED_GIT_URL) must not carry credentials
# (https://user:token@host/...): the installers write it into the Flux
# GitRepository spec, which anyone who can read that object sees. A token goes
# in RATHSTED_GIT_TOKEN, which becomes a Secret. A bare user name is refused
# too: a token can sit in that position. SSH URLs carry a user, not a secret
# (git@host:path, ssh://git@host/path), but an ssh:// URL with a password
# before the @ is refused. The URL is not printed.
validate_rathsted_git_url() {
  local url="${1-${RATHSTED_GIT_URL:-}}"
  url="${url#"${url%%[![:space:]]*}"}"
  [[ -z "$url" ]] && return 0
  if [[ "$url" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/@]+@ ]]; then
    echo "[rathsted] the GitOps URL (RATHSTED_GIT_URL, else the origin remote) must not embed credentials; use RATHSTED_GIT_TOKEN. Anything before '@' counts, even a user name alone, since a token can sit there" >&2
    return 1
  fi
  # Any scheme (ssh://, git+ssh://, ...): a password before the @ is refused.
  if [[ "$url" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/@:]*:[^/@]*@ ]]; then
    echo "[rathsted] the GitOps URL (RATHSTED_GIT_URL, else the origin remote) must not embed a password; use an SSH key" >&2
    return 1
  fi
  return 0
}

# git in the checkout. safe.directory: install.sh's root pass runs git in a
# checkout the invoking user owns.
_r3_git() {
  git -c safe.directory="${ROOT_DIR}" -C "${ROOT_DIR}" "$@"
}

# The GitOps source the installers point Flux at: RATHSTED_GIT_URL, else this
# checkout's origin URL (as written; install.sh turns git@host:path into
# ssh://). Empty when there is neither. Used by the GitRepository render and
# by check_gitops_operator_control, so the two cannot disagree.
r3_gitops_url() {
  if [[ -n "${RATHSTED_GIT_URL:-}" ]]; then
    printf '%s\n' "${RATHSTED_GIT_URL}"
    return 0
  fi
  _r3_git remote get-url origin 2>/dev/null || true
}

# The Flux GitRepository ref spec the installers write: RATHSTED_GIT_REF
# (e.g. "tag: v1.0.3", "branch: main"), else the tag HEAD is exactly on, so
# reconciliation follows the pinned artifact, else "branch: main".
r3_gitops_ref_spec() {
  local t
  if [[ -n "${RATHSTED_GIT_REF:-}" ]]; then
    printf '%s\n' "${RATHSTED_GIT_REF}"
  elif t="$(_r3_git describe --tags --exact-match 2>/dev/null)"; then
    printf 'tag: %s\n' "$t"
  else
    printf 'branch: main\n'
  fi
}

# Refusal of check_gitops_operator_control when the commit GitOps will apply
# cannot be checked. $1: why.
_r3_gitops_unchecked() {
  echo "[rathsted] cannot check RATHSTED_OPERATOR_CONTROL=${RATHSTED_OPERATOR_CONTROL:-} against the policy GitOps will apply: $1" >&2
  echo "[rathsted] Nothing was applied, labelled or recorded. Either:" >&2
  echo "[rathsted]   - fetch that ref into this clone (git fetch <RATHSTED_GIT_URL> <ref>) and re-run," >&2
  echo "[rathsted]   - set RATHSTED_GIT_REF to a readable tag:, branch: or commit: ref that holds the value, or" >&2
  echo "[rathsted]   - leave RATHSTED_OPERATOR_CONTROL unset (the install then uses what Git carries and warns)." >&2
  return 1
}

# For the install paths that bootstrap GitOps (install.sh always,
# install-managed.sh with RATHSTED_GIT_URL). Flux reconciles policies/ from
# Git (cluster/gitops/apps), so a declaration that differs from the literal
# Git carries would be reverted at the first reconcile, leaving namespaces
# stamped with two values. Returns 0 when RATHSTED_OPERATOR_CONTROL is unset,
# or equals the stamp literal GitOps will apply at that commit: the value of
# the one components/operator-control/<value> that
# cluster/gitops/apps/kustomization.yaml enables, else the literal in
# policies/require-namespace-labels.yaml. Two halves:
#   _r3_gitops_resolve_commit  network: r3_gitops_url and r3_gitops_ref_spec,
#                              resolved with git ls-remote (read-only, bounded,
#                              non-interactive; needs the installing user's
#                              read access)
#   _r3_gitops_check_commit    local: that commit, read from this clone
# Fails closed: no URL, a ref other than tag:, branch: or commit:, a ref the
# remote does not have, an unreachable or slow remote, a commit not in this
# clone (or no clone), no single valid literal, or an apps kustomization
# _r3_opctl_component cannot read all refuse (it also refuses keys other
# than apiVersion, kind, resources, components and images there, any other
# components: entry, and keys other than apiVersion, kind and resources in
# policies/kustomization.yaml). Not seen: a resources: entry (in either
# file) that is itself a kustomization or overlay patching the stamp, or a
# manifest that sets the label another way (for example a second policy
# mutating rathsted.io/operator-control); verify is the backstop. A quoted
# policy literal refuses.
# Unset: refuses only when the checkout (HEAD) enables a component, since
# the install would then seed and label with another value. Sets
# R3_GITOPS_URL, R3_GITOPS_REF and
# R3_OPCTL_SHA. No kubectl call: installers run it before anything.
check_gitops_operator_control() {
  local v="${RATHSTED_OPERATOR_CONTROL:-}"
  R3_GITOPS_URL="" R3_GITOPS_REF="" R3_OPCTL_SHA=""
  if [[ -z "$v" ]]; then
    _r3_opctl_unset_check
    return
  fi
  validate_rathsted_operator_control || return 1
  R3_GITOPS_URL="$(r3_gitops_url)"
  R3_GITOPS_REF="$(r3_gitops_ref_spec)"
  _r3_gitops_resolve_commit "$R3_GITOPS_URL" "$R3_GITOPS_REF" || return 1
  _r3_gitops_check_commit "$R3_GITOPS_URL" "$R3_GITOPS_REF" "$R3_OPCTL_SHA"
}

# install.sh's form of the check. $1: the caller's EUID. The user pass runs
# the whole check (the user has the Git credentials) and install.sh passes
# R3_GITOPS_URL, R3_GITOPS_REF, R3_OPCTL_SHA and the marker
# _RATHSTED_OPCTL_CHECKED=url|ref|value|commit through sudo. The marker
# counts only in that root pass (EUID 0 and SUDO_UID set) and only when it
# names this URL, ref, value and _RATHSTED_OPCTL_SHA; then the local half
# re-reads that commit (root usually cannot reach a private remote). Anything
# else runs the whole check.
gitops_operator_control_gate() {
  local euid="$1" v="${RATHSTED_OPERATOR_CONTROL:-}" sha="${_RATHSTED_OPCTL_SHA:-}"
  if [[ -n "$v" && "$euid" == 0 && -n "${SUDO_UID:-}" && -n "$sha" ]]; then
    validate_rathsted_operator_control || return 1
    R3_GITOPS_URL="$(r3_gitops_url)"
    R3_GITOPS_REF="$(r3_gitops_ref_spec)"
    if [[ "${_RATHSTED_OPCTL_CHECKED:-}" == "${R3_GITOPS_URL}|${R3_GITOPS_REF}|${v}|${sha}" ]]; then
      R3_OPCTL_SHA="$sha"
      _r3_gitops_check_commit "$R3_GITOPS_URL" "$R3_GITOPS_REF" "$sha"
      return
    fi
  fi
  check_gitops_operator_control
}

# Network half. $1 url, $2 ref spec. Sets R3_OPCTL_SHA or refuses.
_r3_gitops_resolve_commit() {
  local url="$1" spec="$2" name="" refs rc=0
  local -a to=()
  R3_OPCTL_SHA=""
  [[ -z "$url" ]] && { _r3_gitops_unchecked "no RATHSTED_GIT_URL and no origin remote"; return 1; }
  case "$spec" in
    "tag: "?*) name="refs/tags/${spec#tag: }" ;;
    "branch: "?*) name="refs/heads/${spec#branch: }" ;;
    "commit: "?*) R3_OPCTL_SHA="${spec#commit: }"; return 0 ;;
    *) _r3_gitops_unchecked "ref '${spec}' is not tag:, branch: or commit:, so its commit cannot be resolved"; return 1 ;;
  esac
  command -v timeout >/dev/null 2>&1 && to=(timeout 60)
  refs="$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}" \
    ${to[@]+"${to[@]}"} git -c safe.directory="${ROOT_DIR}" -C "${ROOT_DIR}" \
    ls-remote "$url" "$name" "${name}^{}" 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 124 ]]; then
      _r3_gitops_unchecked "git ls-remote ${url} timed out after 60 s"
    elif [[ "$url" == https://* ]]; then
      _r3_gitops_unchecked "git ls-remote could not read ${url}. If it needs credentials that only RATHSTED_GIT_TOKEN carries (the installer gives that token to Flux, not to git), git cannot read it non-interactively here: give the installing user a credential helper or SSH access for that URL"
    else
      _r3_gitops_unchecked "git ls-remote could not read ${url} (non-interactive: no password or passphrase prompt)"
    fi
    return 1
  fi
  # Annotated tags: the peeled (^{}) line is the commit.
  R3_OPCTL_SHA="$(printf '%s\n' "$refs" | awk -v n="$name" '$2 == n "^{}" { p = $1 } $2 == n { r = $1 } END { print (p != "" ? p : r) }')"
  [[ -z "$R3_OPCTL_SHA" ]] && { _r3_gitops_unchecked "${url} has no ${name} ('${spec}')"; return 1; }
  return 0
}

# The patches: block of the stamp patch for value $1: the installer render
# and every components/operator-control/<value> carry exactly this.
_r3_opctl_patches() {
  printf '%s\n' "patches:" \
    "  - target:" \
    "      group: kyverno.io" \
    "      kind: ClusterPolicy" \
    "      name: require-namespace-labels" \
    "    patch: |-" \
    "      - op: test" \
    "        path: /spec/rules/0/name" \
    "        value: stamp-operator-control" \
    "      - op: replace" \
    "        path: /spec/rules/0/mutate/patchStrategicMerge/metadata/labels/rathsted.io~1operator-control" \
    "        value: $1"
}

# Refusals of _r3_opctl_component. $1 commit, $2 ref spec, $3 why.
_r3_opctl_refused_tail() {
  echo "[rathsted] Enable exactly one, as a top-level 'components:' entry written '- ../../../components/operator-control/<value>' (docs/operator-control-components.md)," >&2
  echo "[rathsted] or remove the reference and commit the literal to policies/require-namespace-labels.yaml. Nothing was applied, labelled or recorded." >&2
  return 1
}
_r3_opctl_component_refused() {
  echo "[rathsted] cannot use the operator-control component reference in cluster/gitops/apps/kustomization.yaml at $1 ('$2'): $3" >&2
  _r3_opctl_refused_tail
}
_r3_opctl_apps_refused() {
  echo "[rathsted] cannot tell which operator-control literal the kustomization GitOps builds applies, at $1 ('$2'): $3" >&2
  echo "[rathsted] The gate reads cluster/gitops/apps/kustomization.yaml as text, so it accepts only one YAML document with each of the keys apiVersion, kind, resources, components, images at most once." >&2
  _r3_opctl_refused_tail
}

# Scan an apps kustomization (stdin). One line per finding:
#   ref <value>   a plain '- ../../../components/operator-control/<value>' entry
#                 of the top-level components: list
#   odd <line>    any other non-comment line that mentions operator-control
#   dup <key>     a top-level key seen more than once (kustomize keeps the last)
#   doc <line>    a '---' or '...' after the first content line (kustomize reads
#                 only the first document)
#   key <key>     a top-level key outside $1 (default apiVersion, kind,
#                 resources, components, images)
#   top <line>    a column-0 line that is not a plain key, a list item or a comment
#   cmp <line>    anything under components: other than the operator-control
#                 entry (another component would apply after or before it), or
#                 an inline value other than []
# $1 (optional): the allowed top-level keys, as an awk alternation.
_r3_opctl_scan() {
  awk -v allow="^(${1:-apiVersion|kind|resources|components|images})\$" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^(---|\.\.\.)([[:space:]]|$)/ { if (seen) print "doc " NR; next }
    { seen = 1 }
    /^[A-Za-z][A-Za-z0-9_-]*:([[:space:]]|$)/ {
      key = $0; sub(/:.*/, "", key)
      if (count[key]++) print "dup " key
      if (key !~ allow) print "key " key
    }
    /^[^[:space:]-]/ && !/^[A-Za-z][A-Za-z0-9_-]*:([[:space:]]|$)/ { print "top " NR; key = "" }
    key == "components" {
      if ($0 ~ /^components:/) {
        rest = $0; sub(/^components:[[:space:]]*/, "", rest)
        if (rest != "" && rest != "[]") print "cmp " NR
      } else if ($0 !~ /^[[:space:]]*-[[:space:]]+\.\.\/\.\.\/\.\.\/components\/operator-control\/[a-z-]+$/) print "cmp " NR
    }
    /operator-control/ {
      if (key == "components" && $0 ~ /^[[:space:]]*-[[:space:]]+\.\.\/\.\.\/\.\.\/components\/operator-control\/[a-z-]+$/) {
        v = $0; sub(/.*\//, "", v); print "ref " v
      } else print "odd " NR
    }'
}

# The structural findings of _r3_opctl_scan (stdin) as one line of reasons.
# $1: the allowed keys, for the message. Empty when there are none.
_r3_opctl_scan_bad() {
  sed -n -e 's/^dup \(.*\)/top-level key \1 appears more than once (kustomize keeps the last);/p' \
    -e "s/^doc \(.*\)/line \1 starts another YAML document ('---'; kustomize reads only the first);/p" \
    -e "s/^key \(.*\)/top-level key \1 is not one of $1;/p" \
    -e 's/^top \(.*\)/line \1 is not a plain top-level key;/p' \
    -e 's/^cmp \(.*\)/line \1 under components: is not the operator-control entry (components: may hold only the operator-control entry; another component would apply its own patches);/p' \
    | tr '\n' ' '
}

# $1 commit, $2 path (from the repository root, as git show <sha>:<path>
# reads it). Prints the path when it exists at that commit, nothing when it
# does not; non-zero when git cannot list the commit.
_r3_git_has() {
  _r3_git ls-tree --full-tree --name-only "$1" -- "$2" 2>/dev/null
}

# The operator-control component cluster/gitops/apps/kustomization.yaml
# enables at commit $1 ($2: ref spec, for messages), read as text with git
# show: no kubectl or kustomize, so install.sh's user pass can run it before
# either exists. Prints the component's value, or nothing when the file is
# absent or enables none (the policy literal then applies). Refuses when git
# cannot list the commit; when a non-comment line mentions operator-control
# outside a plain entry of the top-level components: list; on a duplicate
# top-level key, a second YAML document, a top-level key other than
# apiVersion, kind, resources, components and images, or a column-0 line
# that is not a plain key; on more than one entry or a value outside
# R3_OPERATOR_CONTROLS; and unless components/operator-control/<value>/
# kustomization.yaml at that commit is, comment lines aside, exactly the
# Component Foundations ships for <value>.
_r3_opctl_component() {
  local sha="$1" spec="$2" apps=cluster/gitops/apps/kustomization.yaml has text scan odd bad n v cf ctext want vals
  if ! has="$(_r3_git_has "$sha" "$apps")"; then
    _r3_opctl_apps_refused "$sha" "$spec" "git cannot list ${sha}"
    return 1
  fi
  [[ -z "$has" ]] && return 0
  if ! text="$(_r3_git show "${sha}:${apps}" 2>/dev/null)"; then
    _r3_opctl_component_refused "$sha" "$spec" "${apps} cannot be read"
    return 1
  fi
  scan="$(printf '%s\n' "$text" | _r3_opctl_scan)"
  odd="$(printf '%s\n' "$scan" | sed -n 's/^odd //p' | tr '\n' ' ')"
  if [[ -n "$odd" ]]; then
    _r3_opctl_component_refused "$sha" "$spec" "line(s) ${odd}mention operator-control but are not a plain entry of the top-level components: list"
    return 1
  fi
  bad="$(printf '%s\n' "$scan" | _r3_opctl_scan_bad 'apiVersion, kind, resources, components, images')"
  if [[ -n "$bad" ]]; then
    _r3_opctl_apps_refused "$sha" "$spec" "$bad"
    return 1
  fi
  n="$(printf '%s\n' "$scan" | grep -c '^ref ' || true)"
  [[ "$n" == 0 ]] && return 0
  if [[ "$n" != 1 ]]; then
    _r3_opctl_component_refused "$sha" "$spec" "${n} operator-control component references; enable exactly one"
    return 1
  fi
  v="$(printf '%s\n' "$scan" | sed -n 's/^ref //p')"
  if ! _r3_in "$v" "${R3_OPERATOR_CONTROLS[@]}"; then
    _r3_opctl_component_refused "$sha" "$spec" "'${v}' is not one of: customer, domestic-provider, foreign-provider, rathsted"
    return 1
  fi
  cf="components/operator-control/${v}/kustomization.yaml"
  if ! ctext="$(_r3_git show "${sha}:${cf}" 2>/dev/null)"; then
    _r3_opctl_component_refused "$sha" "$spec" "${cf} cannot be read at ${sha}"
    return 1
  fi
  want="$(printf '%s\n' "apiVersion: kustomize.config.k8s.io/v1alpha1" "kind: Component"; _r3_opctl_patches "$v")"
  if [[ "$(printf '%s\n' "$ctext" | grep -vE '^[[:space:]]*(#|$)' || true)" != "$want" ]]; then
    vals="$(sed -n 's/^[[:space:]]*value:[[:space:]]*//p' <<<"$ctext" | grep -vx 'stamp-operator-control' | tr '\n' ' ')"
    if [[ -n "$vals" && "$vals" != "${v} " ]]; then
      _r3_opctl_component_refused "$sha" "$spec" "${cf} at ${sha} patches rathsted.io/operator-control to ${vals% }, not ${v}"
    else
      _r3_opctl_component_refused "$sha" "$spec" "${cf} at ${sha} is not the Component Foundations ships for ${v} (comment lines aside)"
    fi
    return 1
  fi
  printf '%s\n' "$v"
}

# policies/kustomization.yaml at commit $1 ($2: ref spec) must not patch:
# refuses unless its top-level keys are only apiVersion, kind and resources,
# each once, in one YAML document, with no mention of operator-control, or
# when git cannot list the commit. Absent is fine.
_r3_opctl_policies_kustomization() {
  local sha="$1" spec="$2" f=policies/kustomization.yaml has text scan bad
  if ! has="$(_r3_git_has "$sha" "$f")"; then
    _r3_opctl_apps_refused "$sha" "$spec" "git cannot list ${sha}"
    return 1
  fi
  [[ -z "$has" ]] && return 0
  if ! text="$(_r3_git show "${sha}:${f}" 2>/dev/null)"; then
    _r3_opctl_apps_refused "$sha" "$spec" "${f} cannot be read"
    return 1
  fi
  scan="$(printf '%s\n' "$text" | _r3_opctl_scan 'apiVersion|kind|resources')"
  bad="$(printf '%s\n' "$scan" | _r3_opctl_scan_bad 'apiVersion, kind, resources')"
  grep -q '^odd ' <<<"$scan" && bad="${bad}it mentions operator-control;"
  if [[ -n "$bad" ]]; then
    _r3_opctl_apps_refused "$sha" "$spec" "${f}: ${bad} only apiVersion, kind and resources are read there, since anything else can change the stamp"
    return 1
  fi
}

# RATHSTED_OPERATOR_CONTROL unset on a GitOps path. Reads this checkout's
# HEAD only (no network). Refuses when its cluster/gitops/apps/kustomization.yaml
# enables an operator-control component: the installer would seed and label
# the platform namespaces with the policy literal, then Flux would stamp the
# component's value. Paths are read both from the repository root (what Flux
# applies when this repository is the GitOps source) and under ROOT_DIR's
# prefix (when this checkout is a subdirectory of a larger repository); the
# first that enables a component is reported. Returns 0 when there is no git
# checkout, or git cannot read it: an unset install never needed one.
_r3_opctl_unset_check() {
  local apps="" p prefix has text vals=""
  _r3_git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 || return 0
  prefix="$(_r3_git rev-parse --show-prefix 2>/dev/null || true)"
  for p in "cluster/gitops/apps/kustomization.yaml" "${prefix}cluster/gitops/apps/kustomization.yaml"; do
    has="$(_r3_git_has HEAD "$p")" || continue
    [[ -z "$has" ]] && continue
    text="$(_r3_git show "HEAD:${p}" 2>/dev/null)" || continue
    vals="$(printf '%s\n' "$text" | _r3_opctl_scan | sed -n 's/^ref //p' | tr '\n' ' ')"
    apps="$p"
    [[ -n "$vals" ]] && break
  done
  [[ -z "$vals" ]] && return 0
  if [[ "$vals" == *" "?* ]]; then
    echo "[rathsted] RATHSTED_OPERATOR_CONTROL is not set, and ${apps} in this checkout (HEAD) enables more than one operator-control component (${vals% }). Enable exactly one and set RATHSTED_OPERATOR_CONTROL to its value. Nothing was applied, labelled or recorded." >&2
    return 1
  fi
  echo "[rathsted] RATHSTED_OPERATOR_CONTROL is not set, but ${apps} in this checkout (HEAD) enables components/operator-control/${vals% }." >&2
  echo "[rathsted] The install would seed the policies and label the platform namespaces with the policy's literal, then Flux would stamp ${vals% } and verify would flag them." >&2
  echo "[rathsted] Re-run with RATHSTED_OPERATOR_CONTROL=${vals% } (the installer then checks the commit GitOps will apply). Nothing was applied, labelled or recorded." >&2
  return 1
}

# Local half. $1 url, $2 ref spec (both for messages), $3 commit.
_r3_gitops_check_commit() {
  local url="$1" spec="$2" sha="$3" v="${RATHSTED_OPERATOR_CONTROL:-}" text lit n cmp
  local file=policies/require-namespace-labels.yaml
  if ! [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]]; then
    _r3_gitops_unchecked "'${sha}' is not a commit id ('${spec}')"
    return 1
  fi
  if ! _r3_git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    _r3_gitops_unchecked "commit ${sha} ('${spec}' on ${url}) is not in this clone (or there is no clone)"
    return 1
  fi
  _r3_opctl_policies_kustomization "$sha" "$spec" || return 1
  cmp="$(_r3_opctl_component "$sha" "$spec")" || return 1
  if [[ -n "$cmp" ]]; then
    if [[ "$cmp" != "$v" ]]; then
      echo "[rathsted] RATHSTED_OPERATOR_CONTROL=${v}, but GitOps will apply components/operator-control/${cmp} (enabled in cluster/gitops/apps/kustomization.yaml at ${sha}, '${spec}' on ${url}), which stamps ${cmp}." >&2
      echo "[rathsted] Flux reconciles policies/ from Git (cluster/gitops/apps), so ${v} would be reverted at its first reconcile." >&2
      echo "[rathsted] Change that entry to ../../../components/operator-control/${v}, or remove it and commit rathsted.io/operator-control: ${v} to ${file}; push, and re-run. Nothing was applied, labelled or recorded." >&2
      return 1
    fi
    echo "[rathsted] RATHSTED_OPERATOR_CONTROL=${v} matches components/operator-control/${v}, enabled in cluster/gitops/apps/kustomization.yaml at ${sha} ('${spec}' on ${url}), the commit GitOps will apply"
    return 0
  fi
  if ! text="$(_r3_git show "${sha}:${file}" 2>/dev/null)"; then
    _r3_gitops_unchecked "${file} cannot be read at ${sha} ('${spec}')"
    return 1
  fi
  lit="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*rathsted\.io\/operator-control:[[:space:]]*\([A-Za-z-]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p')"
  n="$(printf '%s' "$lit" | grep -c . || true)"
  if [[ "$n" != 1 ]] || ! _r3_in "$lit" "${R3_OPERATOR_CONTROLS[@]}"; then
    _r3_gitops_unchecked "cannot read one unquoted rathsted.io/operator-control literal in ${file} at ${sha} ('${spec}')"
    return 1
  fi
  if [[ "$lit" != "$v" ]]; then
    echo "[rathsted] RATHSTED_OPERATOR_CONTROL=${v}, but the policy GitOps will apply (${file} at ${sha}, '${spec}' on ${url}) stamps ${lit}." >&2
    echo "[rathsted] Flux reconciles policies/ from Git (cluster/gitops/apps), so ${v} would be reverted at its first reconcile." >&2
    echo "[rathsted] In your GitOps source, either enable components/operator-control/${v} in cluster/gitops/apps/kustomization.yaml (docs/operator-control-components.md)" >&2
    echo "[rathsted] or commit rathsted.io/operator-control: ${v} to ${file}; push it, and re-run. Nothing was applied, labelled or recorded." >&2
    return 1
  fi
  echo "[rathsted] RATHSTED_OPERATOR_CONTROL=${v} matches ${file} at ${sha} ('${spec}' on ${url}), the commit GitOps will apply"
}

# GitOps install paths, after applying make configure's rendered policies.
# $1: the rendered directory (config/rendered). Flux applies policies/ from
# Git at its first reconcile, so a rendered restrict-registries.yaml or
# require-signed-images.yaml that differs from policies/<file> at the commit
# GitOps will apply is replaced within about a minute. Compares with that
# commit (R3_OPCTL_SHA, which the gate resolves when RATHSTED_OPERATOR_CONTROL
# is set), else with this checkout's HEAD (read from the repository root
# under ROOT_DIR's prefix). Warns on stderr; never fails the install. With
# no difference at HEAD, prints one line saying HEAD was compared (unpushed
# commits there are not what Flux applies).
warn_rendered_policies_gitops() {
  local dir="$1" sha="${R3_OPCTL_SHA:-}" ref where f text diffs="" prefix compared=""
  if [[ -n "$sha" ]]; then
    ref="${sha}:policies/" where="${sha}, the commit GitOps will apply"
  elif _r3_git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    prefix="$(_r3_git rev-parse --show-prefix 2>/dev/null || true)"
    ref="HEAD:${prefix}policies/"
    where="this checkout's HEAD (the commit GitOps will apply is resolved only when RATHSTED_OPERATOR_CONTROL is set)"
  else
    echo "[rathsted] WARNING: cannot compare config/rendered/ with policies/ in Git (no git checkout). Flux applies policies/ from your GitOps source at its first reconcile and replaces the rendered registry/signing policies unless that source carries them (docs/upgrade-guide.md)." >&2
    return 0
  fi
  for f in restrict-registries.yaml require-signed-images.yaml; do
    [[ -f "${dir}/${f}" ]] || continue
    compared="${compared}${f} "
    if ! text="$(_r3_git show "${ref}${f}" 2>/dev/null)" || [[ "$text" != "$(cat "${dir}/${f}")" ]]; then
      diffs="${diffs}${f} "
    fi
  done
  if [[ -z "$diffs" ]]; then
    # Local HEAD is not necessarily what Flux will fetch.
    [[ -z "$sha" && -n "$compared" ]] && echo "[rathsted] config/rendered/ ${compared% } match policies/ at this checkout's local HEAD, not at the GitOps source: unpushed commits are not seen, and Flux applies only what is pushed"
    return 0
  fi
  echo "[rathsted] WARNING: config/rendered/ ${diffs% } differ from policies/ at ${where}." >&2
  echo "[rathsted] Flux applies policies/ from Git at its first reconcile (within about a minute) and replaces them; pods from your registry are then denied at their next creation." >&2
  echo "[rathsted] To keep them: copy config/rendered/<file> to policies/<file> in your GitOps source, commit and push (docs/upgrade-guide.md)." >&2
}

# $1: an empty directory. Writes $1/policies (a copy of ${ROOT_DIR}/policies)
# and $1/kustomization.yaml, which patches the stamp-operator-control literal
# to RATHSTED_OPERATOR_CONTROL. Apply it with kubectl apply -k "$1". The
# tracked files are never edited. The patch addresses the rule by index, so it
# first tests that rule 0 is stamp-operator-control: if the policy's rules are
# reordered, kustomize fails instead of patching the wrong rule. No kubectl call.
render_operator_control_policies() {
  local dir="$1" v="${RATHSTED_OPERATOR_CONTROL:-}"
  if [[ -z "$v" ]]; then
    echo "[rathsted] render_operator_control_policies: RATHSTED_OPERATOR_CONTROL is not set" >&2
    return 1
  fi
  validate_rathsted_operator_control || return 1
  if ! { mkdir -p "$dir" && cp -R "${ROOT_DIR}/policies" "${dir}/policies"; }; then
    echo "[rathsted] cannot copy ${ROOT_DIR}/policies to ${dir}" >&2
    return 1
  fi
  {
    printf '%s\n' "# Rendered by bootstrap/lib/jurisdiction.sh from RATHSTED_OPERATOR_CONTROL." \
      "apiVersion: kustomize.config.k8s.io/v1beta1" "kind: Kustomization" "resources:" "  - policies"
    _r3_opctl_patches "$v"
  } > "${dir}/kustomization.yaml"
}

# Print the operator-control literal the live require-namespace-labels policy
# stamps. Read from the cluster, not from policies/, because a deploy overlay
# may have patched it. Returns non-zero unless the value is in R3_OPERATOR_CONTROLS.
stamped_operator_control() {
  local v
  v="$(kubectl get cpol require-namespace-labels \
    -o jsonpath='{.spec.rules[?(@.name=="stamp-operator-control")].mutate.patchStrategicMerge.metadata.labels.rathsted\.io/operator-control}' \
    2>/dev/null)" || v=""
  if ! _r3_in "$v" "${R3_OPERATOR_CONTROLS[@]}"; then
    echo "[rathsted] cannot read a valid rathsted.io/operator-control from the live require-namespace-labels policy (got '${v}')" >&2
    return 1
  fi
  printf '%s\n' "$v"
}

# Print the jurisdiction recorded by apply_platform_namespace_labels in the
# Foundations contract ConfigMap. Prints nothing and returns 0 when nothing is
# recorded: the key is absent, or the ConfigMap is NotFound. Any other read
# error returns 2, so a broken read never downgrades verify to a warning.
recorded_jurisdiction() {
  local out err errf rc=0
  errf="$(mktemp)" || return 2
  out="$(kubectl get configmap "${R3_CONTRACT_NAME}" -n "${R3_CONTRACT_NS}" \
    -o jsonpath='{.data.r3_jurisdiction}' 2>"$errf")" || rc=$?
  err="$(cat "$errf")"
  rm -f "$errf"
  if [[ "$rc" -ne 0 ]]; then
    [[ "$err" == *NotFound* ]] && return 0
    echo "[rathsted] cannot read ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}: ${err}" >&2
    return 2
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# Print the operator-control recorded by declare_operator_control. Same
# contract as recorded_jurisdiction: empty and 0 when not recorded, 2 on any
# read error other than NotFound.
recorded_operator_control() {
  local out err errf rc=0
  errf="$(mktemp)" || return 2
  out="$(kubectl get configmap "${R3_CONTRACT_NAME}" -n "${R3_CONTRACT_NS}" \
    -o jsonpath='{.data.r3_operator_control}' 2>"$errf")" || rc=$?
  err="$(cat "$errf")"
  rm -f "$errf"
  if [[ "$rc" -ne 0 ]]; then
    [[ "$err" == *NotFound* ]] && return 0
    echo "[rathsted] cannot read ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}: ${err}" >&2
    return 2
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# Call after the policies are applied (from render_operator_control_policies
# when RATHSTED_OPERATOR_CONTROL is set) and before apply_platform_namespace_labels,
# so the platform namespaces get the declared value.
# Set: the live stamp must equal RATHSTED_OPERATOR_CONTROL; then the value is
# recorded as r3_operator_control in the contract ConfigMap, and verify
# compares the live stamp with it.
# Unset: writes nothing and warns with the value the live policy stamps. Never
# fails: an install without the variable behaves as it did before it existed.
declare_operator_control() {
  local v="${RATHSTED_OPERATOR_CONTROL:-}" ctl="" rec=""
  if [[ -z "$v" ]]; then
    if ctl="$(stamped_operator_control 2>/dev/null)"; then
      echo "[rathsted] WARNING: RATHSTED_OPERATOR_CONTROL is not set, so require-namespace-labels stamps rathsted.io/operator-control=${ctl} on every namespace."
    else
      ctl=""
      echo "[rathsted] WARNING: RATHSTED_OPERATOR_CONTROL is not set, and the stamped rathsted.io/operator-control could not be read."
    fi
    if [[ -z "$ctl" || "$ctl" == "foreign-provider" ]]; then
      echo "[rathsted] WARNING: the tracked policy's value is foreign-provider, written for Rathsted's reference deployment; it is not a fact about this cluster."
    fi
    # A previous install may have declared a value; it is still recorded, and
    # verify compares the stamp with it.
    rec="$(recorded_operator_control 2>/dev/null)" || rec=""
    if [[ -n "$rec" && "$rec" != "$ctl" ]]; then
      echo "[rathsted] WARNING: this cluster recorded r3_operator_control=${rec} from an earlier install; verify fails until RATHSTED_OPERATOR_CONTROL=${rec} is declared again."
      echo "[rathsted] If that record no longer says who controls the operator, remove it (docs/upgrade-guide.md): ${R3_REMOVE_OPCTL_CMD}"
    fi
    echo "[rathsted] Declare who controls this cluster's operator: re-run with RATHSTED_OPERATOR_CONTROL=customer|domestic-provider|foreign-provider|rathsted"
    return 0
  fi
  validate_rathsted_operator_control || return 1
  ctl="$(stamped_operator_control)" || return 1
  if [[ "$ctl" != "$v" ]]; then
    echo "[rathsted] RATHSTED_OPERATOR_CONTROL=${v}, but the live require-namespace-labels policy stamps ${ctl}; nothing was recorded" >&2
    return 1
  fi
  _r3_retry kubectl patch configmap "${R3_CONTRACT_NAME}" -n "${R3_CONTRACT_NS}" \
    --type merge -p "{\"data\":{\"r3_operator_control\":\"${v}\"}}" \
    || { echo "[rathsted] could not record r3_operator_control in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}" >&2; return 1; }
  echo "[rathsted] require-namespace-labels stamps rathsted.io/operator-control=${v} (declared); recorded r3_operator_control=${v} in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}"
  echo "[rathsted] NOTE: Flux reconciles policies/ from the GitOps source (cluster/gitops/apps). Unless that source stamps ${v} too, Flux restores its own literal at the next reconcile and verify fails."
}

# Print "owner|environment|jurisdiction" for namespace $1. Non-zero if unreadable.
_r3_ns_labels() {
  kubectl get namespace "$1" \
    -o jsonpath='{.metadata.labels.owner}{"|"}{.metadata.labels.environment}{"|"}{.metadata.labels.rathsted\.io/jurisdiction}'
}

# With RATHSTED_JURISDICTION set, for every RATHSTED_PLATFORM_NAMESPACES entry:
#   - rathsted.io/jurisdiction=<value>; refused, with nothing written, if any of
#     them already declares a different jurisdiction
#   - rathsted.io/operator-control=<the live stamped value>, always overwritten
#     (the cluster fact wins). Set here because Kyverno's resourceFilters
#     ([*/*,kyverno,*]) keep updates to the kyverno namespace out of admission,
#     so the stamp rule never runs on it.
#   - owner=platform, environment=platform, only where absent
# All three are read before any is written. Then the jurisdiction is recorded
# as r3_jurisdiction in flux-system/rathsted-foundations-contract, which makes
# verify strict.
# Unset: labels nothing (no jurisdiction is guessed) and prints a warning.
# Call after the policies are in place.
apply_platform_namespace_labels() {
  local j="${RATHSTED_JURISDICTION:-}" ctl ns vals o e cj i
  local -a owners=() envs=() conflicts=() args=()
  if [[ -z "$j" ]]; then
    echo "[rathsted] WARNING: RATHSTED_JURISDICTION is not set, so these namespaces were left without jurisdiction labels: ${RATHSTED_PLATFORM_NAMESPACES[*]}"
    echo "[rathsted] WARNING: they do not meet the namespace label convention until labelled. Re-run with RATHSTED_JURISDICTION=ca|us|fr, or run:"
    echo "[rathsted]   CTL=\"\$(kubectl get cpol require-namespace-labels -o jsonpath='{.spec.rules[?(@.name==\"stamp-operator-control\")].mutate.patchStrategicMerge.metadata.labels.rathsted\\.io/operator-control}')\""
    echo "[rathsted]   kubectl label namespace ${RATHSTED_PLATFORM_NAMESPACES[*]} owner=platform environment=platform rathsted.io/jurisdiction=<ca|us|fr> rathsted.io/operator-control=\"\$CTL\" --overwrite"
    echo "[rathsted] Check with: ./bootstrap/jurisdiction-audit.sh"
    return 0
  fi
  validate_rathsted_jurisdiction || return 1
  ctl="$(stamped_operator_control)" || return 1

  i=0
  for ns in "${RATHSTED_PLATFORM_NAMESPACES[@]}"; do
    vals="$(_r3_ns_labels "$ns")" \
      || { echo "[rathsted] cannot read namespace ${ns}; no platform namespace was labelled" >&2; return 1; }
    IFS='|' read -r o e cj <<<"$vals" || true
    owners[i]="$o"; envs[i]="$e"
    if [[ -n "$cj" && "$cj" != "$j" ]]; then
      conflicts+=("${ns} has rathsted.io/jurisdiction=${cj}")
    fi
    i=$((i + 1))
  done
  if (( ${#conflicts[@]} > 0 )); then
    echo "[rathsted] RATHSTED_JURISDICTION=${j}, but: ${conflicts[*]}. No platform namespace was labelled." >&2
    echo "[rathsted] A namespace's jurisdiction is a declaration; change it deliberately with kubectl label namespace <name> rathsted.io/jurisdiction=<value> --overwrite, or re-run with the declared value." >&2
    return 1
  fi

  i=0
  for ns in "${RATHSTED_PLATFORM_NAMESPACES[@]}"; do
    args=()
    [[ -z "${owners[i]}" ]] && args+=(owner=platform)
    [[ -z "${envs[i]}" ]] && args+=(environment=platform)
    args+=("rathsted.io/jurisdiction=${j}" "rathsted.io/operator-control=${ctl}")
    _r3_retry kubectl label namespace "$ns" "${args[@]}" --overwrite \
      || { echo "[rathsted] could not label namespace ${ns}" >&2; return 1; }
    i=$((i + 1))
  done
  _r3_retry kubectl patch configmap "${R3_CONTRACT_NAME}" -n "${R3_CONTRACT_NS}" \
    --type merge -p "{\"data\":{\"r3_jurisdiction\":\"${j}\"}}" \
    || { echo "[rathsted] could not record r3_jurisdiction in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}" >&2; return 1; }
  echo "[rathsted] Labelled ${RATHSTED_PLATFORM_NAMESPACES[*]}: rathsted.io/jurisdiction=${j}, rathsted.io/operator-control=${ctl}; recorded r3_jurisdiction=${j} in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}"
}

# Read-only audit of the namespace label convention. Prints one line per namespace with its
# owner, environment, rathsted.io/jurisdiction and rathsted.io/operator-control,
# and a verdict: conforming, NON-CONFORMING (with the reason when a value is
# valid but wrong), or system (excluded).
# $1 (optional): the jurisdiction the platform namespaces must carry.
# Returns 0 when every non-system namespace conforms, 1 when any does not,
# 2 when the namespaces or the stamped operator-control cannot be read.
jurisdiction_audit() {
  local expect="${1:-}" stamped rows name owner env jur ctl verdict
  local -a bad=()
  local seen=0
  if ! stamped="$(stamped_operator_control)"; then
    echo "[rathsted] jurisdiction audit: cannot read the stamped operator-control" >&2
    return 2
  fi
  if ! rows="$(kubectl get namespaces \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.owner}{"|"}{.metadata.labels.environment}{"|"}{.metadata.labels.rathsted\.io/jurisdiction}{"|"}{.metadata.labels.rathsted\.io/operator-control}{"\n"}{end}')"; then
    echo "[rathsted] jurisdiction audit: cannot list namespaces" >&2
    return 2
  fi
  printf '%-28s %-14s %-14s %-12s %-18s %s\n' NAMESPACE OWNER ENVIRONMENT JURISDICTION OPERATOR-CONTROL VERDICT
  # "|" is not whitespace, so empty fields stay empty (a tab IFS merges them).
  while IFS='|' read -r name owner env jur ctl; do
    [[ -z "$name" ]] && continue
    seen=$((seen + 1))
    if _r3_in "$name" "${R3_SYSTEM_NAMESPACES[@]}"; then
      verdict="system (excluded)"
    elif [[ -z "$owner" || -z "$env" ]] \
        || ! _r3_in "$jur" "${R3_JURISDICTIONS[@]}" \
        || ! _r3_in "$ctl" "${R3_OPERATOR_CONTROLS[@]}"; then
      verdict="NON-CONFORMING"
    elif [[ "$ctl" != "$stamped" ]]; then
      verdict="NON-CONFORMING (operator-control != ${stamped})"
    elif [[ -n "$expect" && "$jur" != "$expect" ]] && _r3_in "$name" "${RATHSTED_PLATFORM_NAMESPACES[@]}"; then
      verdict="NON-CONFORMING (jurisdiction != ${expect})"
    else
      verdict="conforming"
    fi
    [[ "$verdict" == NON-CONFORMING* ]] && bad+=("$name")
    printf '%-28s %-14s %-14s %-12s %-18s %s\n' "$name" "${owner:--}" "${env:--}" "${jur:--}" "${ctl:--}" "$verdict"
  done <<<"$rows"
  if (( seen == 0 )); then
    echo "[rathsted] jurisdiction audit: no namespaces listed" >&2
    return 2
  fi
  if (( ${#bad[@]} > 0 )); then
    echo "[rathsted] jurisdiction audit: non-conforming: ${bad[*]}"
    return 1
  fi
  echo "[rathsted] jurisdiction audit: every non-system namespace conforms"
}

# verify.sh's verdict on the namespace label convention. $1: release mode (true|false).
# Strict when RATHSTED_JURISDICTION is set in verify's environment, when the
# install recorded r3_jurisdiction in the contract ConfigMap (the installer
# then promised the labels), when any platform namespace declares a
# jurisdiction (so deleting the recorded key alone does not downgrade), or
# under --release. The expected platform jurisdiction is RATHSTED_JURISDICTION,
# else the recorded one, else the one value the platform namespaces declare;
# with neither set nor recorded, platform declarations that differ fail.
# A contract read error other than NotFound fails.
# Sets R3_VERIFY_MSG. Returns 0 (ok), 1 (warn) or 2 (fail).
# shellcheck disable=SC2034  # R3_VERIFY_MSG is read by the caller (verify.sh)
jurisdiction_verify_check() {
  local release="${1:-false}" env_j="${RATHSTED_JURISDICTION:-}" rec exp why="" rc=0 ns vals d common=""
  local -a declared=()
  if ! rec="$(recorded_jurisdiction)"; then
    R3_VERIFY_MSG="Cannot read ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}, so cannot tell whether a jurisdiction was recorded"
    return 2
  fi
  for ns in "${RATHSTED_PLATFORM_NAMESPACES[@]}"; do
    vals="$(_r3_ns_labels "$ns" 2>/dev/null)" || continue
    [[ -n "${vals##*|}" ]] && declared+=("${ns}=${vals##*|}")
  done
  if [[ -n "$env_j" && -n "$rec" && "$env_j" != "$rec" ]]; then
    R3_VERIFY_MSG="RATHSTED_JURISDICTION=${env_j}, but the install recorded r3_jurisdiction=${rec} in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}"
    return 2
  fi
  exp="${env_j:-$rec}"
  if [[ -z "$exp" ]] && (( ${#declared[@]} > 0 )); then
    for d in "${declared[@]}"; do
      if [[ -z "$common" ]]; then common="${d#*=}"
      elif [[ "${d#*=}" != "$common" ]]; then
        R3_VERIFY_MSG="Platform namespaces declare different jurisdictions (${declared[*]}) and none is recorded or set"
        return 2
      fi
    done
    exp="$common"
  fi
  if [[ -n "$env_j" ]]; then why="RATHSTED_JURISDICTION=${env_j}"
  elif [[ -n "$rec" ]]; then why="install recorded r3_jurisdiction=${rec}"
  elif (( ${#declared[@]} > 0 )); then why="platform namespaces declare rathsted.io/jurisdiction: ${declared[*]}"
  elif [[ "$release" == "true" ]]; then why="--release"
  fi
  jurisdiction_audit ${exp:+"$exp"} || rc=$?
  case "$rc" in
    0)
      R3_VERIFY_MSG="Every non-system namespace has the jurisdiction labels${exp:+; platform namespaces declare ${exp}}"
      return 0 ;;
    1)
      if [[ -n "$why" ]]; then
        R3_VERIFY_MSG="Namespaces without the jurisdiction labels (strict: ${why}); see docs/upgrade-guide.md"
        return 2
      fi
      R3_VERIFY_MSG="Namespaces without the jurisdiction labels; warning only: no r3_jurisdiction is recorded in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME} and no platform namespace declares a jurisdiction (strict with RATHSTED_JURISDICTION or --release; see docs/upgrade-guide.md)"
      return 1 ;;
    *)
      R3_VERIFY_MSG="Cannot audit the namespace jurisdiction labels: namespaces or the require-namespace-labels policy could not be read"
      return 2 ;;
  esac
}

# verify.sh's verdict on the stamped operator-control. $1: release mode
# (true|false). An undeclared stamp is a warning in both modes, so existing
# installs and release verification keep passing; whether it should fail is
# a separate decision.
# The declaration is RATHSTED_OPERATOR_CONTROL in verify's environment, else
# the recorded r3_operator_control; with one, the live stamp must equal it.
# Fails when verify's value is invalid or differs from the recorded one, and
# when the contract or the stamp cannot be read.
# Sets R3_VERIFY_MSG. Returns 0 (ok), 1 (warn) or 2 (fail).
# shellcheck disable=SC2034  # R3_VERIFY_MSG is read by the caller (verify.sh)
operator_control_verify_check() {
  local release="${1:-false}" env_v="${RATHSTED_OPERATOR_CONTROL:-}" rec stamped exp why sync
  if ! validate_rathsted_operator_control 2>/dev/null; then
    R3_VERIFY_MSG="RATHSTED_OPERATOR_CONTROL='${env_v}' is not one of: customer, domestic-provider, foreign-provider, rathsted"
    return 2
  fi
  if ! rec="$(recorded_operator_control)"; then
    R3_VERIFY_MSG="Cannot read ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}, so cannot tell whether an operator-control was declared"
    return 2
  fi
  if ! stamped="$(stamped_operator_control 2>/dev/null)"; then
    R3_VERIFY_MSG="Cannot read a valid rathsted.io/operator-control from the live require-namespace-labels policy"
    return 2
  fi
  if [[ -n "$env_v" && -n "$rec" && "$env_v" != "$rec" ]]; then
    R3_VERIFY_MSG="RATHSTED_OPERATOR_CONTROL=${env_v}, but the install recorded r3_operator_control=${rec} in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}"
    return 2
  fi
  exp="${env_v:-$rec}"
  if [[ -z "$exp" ]]; then
    R3_VERIFY_MSG="rathsted.io/operator-control is stamped ${stamped}, but no operator declared it (no r3_operator_control in ${R3_CONTRACT_NS}/${R3_CONTRACT_NAME}); declare it with RATHSTED_OPERATOR_CONTROL at install$([[ "$release" == "true" ]] && echo '; a warning under --release too')"
    return 1
  fi
  if [[ -n "$env_v" ]]; then why="RATHSTED_OPERATOR_CONTROL=${env_v}"; else why="the install recorded r3_operator_control=${rec}"; fi
  if [[ "$stamped" != "$exp" ]]; then
    R3_VERIFY_MSG="rathsted.io/operator-control is stamped ${stamped}, but ${why}. If the install applied ${exp}, the GitOps source (Flux, cluster/gitops/apps) restored its own literal: carry ${exp} there"
    [[ -z "$env_v" ]] && R3_VERIFY_MSG="${R3_VERIFY_MSG}. If the record is stale, remove it (docs/upgrade-guide.md): ${R3_REMOVE_OPCTL_CMD}"
    return 2
  fi
  # With GitOps configured, the stamp is only the cluster's settled value once
  # rathsted-sync has applied a revision; before that, Flux may still replace it.
  if ! sync="$(_r3_sync_state)"; then
    R3_VERIFY_MSG="Cannot read flux-system/rathsted-sync, so cannot tell whether GitOps has applied the policies"
    return 2
  fi
  if [[ -n "$sync" && "$sync" != True\|?* ]]; then
    R3_VERIFY_MSG="rathsted.io/operator-control is stamped ${stamped}, as declared (${why}), but flux-system/rathsted-sync is not Ready with an applied revision yet; re-run verify after it is"
    return 1
  fi
  R3_VERIFY_MSG="rathsted.io/operator-control is stamped ${stamped}, as declared (${why})${sync:+; rathsted-sync applied ${sync#True|}}"
  return 0
}

# Print "<Ready status>|<lastAppliedRevision>" of flux-system/rathsted-sync.
# Prints nothing and returns 0 when it does not exist (no GitOps configured,
# e.g. install-managed.sh without RATHSTED_GIT_URL) or Flux's CRD is absent.
# Any other read error returns 2.
_r3_sync_state() {
  local out err errf rc=0
  errf="$(mktemp)" || return 2
  out="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io rathsted-sync -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.lastAppliedRevision}' 2>"$errf")" || rc=$?
  err="$(cat "$errf")"
  rm -f "$errf"
  if [[ "$rc" -ne 0 ]]; then
    [[ "$err" == *NotFound* || "$err" == *"doesn't have a resource type"* ]] && return 0
    echo "[rathsted] cannot read flux-system/rathsted-sync: ${err}" >&2
    return 2
  fi
  printf '%s' "${out:-|}"
}
