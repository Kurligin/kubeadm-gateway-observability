#!/usr/bin/env bash
# Check that a repeated deployment changed nothing.
#
#   scripts/check-idempotency.sh snapshot <file>            save the Helm release revisions
#   scripts/check-idempotency.sh check <deploy log> <file>  compare after a repeated deploy
#
# `check` takes the full output of the repeated `./deploy.sh` (or `make
# deploy`) and fails unless:
#   - every host in the Ansible PLAY RECAP has changed=0 and failed=0;
#   - helmfile upgraded no release (no "UPDATED RELEASES" in its output) and
#     did not have to retry;
#   - no Helm release got a new revision since `snapshot` (helm list -A).
# Used by the e2e workflow (.github/workflows/e2e.yml); works on any node.
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  failed=1
}
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

revisions() {
  helm list --all-namespaces --all --output json |
    jq --sort-keys 'map({key: "\(.namespace)/\(.name)", value: (.revision | tostring)}) | from_entries'
}

check_ansible() {
  local recap
  # Without colour codes; host lines follow the "PLAY RECAP" header.
  recap="$(sed -E 's/\x1b\[[0-9;]*m//g' "$1" | sed -n '/^PLAY RECAP/,/^$/p' | grep -E 'changed=[0-9]+' || true)"
  if [[ -z ${recap} ]]; then
    fail "Ansible: no PLAY RECAP in $1"
    return
  fi
  printf '%s\n' "${recap}" | sed 's/^/    /'
  if grep -Eqv 'changed=0 .*failed=0 ' <<<"${recap}"; then
    fail "Ansible: a host reports changed or failed tasks"
  else
    ok "Ansible: changed=0, failed=0 on every host"
  fi
}

check_helmfile() {
  local clean
  clean="$(sed -E 's/\x1b\[[0-9;]*m//g' "$1")"
  if grep -q '^UPDATED RELEASES' <<<"${clean}"; then
    fail "helmfile: releases were upgraded"
    sed -n '/^UPDATED RELEASES/,/^$/p' <<<"${clean}" | sed 's/^/    /'
  elif grep -q 'helmfile failed; retrying' <<<"${clean}"; then
    fail "helmfile: had to retry (see $1)"
  else
    ok "helmfile: no release upgraded"
  fi
}

check_revisions() {
  local before=$1 after changes
  after="$(revisions)"
  changes="$(jq --null-input --argjson a "$(<"${before}")" --argjson b "${after}" -r '
    ($a | keys) + ($b | keys) | unique[] as $k
    | select($a[$k] != $b[$k])
    | "\($k): revision \($a[$k] // "none") -> \($b[$k] // "none")"')"
  if [[ -n ${changes} ]]; then
    fail "Helm: revisions changed"
    printf '%s\n' "${changes}" | sed 's/^/    /'
  else
    ok "Helm: $(jq length <<<"${after}") releases, revisions unchanged"
  fi
}

main() {
  case ${1:-} in
    snapshot)
      [[ $# -eq 2 ]] || die "usage: $0 snapshot <file>"
      revisions >"$2"
      log "Saved the revisions of $(jq length "$2") Helm releases to $2"
      ;;
    check)
      [[ $# -eq 3 ]] || die "usage: $0 check <deploy log> <file>"
      [[ -r $2 ]] || die "deploy log not found: $2"
      [[ -r $3 ]] || die "revision snapshot not found: $3"
      failed=0
      log "Idempotency of the repeated deployment"
      check_ansible "$2"
      check_helmfile "$2"
      check_revisions "$3"
      if [[ ${failed} -ne 0 ]]; then
        printf 'RESULT: the repeated deployment changed something\n'
        exit 1
      fi
      printf 'RESULT: OK, the repeated deployment changed nothing\n'
      ;;
    *) die "usage: $0 snapshot <file> | check <deploy log> <file>" ;;
  esac
}

main "$@"
