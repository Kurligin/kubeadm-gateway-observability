#!/usr/bin/env bash
# Short overview of the deployment: node and versions, Gateway address, UI
# links, Helm releases and a quick health summary. Passwords are not shown
# here (`make ui`). Called by `make status`; PUBLIC_IP: see
# scripts/hosts-hint.sh.
set -euo pipefail

readonly DOMAIN=${DOMAIN:-demo.local}
readonly GATEWAY_NAMESPACE=gateway
readonly GATEWAY_NAME=public
readonly TRACING_NAMESPACE=tracing
UI_HOSTS=(app grafana prometheus alertmanager logs)

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

section() {
  if [[ -t 1 ]]; then
    printf '\n\033[1m%s\033[0m\n' "$*"
  else
    printf '\n%s\n' "$*"
  fi
}

main() {
  command -v kubectl >/dev/null || die "kubectl not found: run 'make deploy' first"
  command -v jq >/dev/null || die "jq not found"
  kubectl get --raw /readyz >/dev/null 2>&1 || die "the API server does not answer (is the cluster deployed? 'make deploy')"

  section "Node"
  kubectl get nodes -o json | jq -r '.items[] |
    "  \(.metadata.name)  \([.status.conditions[] | select(.type == "Ready")][0].status | if . == "True" then "Ready" else "NotReady" end)  " +
    "\([.status.addresses[] | select(.type == "InternalIP")][0].address)  " +
    "Kubernetes \(.status.nodeInfo.kubeletVersion), \(.status.nodeInfo.containerRuntimeVersion), \(.status.nodeInfo.osImage)"'

  section "Gateway"
  local gw ip addresses server programmed
  gw="$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" -o json 2>/dev/null || echo '{}')"
  # With workers the Gateway has an address on every node; the control
  # plane's (the API server address) is shown first and used below.
  addresses="$(jq -r '.status.addresses[]?.value' <<<"${gw}")"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  server=${server#https://}
  server=${server%:*}
  if grep -qxF "${server}" <<<"${addresses}"; then
    ip=${server}
  else
    ip="$(head -n1 <<<"${addresses}")"
  fi
  addresses="$({ printf '%s\n' "${ip}"; grep -vxF "${ip}" <<<"${addresses}" || true; } | xargs)"
  programmed="$(jq -r '[.status.conditions[]? | select(.type == "Programmed")][0].status // "unknown"' <<<"${gw}")"
  printf '  %s/%s  address %s  Programmed=%s\n' "${GATEWAY_NAMESPACE}" "${GATEWAY_NAME}" "${addresses:-none}" "${programmed}"

  section "Tracing"
  # What is deployed now, and what the next deploy would do with the
  # current environment (TRACING=auto|true|false).
  local deployed next
  deployed=off
  if kubectl get namespace "${TRACING_NAMESPACE}" >/dev/null 2>&1; then
    deployed=on
    UI_HOSTS+=(traces)
  fi
  next="$("$(dirname "${BASH_SOURCE[0]}")/tracing-mode.sh" --explain 2>&1 || true)"
  printf '  deployed: %s; next deploy: %s\n' "${deployed}" "${next}"

  section "Addresses (HTTPS, certificate of the demo CA)"
  local host
  for host in "${UI_HOSTS[@]}"; do
    case ${host} in
      app) printf '  %-13s https://%s.%s/\n' "application" "${host}" "${DOMAIN}" ;;
      logs) printf '  %-13s https://%s.%s/select/vmui/\n' "logs (vmui)" "${host}" "${DOMAIN}" ;;
      traces) printf '  %-13s https://%s.%s/select/vmui/\n' "traces (UI)" "${host}" "${DOMAIN}" ;;
      *) printf '  %-13s https://%s.%s/\n' "${host}" "${host}" "${DOMAIN}" ;;
    esac
  done
  printf '\n'
  "$(dirname "${BASH_SOURCE[0]}")/hosts-hint.sh" "${ip}" "${UI_HOSTS[@]/%/.${DOMAIN}}"
  printf '  CA certificate for curl --cacert / the browser: make ca (writes ca.crt)\n'
  printf '  Passwords (Grafana, basic auth of Prometheus/Alertmanager/logs/traces): make ui\n'

  section "Helm releases"
  if command -v helm >/dev/null; then
    helm list --all-namespaces --all --output json | jq -r '
      (map(select(.status == "deployed")) | length) as $ok |
      "  \($ok)/\(length) deployed",
      (.[] | select(.status != "deployed") | "  NOT deployed: \(.namespace)/\(.name) \(.status)")'
    helm list --all-namespaces --output json | jq -r '.[] | "    \(.namespace)/\(.name)  \(.chart)  rev \(.revision)"'
  else
    printf '  helm not installed\n'
  fi

  section "Health"
  kubectl get pods --all-namespaces -o json | jq -r '
    [.items[] | select(.status.phase != "Succeeded")] as $pods |
    [$pods[] | select(.status.phase == "Running" and
        ([.status.containerStatuses[]? | select(.ready != true)] | length) == 0)] as $ready |
    "  pods ready: \($ready | length)/\($pods | length)",
    ($pods[] | select(.status.phase != "Running" or
        ([.status.containerStatuses[]? | select(.ready != true)] | length) > 0) |
      "  not ready: \(.metadata.namespace)/\(.metadata.name) (\(.status.phase))")'
  kubectl get certificates --all-namespaces -o json | jq -r '
    [.items[] | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)] as $ok |
    "  certificates ready: \($ok | length)/\(.items | length)"'
  printf '\n  Full end-to-end check: make verify\n'
}

main "$@"
