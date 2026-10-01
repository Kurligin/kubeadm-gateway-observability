#!/usr/bin/env bash
# Create the Secret with the Grafana admin credentials, once.
#
#   scripts/ensure-grafana-admin.sh <namespace> <secret> <username>
#
# The password is random and exists only in the cluster (keys "admin-user"
# and "admin-password", read by Grafana through admin.existingSecret and by
# `make status`). An existing Secret is never touched, so re-deploys keep the
# same password and Grafana is not restarted.
# Called by `make platform` after every helmfile apply and by helmfile
# (presync hook of the "kube-prometheus-stack" release) before the first
# install.
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

  local password
  password="$(openssl rand -hex 16)"

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
    app.kubernetes.io/part-of: monitoring
    app.kubernetes.io/managed-by: deploy
type: Opaque
stringData:
  admin-user: "${username}"
  admin-password: "${password}"
MANIFEST
}

main "$@"
