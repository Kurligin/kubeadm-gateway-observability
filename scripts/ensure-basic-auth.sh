#!/usr/bin/env bash
# Create the htpasswd Secret used by Envoy Gateway basic auth, once.
#
#   scripts/ensure-basic-auth.sh <namespace> <secret> <username>
#
# The password is random and exists only in the cluster (keys "username",
# "password" for `make status`, ".htpasswd" for the SecurityPolicy). An
# existing Secret is never touched, so re-deploys keep the same password.
# Called by helmfile (presync hook of the "gateway" release).
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

main() {
  [[ $# -eq 3 ]] || die "usage: $0 <namespace> <secret> <username>"
  local namespace=$1 secret=$2 username=$3

  if kubectl -n "${namespace}" get secret "${secret}" >/dev/null 2>&1; then
    log "Secret ${namespace}/${secret} already exists, keeping it"
    return
  fi

  local password hash
  password="$(openssl rand -hex 16)"
  # Envoy supports only the {SHA} htpasswd scheme: base64(sha1(password)).
  hash="$(printf '%s' "${password}" | openssl dgst -binary -sha1 | openssl base64 -A)"

  log "Creating Secret ${namespace}/${secret} (user ${username}, random password)"
  kubectl -n "${namespace}" create secret generic "${secret}" \
    --from-literal=username="${username}" \
    --from-literal=password="${password}" \
    --from-literal=.htpasswd="${username}:{SHA}${hash}" >/dev/null
  kubectl -n "${namespace}" label secret "${secret}" \
    app.kubernetes.io/part-of=gateway app.kubernetes.io/managed-by=deploy >/dev/null
}

main "$@"
