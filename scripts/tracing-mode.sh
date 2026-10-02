#!/usr/bin/env bash
# Decides whether distributed tracing (VictoriaTraces + Envoy spans) is
# deployed, from the TRACING environment variable:
#
#   TRACING=true    always
#   TRACING=false   never (everything tracing-related is removed)
#   TRACING=auto    (default) on if the control plane node has at least
#                   TRACING_AUTO_MIN_MEMORY_MIB of memory (versions.env)
#
#   scripts/tracing-mode.sh             prints "true" or "false"
#   scripts/tracing-mode.sh --explain   prints the decision and its reason
#
# Without a cluster in the current kubeconfig (offline rendering: `make
# lint`, `make images-list`) "auto" means "true", so that the tracing
# manifests are rendered and checked too. If the cluster is configured but
# its nodes cannot be read, the script fails rather than guess: a guess
# could remove tracing from a cluster that has it. Called by
# helmfile.yaml.gotmpl and `make platform`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR

die() {
  printf 'tracing-mode: %s\n' "$*" >&2
  exit 1
}

# memory_mib <quantity>: a Kubernetes memory quantity (as in node
# status.capacity) in MiB, rounded down.
memory_mib() {
  local q=$1
  case ${q} in
    *Ki) echo $((${q%Ki} / 1024)) ;;
    *Mi) echo "${q%Mi}" ;;
    *Gi) echo $((${q%Gi} * 1024)) ;;
    *[0-9]) echo $((q / 1048576)) ;;
    *) die "unsupported memory quantity '${q}'" ;;
  esac
}

main() {
  local explain=false
  [[ ${1:-} != "--explain" ]] || explain=true

  local mode=${TRACING:-auto} enabled reason
  mode=${mode,,}
  case ${mode} in
    true | on | 1)
      enabled=true
      reason="TRACING=${TRACING}"
      ;;
    false | off | 0)
      enabled=false
      reason="TRACING=${TRACING}"
      ;;
    auto)
      local min server quantity mib
      min="$(sed -n 's/^TRACING_AUTO_MIN_MEMORY_MIB=//p' "${REPO_DIR}/versions.env")"
      [[ ${min} =~ ^[0-9]+$ ]] || die "TRACING_AUTO_MIN_MEMORY_MIB missing in versions.env"
      server="$(kubectl config view --minify --output 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)"
      if [[ -z ${server} ]]; then
        enabled=true
        reason="TRACING=auto, no cluster configured (offline rendering)"
      else
        quantity="$(kubectl get nodes --selector node-role.kubernetes.io/control-plane \
          --output 'jsonpath={.items[0].status.capacity.memory}' 2>/dev/null)" ||
          die "cannot read the control plane node (TRACING=auto); set TRACING=true or TRACING=false"
        [[ -n ${quantity} ]] || die "no control plane node found (TRACING=auto); set TRACING=true or TRACING=false"
        mib="$(memory_mib "${quantity}")"
        if [[ ${mib} -ge ${min} ]]; then
          enabled=true
          reason="TRACING=auto, control plane memory ${mib} MiB >= ${min} MiB"
        else
          enabled=false
          reason="TRACING=auto, control plane memory ${mib} MiB < ${min} MiB; TRACING=true forces it on"
        fi
      fi
      ;;
    *) die "TRACING must be auto, true or false (got '${TRACING}')" ;;
  esac

  if [[ ${explain} == true ]]; then
    printf '%s (%s)\n' "$([[ ${enabled} == true ]] && echo on || echo off)" "${reason}"
  else
    echo "${enabled}"
  fi
}

main "$@"
