#!/usr/bin/env bash
# Collect what is needed to understand a failed deployment into a directory.
#
#   scripts/collect-diagnostics.sh <dir>
#
# Nodes, pods, events, Helm releases, Gateway API objects, `describe` and
# logs of every pod that is not Running and Ready, the tail of the kubelet
# and containerd journals, disk and memory. Never fails: whatever cannot be
# collected is noted in the output file. Used by the e2e workflow on
# failure; works on any node (asks for sudo for the journals).
set -uo pipefail

readonly JOURNAL_LINES=400
readonly LOG_LINES=300

collect() {
  local file=$1
  shift
  {
    printf '$ %s\n' "$*"
    "$@" 2>&1 || printf '(exit code %d)\n' "$?"
  } >"${dir}/${file}"
}

as_root() {
  if [[ ${EUID} -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
}

not_ready_pods() {
  kubectl get pods --all-namespaces --output json 2>/dev/null | jq -r '.items[]
    | select(.status.phase != "Succeeded")
    | select(.status.phase != "Running"
        or ([.status.containerStatuses[]? | .ready] | all | not))
    | "\(.metadata.namespace) \(.metadata.name)"'
}

main() {
  [[ $# -eq 1 ]] || {
    echo "usage: $0 <dir>" >&2
    exit 2
  }
  dir=$1
  mkdir -p "${dir}/pods"

  collect system.txt bash -c 'uname -a; echo; df -h; echo; free -m; echo; uptime'
  collect nodes.txt kubectl get nodes --output wide
  collect nodes-describe.txt kubectl describe nodes
  collect pods.txt kubectl get pods --all-namespaces --output wide
  collect events.txt kubectl get events --all-namespaces --sort-by=.lastTimestamp
  collect helm-releases.txt helm list --all-namespaces --all
  collect gateway-api.txt kubectl get gatewayclasses,gateways,httproutes,referencegrants --all-namespaces --output wide
  collect pvc.txt kubectl get pvc,pv --all-namespaces
  collect csr.txt kubectl get csr
  collect containers.txt as_root crictl ps --all
  collect kubelet-journal.txt as_root journalctl --unit kubelet --no-pager --lines "${JOURNAL_LINES}"
  collect containerd-journal.txt as_root journalctl --unit containerd --no-pager --lines "${JOURNAL_LINES}"
  collect approver-journal.txt as_root journalctl --unit 'kubeadm-gateway-kubelet-cert-approver*' --no-pager --lines 100

  local ns pod count=0
  while read -r ns pod; do
    [[ -n ${pod} ]] || continue
    collect "pods/${ns}_${pod}.describe.txt" kubectl --namespace "${ns}" describe pod "${pod}"
    collect "pods/${ns}_${pod}.log.txt" kubectl --namespace "${ns}" logs "${pod}" \
      --all-containers --prefix --tail "${LOG_LINES}"
    collect "pods/${ns}_${pod}.previous.log.txt" kubectl --namespace "${ns}" logs "${pod}" \
      --all-containers --prefix --previous --tail "${LOG_LINES}"
    count=$((count + 1))
  done < <(not_ready_pods)
  printf 'Diagnostics written to %s (%d pods not Running and Ready)\n' "${dir}" "${count}"
}

main "$@"
