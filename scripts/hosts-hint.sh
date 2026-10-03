#!/usr/bin/env bash
# Prints how to reach the Gateway by name from the machine the checks run
# on: the /etc/hosts line and the curl --resolve option. Used by
# `make status` and `make ui`.
#
#   scripts/hosts-hint.sh <Gateway address> <host name>...
#
# PUBLIC_IP (optional) is the address the node is reached at from outside
# when it sits behind NAT (a cloud VM: the node only knows its private
# address, and the Gateway reports that one). Given, the lines use it.
# Without it a private node address (RFC 1918 or CGNAT) gets a note: it
# works from the same network only. No outside service is asked for the
# public address.
set -euo pipefail

# private_ipv4 <address>: 0 for 10/8, 172.16/12, 192.168/16, 100.64/10.
private_ipv4() {
  local a b
  IFS=. read -r a b _ _ <<<"$1"
  [[ ${a} =~ ^[0-9]+$ && ${b} =~ ^[0-9]+$ ]] || return 1
  ((a == 10)) && return 0
  ((a == 172 && b >= 16 && b <= 31)) && return 0
  ((a == 192 && b == 168)) && return 0
  ((a == 100 && b >= 64 && b <= 127)) && return 0
  return 1
}

main() {
  [[ $# -ge 2 ]] || {
    printf 'usage: %s <Gateway address> <host name>...\n' "$0" >&2
    exit 2
  }
  local node_ip=${1:-} address public=${PUBLIC_IP:-}
  shift
  address=${public:-${node_ip:-<node IP>}}

  printf '  No DNS needed: add to /etc/hosts of the machine you check from\n'
  printf '    %s %s\n' "${address}" "$*"
  printf '  or use curl --resolve %s:443:%s\n' "$1" "${address}"
  if [[ -n ${public} ]]; then
    printf '  %s is PUBLIC_IP, the address of the node from outside (NAT); the node itself has %s.\n' \
      "${public}" "${node_ip:-no address yet}"
    printf '  The cloud firewall (security group) must allow TCP 80 and 443 to it.\n'
  elif [[ -n ${node_ip} ]] && private_ipv4 "${node_ip}"; then
    printf '  %s is a private address: it works from the same network. A node behind NAT\n' "${node_ip}"
    printf '  (a cloud VM) is reached at its public address instead; to print these lines\n'
    printf '  with it: PUBLIC_IP=<public address> make status (or make ui).\n'
  fi
}

main "$@"
