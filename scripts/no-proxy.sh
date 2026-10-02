#!/usr/bin/env bash
# Print the NO_PROXY list to use when an HTTP(S) proxy is configured.
#
#   scripts/no-proxy.sh <pod CIDR> <service CIDR> <domain>
#
# Starts from NO_PROXY / no_proxy of the environment and adds everything
# that must never go through the proxy: localhost, every IPv4 address of
# this machine, the API server of the current kubeconfig, the pod and
# service networks, in-cluster names (.svc, .cluster.local) and the demo
# domain. Entries are comma-separated and not repeated. Called by the
# Makefile only when HTTP_PROXY or HTTPS_PROXY is set.
set -euo pipefail

main() {
  [[ $# -eq 3 ]] || {
    echo "usage: $0 <pod CIDR> <service CIDR> <domain>" >&2
    exit 2
  }
  local pod_cidr=$1 service_cidr=$2 domain=$3
  local entries=() api_server
  IFS=',' read -r -a entries <<<"${NO_PROXY:-${no_proxy:-}}"
  entries+=(localhost 127.0.0.1 ::1)
  # IPv4 addresses only: the cluster is IPv4-only.
  local addr
  for addr in $(hostname -I 2>/dev/null || true); do
    [[ ${addr} == *:* ]] || entries+=("${addr}")
  done
  api_server="$(kubectl config view --minify --output 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)"
  api_server=${api_server#https://}
  entries+=("${api_server%:*}")
  entries+=("${pod_cidr}" "${service_cidr}" .svc .cluster.local "${domain}" ".${domain}")

  local seen=" " entry result=()
  for entry in "${entries[@]}"; do
    entry="${entry// /}"
    [[ -z ${entry} || ${seen} == *" ${entry} "* ]] && continue
    seen+="${entry} "
    result+=("${entry}")
  done
  (
    IFS=','
    printf '%s\n' "${result[*]}"
  )
}

main "$@"
