#!/usr/bin/env bash
# Create the htpasswd Secret used by Envoy Gateway basic auth, once.
#
#   scripts/ensure-basic-auth.sh <namespace> <secret> <username>
#
# The password is random and exists only in the cluster (keys "username",
# "password" for `make status`, ".htpasswd" for the SecurityPolicy). An
# existing Secret is never touched, so re-deploys keep the same password.
# Called by `make platform` after every helmfile apply and by helmfile
# (presync hook of the "gateway" release) before the first install.
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
    log "Secret ${namespace}/${secret} is in place, password unchanged"
    return
  fi

  local password hash
  password="$(openssl rand -hex 16)"
  # Envoy supports only the {SHA} htpasswd scheme: base64(sha1(password)).
  hash="$(printf '%s' "${password}" | openssl dgst -binary -sha1 | openssl base64 -A)"

  log "Creating Secret ${namespace}/${secret} (user ${username}, random password)"
  # The manifest goes through stdin, so the password never appears in the
  # argument list of a process. `create` rather than `apply`: apply would
  # also store the password in the last-applied-configuration annotation.
  kubectl create -f - >/dev/null <<MANIFEST
apiVersion: v1
kind: Secret
metadata:
  name: "${secret}"
  namespace: "${namespace}"
  labels:
    app.kubernetes.io/part-of: gateway
    app.kubernetes.io/managed-by: deploy
type: Opaque
stringData:
  username: "${username}"
  password: "${password}"
  .htpasswd: "${username}:{SHA}${hash}"
MANIFEST
}

main "$@"
