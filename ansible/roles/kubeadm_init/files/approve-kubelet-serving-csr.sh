#!/usr/bin/env bash
# Approve pending kubelet serving certificate requests (signer
# kubernetes.io/kubelet-serving) of known nodes.
#
#   approve-kubelet-serving-csr.sh <nodes.json>
#
# <nodes.json> maps every node name to the names and IP addresses it may
# have in its certificate, as Ansible knows them from the inventory:
#   {"node1": ["node1", "192.0.2.10"], ...}
# A request is approved only if it comes from system:node:<name> of a known
# node (the API server sets that user name from the kubelet's credentials),
# its subject is CN=system:node:<name>, O=system:nodes, and every subject
# alternative name is one of that node's names or addresses (IPv6 compared
# in normalized form). Anything else is left pending and reported.
# Prints "approved <n>". Uses KUBECONFIG (default /etc/kubernetes/admin.conf).
# Run by Ansible on every deployment and by a systemd timer on the control
# plane (renewals between deployments).
set -euo pipefail

export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

# Normalized form of an IP address (python3 is always on Ubuntu); fails
# for anything that is not an IP address.
normalize_ip() {
  python3 -c 'import ipaddress, sys; print(ipaddress.ip_address(sys.argv[1]))' "$1" 2>/dev/null
}

main() {
  [[ $# -eq 1 && -r $1 ]] || {
    echo "usage: $0 <nodes.json>" >&2
    exit 2
  }
  local nodes_file=$1 approved=0 csr user node request subject text sans san valid allowed ip
  while read -r csr user; do
    node=${user#system:node:}
    if ! jq -e --arg n "${node}" 'has($n)' "${nodes_file}" >/dev/null; then
      echo "left pending: ${csr} from ${user}: not a node of the inventory" >&2
      continue
    fi
    request="$(kubectl get csr "${csr}" --output jsonpath='{.spec.request}' | base64 -d)"
    # A request openssl cannot read is never approved.
    if ! subject="$(openssl req -noout -subject -nameopt RFC2253 <<<"${request}")" ||
      ! text="$(openssl req -noout -text <<<"${request}")"; then
      echo "left pending: ${csr} from ${user}: cannot parse the request" >&2
      continue
    fi
    if [[ ${subject} != "subject=CN=system:node:${node},O=system:nodes" ]]; then
      echo "left pending: ${csr} from ${user}: unexpected subject ${subject#subject=}" >&2
      continue
    fi
    # The line after "X509v3 Subject Alternative Name:" (OpenSSL 3.0 has no
    # `req -ext`).
    sans="$(awk '/X509v3 Subject Alternative Name:/ { getline; print; exit }' <<<"${text}" | tr ',' '\n' | sed 's/^ *//')"
    if [[ -z ${sans} ]]; then
      echo "left pending: ${csr} from ${user}: no subject alternative names" >&2
      continue
    fi
    allowed=" "
    while read -r san; do
      [[ -z ${san} ]] && continue
      if ip="$(normalize_ip "${san}")"; then
        allowed+="IP:${ip} "
      else
        allowed+="DNS:${san} "
      fi
    done < <(jq -r --arg n "${node}" '.[$n][]' "${nodes_file}")
    valid=true
    while read -r san; do
      case "${san}" in
        "") ;;
        DNS:*) [[ ${allowed} == *" ${san} "* ]] || valid=false ;;
        "IP Address:"*)
          if ip="$(normalize_ip "${san#IP Address:}")"; then
            [[ ${allowed} == *" IP:${ip} "* ]] || valid=false
          else
            valid=false
          fi
          ;;
        *) valid=false ;;
      esac
    done <<<"${sans}"
    if [[ ${valid} != true ]]; then
      echo "left pending: ${csr} from ${user}: names that are not this node's: ${sans//$'\n'/, }" >&2
      continue
    fi
    kubectl certificate approve "${csr}" >/dev/null
    approved=$((approved + 1))
  done < <(kubectl get csr --output json | jq -r '.items[]
    | select(.spec.signerName == "kubernetes.io/kubelet-serving")
    | select(.spec.username | startswith("system:node:"))
    | select((.status.conditions // []) | length == 0)
    | "\(.metadata.name) \(.spec.username)"')
  echo "approved ${approved}"
}

main "$@"
