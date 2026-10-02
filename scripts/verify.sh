#!/usr/bin/env bash
# End-to-end check of the deployed solution: one line per check (✓ passed,
# ✗ failed with the reason, - skipped with the reason) and a summary; the
# exit code is non-zero if any check failed. Called by `make verify`.
#
# On the node (kubectl configured) nothing needs to be set: the Gateway
# address, the demo CA and the UI password are read from the cluster.
# From another machine (no kubectl), pass them in the environment:
#
#   GATEWAY_IP=192.0.2.10 CA_FILE=ca.crt UI_PASSWORD=<password> scripts/verify.sh
#
# (ca.crt: `make ca` on the node; password: `make ui` on the node.) The
# cluster-level checks that need kubectl are then skipped.
#
# Variables:
#   GATEWAY_IP   Gateway address (default: Gateway status)
#   CA_FILE      demo root CA, PEM (default: Secret cert-manager/demo-ca-keypair)
#   UI_USER      basic auth user of the UI routes (default: admin)
#   UI_PASSWORD  basic auth password (default: Secret gateway/ui-basic-auth)
#   DOMAIN       demo domain (default: demo.local)
#   WAIT         seconds to wait for things that settle after a fresh
#                deploy: pods, Prometheus targets (default: 300)
#   ENVOY_REPLICAS  Envoy replicas of the Gateway (default: from the
#                cluster, else 2), for the rate limit check
#   GRAFANA_USER, GRAFANA_PASSWORD  Grafana login for the tracing check
#                (default: Secret monitoring/grafana-admin)
#
# With worker nodes (`make add-worker`), step 9 checks every node; on a
# single node it is skipped. Step 10 (tracing) is skipped when tracing is
# off (TRACING=false, or TRACING=auto on a control plane with little
# memory, see scripts/tracing-mode.sh).
#
# Every request goes straight to the Gateway, never through an HTTP proxy
# that may be set in the environment.
#
# Requires curl and jq. Safe to run repeatedly, also within the same minute
# (see the rate limit check).
set -euo pipefail

readonly DOMAIN=${DOMAIN:-demo.local}
readonly UI_USER=${UI_USER:-admin}
readonly WAIT=${WAIT:-300}
readonly GATEWAY_NAMESPACE=gateway
readonly GATEWAY_NAME=public
readonly CA_NAMESPACE=cert-manager
readonly CA_SECRET=demo-ca-keypair
readonly BASIC_AUTH_SECRET=ui-basic-auth
# Canary: requests sent and the accepted share of v2 (weight 10 %).
readonly CANARY_REQUESTS=200
readonly CANARY_MIN_PCT=5
readonly CANARY_MAX_PCT=20
# Rate limit of /limited (charts/gateway values: 10 per minute). The token
# bucket is local to each Envoy replica, so the Gateway as a whole lets
# through up to 10 x <replicas> per minute.
readonly LIMIT_PER_MINUTE=10
# Envoy replicas of the Gateway (default: from the cluster, else 2).
ENVOY_REPLICAS=${ENVOY_REPLICAS:-}
# Response header set by every application route rule (its value is the
# rule name) and a backend header the gateway removes from responses.
readonly ROUTE_HEADER=x-gateway-route
readonly HIDDEN_HEADER=x-backend-pod
# Log search: how long a request may take to appear in VictoriaLogs.
readonly LOG_TIMEOUT=45
# Alert delivery: Alertmanager re-sends the always-firing Watchdog alert to
# the webhook receiver every ~5 min (4 min repeat interval + 1 min group
# interval), so the last ALERT_WINDOW minutes always hold a record. On a
# fresh cluster the first one takes a minute or two after Prometheus starts.
readonly ALERT_WINDOW=10m
readonly ALERT_TIMEOUT=240
# Prometheus jobs that must be up (every target of each); victoria-traces
# is added when tracing is on.
KEY_JOBS=(apiserver kubelet kube-controller-manager kube-scheduler etcd-metrics
  coredns node-exporter kube-state-metrics cilium-agent envoy envoy-gateway
  web-v1 web-v2 fluentd victoria-logs)
# Tracing: namespace and Deployment of VictoriaTraces, how long a trace may
# take to become searchable (Envoy flushes spans every 5 s, VictoriaTraces
# hides the newest 10 s), service.name of the Gateway's spans and the
# Grafana datasources that link logs and traces.
readonly TRACING_NAMESPACE=tracing
readonly TRACING_DEPLOYMENT=victoria-traces
readonly TRACE_TIMEOUT=60
readonly TRACE_SERVICE=envoy-gateway
readonly TRACES_DATASOURCE=traces
readonly LOGS_DATASOURCE=victorialogs
readonly GRAFANA_ADMIN_SECRET=grafana-admin
# Envoy clusters of the application route (not app-limited).
readonly APP_CLUSTERS="httproute/${GATEWAY_NAMESPACE}/app/rule/[0-9]+"

passed=0
failed=0
skipped=0
reason=""
tmp_dir=""

if [[ -t 1 ]]; then
  readonly OK=$'\033[32m✓\033[0m' FAIL=$'\033[31m✗\033[0m' SKIP=$'\033[33m-\033[0m'
else
  readonly OK="✓" FAIL="✗" SKIP="-"
fi

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

# result <step> <title> <status: ok|fail|skip> <details>
result() {
  local step=$1 title=$2 status=$3 details=$4 mark
  case ${status} in
    ok)
      mark=${OK}
      passed=$((passed + 1))
      ;;
    fail)
      mark=${FAIL}
      failed=$((failed + 1))
      ;;
    *)
      mark=${SKIP}
      skipped=$((skipped + 1))
      ;;
  esac
  printf ' %s  %-3s %-44s %s\n' "${mark}" "${step}" "${title}" "${details}"
}

# check <step> <title> <function> [timeout seconds]: the function sets
# $reason and returns 0 (passed) or 1 (failed); with a timeout it is retried
# every 5 s until it passes or the time is up. Return code 2 means "skipped".
check() {
  local step=$1 title=$2 fn=$3 timeout=${4:-0} rc deadline
  deadline=$((SECONDS + timeout))
  while true; do
    reason=""
    rc=0
    "${fn}" || rc=$?
    if [[ ${rc} -ne 1 || ${SECONDS} -ge ${deadline} ]]; then
      break
    fi
    sleep 5
  done
  case ${rc} in
    0) result "${step}" "${title}" ok "${reason}" ;;
    2) result "${step}" "${title}" skip "${reason}" ;;
    *) result "${step}" "${title}" fail "${reason:-failed}" ;;
  esac
}

# kubectl is used only if it reaches this cluster: with GATEWAY_IP given,
# the API server of the current context must have the same address (the
# kubeadm API server listens on the node IP, which is also the Gateway
# address), so a kubectl configured for some other cluster is ignored.
kubectl_ok=""
have_kubectl() {
  if [[ -z ${kubectl_ok} ]]; then
    kubectl_ok=false
    if command -v kubectl >/dev/null 2>&1 && kubectl get --raw /readyz >/dev/null 2>&1; then
      local server
      server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
      server=${server#https://}
      server=${server%:*}
      if [[ -z ${GATEWAY_IP:-} || ${server} == "${GATEWAY_IP}" ]]; then
        kubectl_ok=true
      fi
    fi
  fi
  [[ ${kubectl_ok} == true ]]
}

# --- HTTP helpers -----------------------------------------------------------

# https <host> <curl args...>: request to https://<host>.<domain> through
# the Gateway, certificate checked against the demo CA.
https() {
  local host=$1
  shift
  curl -sS --noproxy '*' --max-time 15 --cacert "${CA_FILE}" \
    --resolve "${host}.${DOMAIN}:443:${GATEWAY_IP}" "$@"
}

# ui_get <host> <path> <curl args...>: GET with basic auth.
ui_get() {
  local host=$1 path=$2
  shift 2
  https "${host}" -u "${UI_USER}:${UI_PASSWORD}" -G "$@" "https://${host}.${DOMAIN}${path}"
}

# promql <query>: prints the JSON result vector.
promql() {
  ui_get prometheus /api/v1/query --data-urlencode "query=$1" | jq -ce '.data.result'
}

# promql_value <query>: first sample value of a scalar-like query, or "".
promql_value() {
  promql "$1" 2>/dev/null | jq -r '.[0].value[1] // empty' 2>/dev/null || true
}

# --- 1. Cluster ---------------------------------------------------------------

check_node() {
  have_kubectl || {
    reason="no kubectl access to this cluster"
    return 2
  }
  local nodes not_ready
  nodes="$(kubectl get nodes -o json)" || {
    reason="kubectl get nodes failed"
    return 1
  }
  not_ready="$(jq -r '.items[] | select(([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length) == 0) | .metadata.name' <<<"${nodes}")"
  if [[ -n ${not_ready} ]]; then
    reason="not Ready: ${not_ready//$'\n'/, }"
    return 1
  fi
  reason="$(jq -r '[.items[] | "\(.metadata.name) \(.status.nodeInfo.kubeletVersion)"] | join(", ")' <<<"${nodes}")"
}

check_pods() {
  have_kubectl || {
    reason="no kubectl access to this cluster"
    return 2
  }
  local pods total bad
  pods="$(kubectl get pods --all-namespaces -o json)" || {
    reason="kubectl get pods failed"
    return 1
  }
  # Finished Job pods (Succeeded) are fine; everything else must be Running
  # with every container ready. Restarts alone are not a failure.
  total="$(jq '[.items[] | select(.status.phase != "Succeeded")] | length' <<<"${pods}")"
  bad="$(jq -r '.items[]
    | select(.status.phase != "Succeeded")
    | select(.status.phase != "Running"
        or ([.status.containerStatuses[]? | select(.ready != true)] | length) > 0)
    | "\(.metadata.namespace)/\(.metadata.name) (\(.status.phase))"' <<<"${pods}")"
  if [[ -n ${bad} ]]; then
    reason="not ready: ${bad//$'\n'/, }"
    return 1
  fi
  reason="${total}/${total} pods Running and Ready"
}

check_releases() {
  have_kubectl || {
    reason="no kubectl access to this cluster"
    return 2
  }
  command -v helm >/dev/null 2>&1 || {
    reason="helm not installed here"
    return 2
  }
  local releases total bad
  releases="$(helm list --all-namespaces --all --output json)" || {
    reason="helm list failed"
    return 1
  }
  total="$(jq 'length' <<<"${releases}")"
  bad="$(jq -r '.[] | select(.status != "deployed") | "\(.namespace)/\(.name): \(.status)"' <<<"${releases}")"
  if [[ -n ${bad} ]]; then
    reason="${bad//$'\n'/, }"
    return 1
  fi
  if [[ ${total} -eq 0 ]]; then
    reason="no Helm releases found"
    return 1
  fi
  reason="${total}/${total} releases deployed"
}

# --- 2. Gateway ---------------------------------------------------------------

check_gateway() {
  have_kubectl || {
    reason="no kubectl access to this cluster"
    return 2
  }
  local gw programmed address node_ips
  gw="$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" -o json 2>/dev/null)" || {
    reason="Gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME} not found"
    return 1
  }
  programmed="$(jq -r '.status.conditions[]? | select(.type == "Programmed") | .status' <<<"${gw}")"
  address="$(jq -r '.status.addresses[0].value // empty' <<<"${gw}")"
  node_ips="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')"
  if [[ ${programmed} != "True" ]]; then
    reason="Programmed=${programmed:-unknown}"
    return 1
  fi
  if ! grep -qxF "${address}" <<<"${node_ips}"; then
    reason="address ${address:-none} is not a node IP (${node_ips//$'\n'/, })"
    return 1
  fi
  reason="Programmed=True, address ${address} = node IP"
}

# Every HTTPRoute of the Gateway is Accepted with all references resolved
# (filters such as RequestMirror and the timeouts included), for each of
# its parents (listeners) separately.
check_routes() {
  have_kubectl || {
    reason="no kubectl access to this cluster"
    return 2
  }
  local routes total bad
  routes="$(kubectl -n "${GATEWAY_NAMESPACE}" get httproutes -o json 2>/dev/null)" || {
    reason="kubectl get httproutes failed"
    return 1
  }
  total="$(jq '.items | length' <<<"${routes}")"
  bad="$(jq -r '.items[] | .metadata.name as $n
    | [.status.parents[]? | ([.conditions[]? | select((.type == "Accepted" or .type == "ResolvedRefs") and .status == "True")] | length)] as $ok
    | select(($ok | length) == 0 or ($ok | any(. < 2))) | $n' <<<"${routes}" | xargs)"
  if [[ ${total} -eq 0 ]]; then
    reason="no HTTPRoutes in ${GATEWAY_NAMESPACE}"
    return 1
  fi
  if [[ -n ${bad} ]]; then
    reason="not Accepted/ResolvedRefs: ${bad}"
    return 1
  fi
  reason="${total}/${total} HTTPRoutes Accepted, ResolvedRefs=True"
}

# --- 3. HTTP and HTTPS --------------------------------------------------------

check_http_redirect() {
  local out code location
  out="$(curl -sS --noproxy '*' --max-time 15 -o /dev/null -w '%{http_code} %{redirect_url}' \
    -H "Host: app.${DOMAIN}" "http://${GATEWAY_IP}/" 2>&1)" || {
    reason="request failed: ${out}"
    return 1
  }
  code=${out%% *}
  location=${out#* }
  if [[ ${code} != "301" || ${location} != "https://app.${DOMAIN}/" ]]; then
    reason="got ${code} -> ${location:-no Location}, want 301 -> https://app.${DOMAIN}/"
    return 1
  fi
  reason="301 -> ${location}"
}

check_https_app() {
  local body code
  body="$(https app -w '\n%{http_code}' "https://app.${DOMAIN}/" 2>&1)" || {
    reason="request failed: ${body}"
    return 1
  }
  code=${body##*$'\n'}
  body=${body%$'\n'*}
  body=${body%$'\n'}
  if [[ ${code} != "200" || ${body} != *"Hello World!"* ]]; then
    reason="got ${code}: ${body:0:80}"
    return 1
  fi
  reason="200, TLS verified by the demo CA: ${body}"
}

# --- 4. Canary and routing ----------------------------------------------------

check_canary() {
  local config total v2 pct attempt
  config="${tmp_dir}/canary.curl"
  for _ in $(seq "${CANARY_REQUESTS}"); do
    printf 'url = "https://app.%s/"\n' "${DOMAIN}"
  done >"${config}"
  # Weighted random choice per request: a sample of 200 falls outside
  # 5-20 % with a probability below 1 %, so one more sample is taken
  # before calling it a failure.
  for attempt in 1 2; do
    # One connection, many requests: Envoy picks the backend per request.
    https app --config "${config}" >"${tmp_dir}/canary.out" 2>&1 || true
    total="$(grep -c 'Hello World!' "${tmp_dir}/canary.out" || true)"
    v2="$(grep -c 'version=v2' "${tmp_dir}/canary.out" || true)"
    if [[ ${total} -ne ${CANARY_REQUESTS} ]]; then
      reason="only ${total}/${CANARY_REQUESTS} requests answered"
      return 1
    fi
    pct=$((v2 * 100 / total))
    reason="v2: ${v2}/${total} = ${pct} % (expected ${CANARY_MIN_PCT}-${CANARY_MAX_PCT} %, weight 10 %)"
    if [[ ${pct} -ge ${CANARY_MIN_PCT} && ${pct} -le ${CANARY_MAX_PCT} ]]; then
      [[ ${attempt} -eq 1 ]] || reason+=", second sample"
      return 0
    fi
  done
  return 1
}

check_canary_path() {
  local body
  body="$(https app "https://app.${DOMAIN}/v2" 2>&1)" || true
  reason="/v2 -> ${body:0:60}"
  [[ ${body} == *"version=v2"* ]]
}

check_canary_header() {
  local body
  body="$(https app -H 'X-Canary: true' "https://app.${DOMAIN}/" 2>&1)" || true
  reason="X-Canary: true -> ${body:0:60}"
  [[ ${body} == *"version=v2"* ]]
}

# response_header <headers file> <name>: value of a response header, or "".
response_header() {
  awk -v name="$2" 'BEGIN { name = tolower(name) }
    { line = $0; sub(/\r$/, "", line); split(line, kv, ":") }
    tolower(kv[1]) == name { sub(/^[^:]*:[ \t]*/, "", line); print line; exit }' "$1"
}

# ResponseHeaderModifier of the route rules: every answer names the rule
# that matched, and the backend's internal header is removed.
check_response_headers() {
  local path rule want headers got hidden
  reason=""
  for path in /:weighted /v2:path-v2; do
    rule=${path#*:}
    path=${path%%:*}
    headers="${tmp_dir}/headers"
    https app -o /dev/null -D "${headers}" "https://app.${DOMAIN}${path}" 2>/dev/null || true
    got="$(response_header "${headers}" "${ROUTE_HEADER}")"
    hidden="$(response_header "${headers}" "${HIDDEN_HEADER}")"
    want=${rule}
    reason+="${reason:+, }${path} -> ${ROUTE_HEADER}: ${got:-none}"
    if [[ ${got} != "${want}" ]]; then
      reason+=" (want ${want})"
      return 1
    fi
    if [[ -n ${hidden} ]]; then
      reason+=", ${HIDDEN_HEADER} not removed (${hidden})"
      return 1
    fi
  done
  reason+=", ${HIDDEN_HEADER} removed"
}

# --- 5. Rate limit ------------------------------------------------------------

# /limited allows 10 requests per minute in each Envoy replica (local token
# bucket, refilled every minute). A burst of 10 x <replicas> + 5 requests
# is more than all replicas together can let through, so it must contain
# at least one 429 issued by the rate limiter itself (header
# x-ratelimit-limit), and at most 10 x <replicas> successes, however the
# requests are spread over the replicas. (The burst runs over one
# connection, so in practice one replica answers: 10 x 200, the rest 429.)
# Run again within the same minute, the buckets may still be empty: then
# all are 429, which is the limit working as well. The main route must not
# be affected.
check_rate_limit() {
  local config codes ok limited other main burst allowed
  allowed=$((LIMIT_PER_MINUTE * ENVOY_REPLICAS))
  burst=$((allowed + 5))
  config="${tmp_dir}/limited.curl"
  for _ in $(seq "${burst}"); do
    printf 'url = "https://app.%s/limited"\noutput = "/dev/null"\n' "${DOMAIN}"
  done >"${config}"
  codes="$(https app --config "${config}" -w '%{http_code} %header{x-ratelimit-limit}\n' 2>&1)" || true
  ok="$(grep -c '^200 ' <<<"${codes}" || true)"
  limited="$(grep -c "^429 ${LIMIT_PER_MINUTE}\$" <<<"${codes}" || true)"
  other=$((burst - ok - limited))
  main="$(https app -o /dev/null -w '%{http_code}' "https://app.${DOMAIN}/" 2>/dev/null || true)"
  reason="${burst} requests: ${ok} x 200, ${limited} x 429 (limit ${LIMIT_PER_MINUTE}/min per replica, ${ENVOY_REPLICAS} replicas)"
  if [[ ${other} -ne 0 ]]; then
    reason+=", ${other} other: $(grep -v -e '^200 ' -e "^429 ${LIMIT_PER_MINUTE}\$" <<<"${codes}" | sort | uniq -c | xargs)"
    return 1
  fi
  if [[ ${limited} -lt 1 || ${ok} -gt ${allowed} ]]; then
    return 1
  fi
  if [[ ${main} != "200" ]]; then
    reason+=", but / answered ${main}"
    return 1
  fi
  reason+=", / still 200"
}

# --- 6. Logs ------------------------------------------------------------------

request_id=""

# The traced request also carries a forged X-Gateway-Route header: the
# route's RequestHeaderModifier must overwrite it before it reaches Angie.
send_traced_request() {
  request_id="verify-$(date +%s)-${RANDOM}${RANDOM}"
  https app -o /dev/null -H "X-Request-ID: ${request_id}" -H "X-Gateway-Route: forged-by-client" \
    "https://app.${DOMAIN}/" 2>/dev/null || true
}

# logs_for_request: every log record with the traced request ID, one JSON
# object per line.
logs_for_request() {
  ui_get logs /select/logsql/query --data-urlencode "query=x_request_id:\"${request_id}\"" 2>/dev/null || true
}

# Both access logs (Angie and the Envoy proxy) must contain the request ID.
check_logs() {
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  local start containers
  start=${SECONDS}
  send_traced_request
  while true; do
    containers="$(logs_for_request | jq -r '."kubernetes.container_name" // empty' 2>/dev/null | sort -u | xargs || true)"
    if [[ " ${containers} " == *" angie "* && " ${containers} " == *" envoy "* ]]; then
      reason="X-Request-ID ${request_id} found in Angie and Envoy access logs after $((SECONDS - start)) s"
      return 0
    fi
    if [[ $((SECONDS - start)) -ge ${LOG_TIMEOUT} ]]; then
      reason="X-Request-ID ${request_id}: after ${LOG_TIMEOUT} s found in [${containers:-nothing}], want angie and envoy"
      return 1
    fi
    sleep 3
  done
}

# angie_records <jq filter>: Angie access log records of the traced request
# that match the filter, compact JSON, one per line.
angie_records() {
  logs_for_request | jq -c "select(.\"kubernetes.container_name\" == \"angie\") | select($1)" 2>/dev/null || true
}

# RequestHeaderModifier: the live request reached Angie with the rule name
# in X-Gateway-Route, not the value the client sent.
check_request_header() {
  [[ -n ${UI_PASSWORD} && -n ${request_id} ]] || {
    reason="no traced request (step 6 skipped)"
    return 2
  }
  local record got
  record="$(angie_records '.traffic != "shadow"' | head -n1)"
  got="$(printf '%s' "${record}" | jq -r '.gateway_route // empty' 2>/dev/null || true)"
  reason="client sent X-Gateway-Route: forged-by-client, Angie got: ${got:-no record}"
  [[ ${got} == "weighted" ]]
}

# RequestMirror: besides the live answer (v1 or v2), a copy of the same
# request (same X-Request-ID) reached web-v2 on its shadow port.
check_mirror() {
  [[ -n ${UI_PASSWORD} && -n ${request_id} ]] || {
    reason="no traced request (step 6 skipped)"
    return 2
  }
  local live shadow
  live="$(angie_records '.traffic != "shadow"' | jq -r '.version' | sort | xargs)"
  shadow="$(angie_records '.traffic == "shadow"' | jq -r '.version' | sort | xargs)"
  reason="X-Request-ID ${request_id}: live answer from [${live:-none}], shadow copy at [${shadow:-none}]"
  [[ ${shadow} == "v2" && -n ${live} && ${live} != *" "* ]]
}

# --- 7. Prometheus ------------------------------------------------------------

# Envoy request counter of the app route right before the test traffic
# (steps 3-6) and the SECONDS value when that traffic started.
envoy_requests_before=""
traffic_start=0

envoy_requests() {
  promql_value "sum(envoy_cluster_upstream_rq_total{envoy_cluster_name=~\"${APP_CLUSTERS}\"})"
}

# Current scrape state from the targets API, not the "up" series: right
# after a reboot, "up" still returns the last samples of the pods that were
# running before it (Prometheus restarted too and could not mark them stale).
check_targets() {
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  local targets missing=() down others job total
  targets="$(ui_get prometheus /api/v1/targets --data-urlencode 'state=active' 2>/dev/null |
    jq -ce '[.data.activeTargets[] | {job: .labels.job, instance: .labels.instance, health}]' 2>/dev/null)" || {
    reason="Prometheus API not reachable"
    return 1
  }
  for job in "${KEY_JOBS[@]}"; do
    if [[ "$(jq --arg j "${job}" '[.[] | select(.job == $j)] | length' <<<"${targets}")" -eq 0 ]]; then
      missing+=("${job}")
    fi
  done
  # Only the key jobs count; other targets are reported but do not fail.
  # jq expression (its $j and $jobs are jq variables, not shell ones).
  # shellcheck disable=SC2016
  local key_filter='(.job as $j | $jobs | index(" " + $j + " ")) != null'
  down="$(jq -r --arg jobs " ${KEY_JOBS[*]} " "[.[] | select(.health != \"up\" and (${key_filter})) | \"\\(.job) \\(.instance) (\\(.health))\"] | join(\", \")" <<<"${targets}")"
  others="$(jq -r --arg jobs " ${KEY_JOBS[*]} " "[.[] | select(.health != \"up\" and ((${key_filter}) | not)) | .job] | unique | join(\", \")" <<<"${targets}")"
  total="$(jq --arg jobs " ${KEY_JOBS[*]} " "[.[] | select(${key_filter})] | length" <<<"${targets}")"
  if [[ ${#missing[@]} -gt 0 || -n ${down} ]]; then
    reason="missing: ${missing[*]:-none}; not up: ${down:-none}"
    return 1
  fi
  reason="${#KEY_JOBS[@]} key jobs, ${total} targets, all up"
  if [[ -n ${others} ]]; then
    # Right after a deploy, a target of a pod that has just been replaced
    # can still be reported down until its next scrape: look once more.
    sleep 35
    others="$(ui_get prometheus /api/v1/targets --data-urlencode 'state=active' 2>/dev/null |
      jq -r --arg jobs " ${KEY_JOBS[*]} " "[.data.activeTargets[] | {job: .labels.job, health}
        | select(.health != \"up\" and ((${key_filter}) | not)) | .job] | unique | join(\", \")" 2>/dev/null || true)"
    [[ -z ${others} ]] || reason+="; not critical, still down after a re-check: ${others}"
  fi
}

# Steps 3-6 sent more than ${CANARY_REQUESTS} requests to the app route.
# Normally the growth is the difference to the value taken before the
# traffic (the last scrape before it). If the counter went down, Envoy has
# restarted since that value was scraped (e.g. after a reboot, the last
# pre-reboot sample is still returned): then increase() is used, which
# survives counter resets; its window reaches one scrape interval before
# the traffic, so the sample preceding it is included.
check_envoy_counter() {
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  local now before=${envoy_requests_before:-0} grown window want=$((CANARY_REQUESTS * 3 / 4))
  now="$(envoy_requests)"
  [[ -n ${now} ]] || {
    reason="envoy_cluster_upstream_rq_total (app route): no data"
    return 1
  }
  if awk -v n="${now}" -v b="${before}" 'BEGIN { exit !(n >= b) }'; then
    grown="$(awk -v n="${now}" -v b="${before}" 'BEGIN { print n - b }')"
    reason="envoy_cluster_upstream_rq_total (app route): ${before} -> ${now}"
  else
    window=$((SECONDS - traffic_start + 40))
    grown="$(promql_value "sum(increase(envoy_cluster_upstream_rq_total{envoy_cluster_name=~\"${APP_CLUSTERS}\"}[${window}s]))")"
    reason="counter reset (Envoy restarted): increase over ${window}s = ${grown:-no data}"
  fi
  awk -v g="${grown:-0}" -v w="${want}" 'BEGIN { exit !(g >= w) }' || {
    reason+=", want +${want}"
    return 1
  }
}

# Resource metrics API (metrics-server): `kubectl top` works for nodes and
# pods.
check_kubectl_top() {
  have_kubectl || {
    reason="no kubectl access to this cluster"
    return 2
  }
  local nodes pods
  nodes="$(kubectl top nodes --no-headers 2>/dev/null)" || {
    reason="kubectl top nodes failed (metrics-server not ready?)"
    return 1
  }
  pods="$(kubectl top pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')" || pods=0
  if [[ -z ${nodes} || ${pods} -eq 0 ]]; then
    reason="kubectl top: ${pods} pods"
    return 1
  fi
  reason="kubectl top nodes: $(awk '{printf "%s%s CPU %s, memory %s", (NR > 1 ? "; " : ""), $1, $2, $4}' <<<"${nodes}"); top pods: ${pods} pods"
}

# Alert delivery end to end: the Watchdog alert (always firing) went
# Prometheus -> Alertmanager -> webhook receiver -> Fluentd -> VictoriaLogs.
check_alert_delivery() {
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  local records count last
  records="$(ui_get logs /select/logsql/query \
    --data-urlencode "query=_time:${ALERT_WINDOW} kubernetes.container_name:receiver alertname:Watchdog | sort by (_time desc)" \
    --data-urlencode 'limit=20' 2>/dev/null || true)"
  count="$(jq -s 'length' <<<"${records}" 2>/dev/null || echo 0)"
  last="$(jq -rs 'first | ._time // empty' <<<"${records}" 2>/dev/null || true)"
  if [[ ${count} -eq 0 ]]; then
    reason="no Watchdog record from the alert receiver in VictoriaLogs within the last ${ALERT_WINDOW}"
    return 1
  fi
  reason="${count} Watchdog notification(s) in the receiver log within the last ${ALERT_WINDOW}, latest ${last}"
}

check_angie_metrics() {
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  local result
  result="$(promql 'sum by (version) (angie_http_server_zones_requests_total{zone="app"})' 2>/dev/null)" || {
    reason="Prometheus API not reachable"
    return 1
  }
  reason="angie_http_server_zones_requests_total{zone=\"app\"}: $(jq -r '[.[] | "\(.metric.version)=\(.value[1])"] | sort | join(", ")' <<<"${result}")"
  [[ "$(jq '[.[] | select(.metric.version == "v1" or .metric.version == "v2") | select((.value[1] | tonumber) > 0)] | length' <<<"${result}")" -eq 2 ]]
}

# --- 8. Security --------------------------------------------------------------

# expect_code <want> <description> <curl args...>
expect_code() {
  local want=$1 what=$2 code
  shift 2
  code="$(curl -sS --noproxy '*' --max-time 10 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
  reason="${what}: ${code}"
  [[ ${code} == "${want}" ]]
}

check_prometheus_auth() {
  expect_code 401 "Prometheus without password" --cacert "${CA_FILE}" \
    --resolve "prometheus.${DOMAIN}:443:${GATEWAY_IP}" "https://prometheus.${DOMAIN}/api/v1/query?query=up"
}

check_logs_auth() {
  expect_code 401 "VictoriaLogs without password" --cacert "${CA_FILE}" \
    --resolve "logs.${DOMAIN}:443:${GATEWAY_IP}" "https://logs.${DOMAIN}/select/logsql/query?query=*"
}

# Even with the password, write and lifecycle endpoints are not routed.
check_closed_endpoints() {
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  local quit insert
  quit="$(https prometheus -u "${UI_USER}:${UI_PASSWORD}" -X POST -o /dev/null -w '%{http_code}' \
    "https://prometheus.${DOMAIN}/-/quit" 2>/dev/null || true)"
  insert="$(https logs -u "${UI_USER}:${UI_PASSWORD}" -X POST -o /dev/null -w '%{http_code}' \
    --data-binary '{"_msg":"verify"}' "https://logs.${DOMAIN}/insert/jsonline" 2>/dev/null || true)"
  reason="with password: POST /-/quit -> ${quit}, POST /insert/jsonline -> ${insert}"
  [[ ${quit} == "404" && ${insert} == "404" ]]
}

# curl exit codes 7 (refused, also TCP reset on connect) and 28 (timeout)
# mean nothing answered.
expect_unreachable() {
  local url=$1 what=$2 rc=0 code
  code="$(curl -sS --noproxy '*' --max-time 5 -k -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)" || rc=$?
  if [[ ${rc} -eq 7 || ${rc} -eq 28 || ${rc} -eq 56 || ${rc} -eq 35 ]]; then
    reason="${what}: connection refused/reset (curl exit ${rc})"
    return 0
  fi
  reason="${what}: answered ${code:-?} (curl exit ${rc})"
  return 1
}

check_etcd_closed() {
  expect_unreachable "http://${GATEWAY_IP}:2381/metrics" "etcd metrics :2381"
}

check_etcd_proxy_auth() {
  expect_code 401 "etcd metrics proxy :2382 without token" --cacert "${CA_FILE}" \
    "https://${GATEWAY_IP}:2382/metrics"
}

# From the node itself the proxy answers 401; from outside, the metrics
# firewall resets the connection before it gets there.
check_node_exporter() {
  local rc=0 code
  code="$(curl -sS --noproxy '*' --max-time 5 -k -o /dev/null -w '%{http_code}' "https://${GATEWAY_IP}:9100/metrics" 2>/dev/null)" || rc=$?
  if [[ ${code} == "401" ]]; then
    reason="node-exporter :9100 without token: 401"
    return 0
  fi
  if [[ ${rc} -eq 7 || ${rc} -eq 28 || ${rc} -eq 35 || ${rc} -eq 56 ]]; then
    reason="node-exporter :9100: closed to this machine (curl exit ${rc})"
    return 0
  fi
  reason="node-exporter :9100 without token: ${code:-?} (curl exit ${rc})"
  return 1
}

on_node() {
  command -v ip >/dev/null 2>&1 && ip -o addr show 2>/dev/null | grep -qF " ${GATEWAY_IP}/"
}

check_cilium_metrics() {
  if on_node; then
    reason="run on the node itself, where :9962 is open by design (run from another machine to check)"
    return 2
  fi
  expect_unreachable "http://${GATEWAY_IP}:9962/metrics" "Cilium metrics :9962"
}

# --- 9. Several nodes ----------------------------------------------------------

# Node name -> InternalIP of every node, and the names of the workers (no
# control-plane role), set by multinode().
nodes_tsv=""
workers=""

# multinode: 0 if the cluster has more than one node (kubectl needed);
# otherwise sets $reason and returns 2 (skipped).
multinode() {
  have_kubectl || {
    reason="no kubectl access to this cluster"
    return 2
  }
  if [[ -z ${nodes_tsv} ]]; then
    local nodes
    nodes="$(kubectl get nodes -o json)" || {
      reason="kubectl get nodes failed"
      return 1
    }
    nodes_tsv="$(jq -r '.items[] | "\(.metadata.name)\t\([.status.addresses[] | select(.type == "InternalIP") | .address] | first)"' <<<"${nodes}")"
    workers="$(jq -r '.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane") | not) | .metadata.name' <<<"${nodes}" | xargs)"
  fi
  if [[ $(wc -l <<<"${nodes_tsv}") -le 1 ]]; then
    reason="single node (workers join with \`make add-worker\`)"
    return 2
  fi
}

# Every DaemonSet has a ready pod on each node it targets; the per-node
# agents (Cilium, Fluentd, node-exporter) target every node.
check_daemonsets() {
  multinode || return
  local ds count bad short
  count=$(wc -l <<<"${nodes_tsv}")
  ds="$(kubectl get daemonsets --all-namespaces -o json)" || {
    reason="kubectl get daemonsets failed"
    return 1
  }
  bad="$(jq -r --argjson n "${count}" '.items[]
    | .metadata.name as $name
    | select(.status.numberReady < .status.desiredNumberScheduled
        or (($name == "cilium" or $name == "fluentd" or ($name | endswith("node-exporter"))) and .status.desiredNumberScheduled != $n))
    | "\(.metadata.namespace)/\($name) \(.status.numberReady)/\(.status.desiredNumberScheduled)"' <<<"${ds}" | xargs)"
  if [[ -n ${bad} ]]; then
    reason="not ready on every node: ${bad}"
    return 1
  fi
  short="$(jq -r '[.items[] | select(.metadata.name == "cilium" or .metadata.name == "fluentd" or (.metadata.name | endswith("node-exporter")))
    | "\(.metadata.name | sub("kube-prometheus-stack-prometheus-"; "")) \(.status.numberReady)/\(.status.desiredNumberScheduled)"] | join(", ")' <<<"${ds}")"
  reason="${count} nodes, every DaemonSet ready on each: ${short}"
}

# Envoy and the demo app run on more than one node (topologySpread);
# replicas that piled up on one node (e.g. after a long outage of a
# worker) are spread again by `make add-worker`.
check_spread() {
  multinode || return
  local pods line app nodes summary="" bad=""
  pods="$(kubectl get pods --all-namespaces -o json)" || {
    reason="kubectl get pods failed"
    return 1
  }
  while read -r line; do
    app=${line%%$'\t'*}
    nodes=${line#*$'\t'}
    summary+="${summary:+; }${app} on ${nodes}"
    [[ ${nodes} == *","* ]] || bad+=" ${app}"
  done < <(jq -r '[.items[] | select(.status.phase == "Running")
      | {app: (if .metadata.namespace == "envoy-gateway-system" and .metadata.labels["app.kubernetes.io/component"] == "proxy" then "envoy"
               elif .metadata.namespace == "demo" then .metadata.labels["app.kubernetes.io/component"] // empty
               else empty end), node: .spec.nodeName}]
    | group_by(.app)[] | "\(.[0].app)\t\([.[].node] | unique | join(","))"' <<<"${pods}")
  reason=${summary:-no Envoy or demo app pods}
  if [[ -n ${bad} || -z ${summary} ]]; then
    reason+="; on one node only:${bad} (\`make add-worker\` spreads them again)"
    return 1
  fi
}

# The Gateway has an address on every node (Cilium node IPAM,
# externalTrafficPolicy Cluster) and answers on each of them.
check_gateway_addresses() {
  multinode || return
  local addresses ip code ok="" bad=""
  addresses="$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{range .status.addresses[*]}{.value}{"\n"}{end}' 2>/dev/null)"
  while read -r ip; do
    [[ -n ${ip} ]] || continue
    code="$(curl -sS --noproxy '*' --max-time 15 --cacert "${CA_FILE}" -o /dev/null -w '%{http_code}' \
      --resolve "app.${DOMAIN}:443:${ip}" "https://app.${DOMAIN}/" 2>/dev/null || true)"
    if [[ ${code} == "200" ]]; then ok+=" ${ip}"; else bad+=" ${ip}:${code:-000}"; fi
  done <<<"${addresses}"
  reason="HTTPS 200 via${ok:- none}"
  if [[ -n ${bad} ]]; then
    reason+="; failed:${bad}"
    return 1
  fi
  if [[ $(wc -w <<<"${ok}") -lt $(wc -l <<<"${nodes_tsv}") ]]; then
    reason+="; fewer Gateway addresses than nodes"
    return 1
  fi
}

# The API server reaches the kubelet of every worker with a verified
# certificate: `kubectl logs` of a pod there and `kubectl top` of the node.
check_worker_kubelet() {
  multinode || return
  local node pod top details=""
  top="$(kubectl top nodes --no-headers 2>/dev/null)" || top=""
  for node in ${workers}; do
    pod="$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=${node}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [[ -z ${pod} ]] || ! kubectl -n kube-system logs "${pod}" -c cilium-agent --tail=1 >/dev/null 2>&1; then
      reason="kubectl logs of ${pod:-a cilium pod} on ${node} failed"
      return 1
    fi
    if ! awk -v n="${node}" '$1 == n { found = 1 } END { exit !found }' <<<"${top}"; then
      reason="kubectl top nodes: no data for ${node}"
      return 1
    fi
    details+="${details:+; }${node}: logs of ${pod}, top $(awk -v n="${node}" '$1 == n { print "CPU " $2 ", memory " $4 }' <<<"${top}")"
  done
  reason=${details}
}

# Logs of pods on every worker reach VictoriaLogs.
check_worker_logs() {
  multinode || return
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set"
    return 2
  }
  local node count details=""
  for node in ${workers}; do
    count="$(ui_get logs /select/logsql/query \
      --data-urlencode "query=_time:10m kubernetes.host:\"${node}\" | stats count() as n" 2>/dev/null |
      jq -r '.n // empty' 2>/dev/null || true)"
    if [[ -z ${count} || ${count} -eq 0 ]]; then
      reason="no log records from pods on ${node} within the last 10 min"
      return 1
    fi
    details+="${details:+; }${node}: ${count} records in 10 min"
  done
  reason=${details}
}

# Prometheus scrapes node-exporter and the kubelet of every node.
check_worker_metrics() {
  multinode || return
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set"
    return 2
  }
  local node ip exporter kubelet details=""
  while IFS=$'\t' read -r node ip; do
    exporter="$(promql_value "up{job=\"node-exporter\",instance=\"${ip}:9100\"} * on (instance) group_left (nodename) node_uname_info{nodename=\"${node}\"}")"
    kubelet="$(promql_value "up{job=\"kubelet\",metrics_path=\"/metrics\",node=\"${node}\"}")"
    if [[ ${exporter} != "1" || ${kubelet} != "1" ]]; then
      reason="${node}: node-exporter up=${exporter:-none}, kubelet up=${kubelet:-none}"
      return 1
    fi
    details+="${details:+, }${node}"
  done <<<"${nodes_tsv}"
  reason="node-exporter and kubelet up on ${details}"
}

# --- 10. Tracing ---------------------------------------------------------------

# "on", "off" or "unknown", set by setup(); the reason when off.
tracing_state=""
tracing_reason=""
# W3C trace ID of the request sent by check_trace.
trace_id=""

# tracing: 0 if tracing is deployed; otherwise sets $reason and returns 2.
tracing() {
  case ${tracing_state} in
    on) return 0 ;;
    off) reason=${tracing_reason} ;;
    *) reason="cannot tell whether tracing is deployed (no kubectl access and no UI_PASSWORD)" ;;
  esac
  return 2
}

# traces_get <path> <curl args...>: VictoriaTraces API through the Gateway.
traces_get() {
  local path=$1
  shift
  ui_get traces "${path}" "$@"
}

# random_hex <bytes>: lower-case hex string.
random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# A request with a known W3C "traceparent" goes through the Gateway; Envoy
# continues that trace, so VictoriaTraces must return a trace with exactly
# this ID (Jaeger query API) holding the Gateway's span of the application
# route, tagged with the route and the version of the backend that answered.
check_trace() {
  tracing || return
  [[ -n ${UI_PASSWORD} ]] || {
    reason="UI_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  local start spans summary
  trace_id="$(random_hex 16)"
  start=${SECONDS}
  https app -o /dev/null -H "traceparent: 00-${trace_id}-$(random_hex 8)-01" \
    "https://app.${DOMAIN}/" 2>/dev/null || true
  while true; do
    # Spans of the Gateway: operation, route tag, backend.version tag.
    # shellcheck disable=SC2016 # jq variables
    spans="$(traces_get "/select/jaeger/api/traces/${trace_id}" 2>/dev/null | jq -c --arg svc "${TRACE_SERVICE}" '
      [.data[0] as $t | $t.spans[]? | select($t.processes[.processID].serviceName == $svc)
        | {op: .operationName,
           route: ([.tags[] | select(.key == "gateway.route") | .value] | first),
           version: ([.tags[] | select(.key == "backend.version") | .value] | first)}]' 2>/dev/null || true)"
    summary="$(jq -r --arg ns "${GATEWAY_NAMESPACE}" '[.[] | select((.route // "") | startswith("httproute/\($ns)/app/")) | select(.version == "v1" or .version == "v2")] | first // empty
      | "route \(.route), backend.version=\(.version)"' <<<"${spans:-[]}" 2>/dev/null || true)"
    if [[ -n ${summary} ]]; then
      reason="trace ${trace_id}: $(jq 'length' <<<"${spans}") spans of ${TRACE_SERVICE} after $((SECONDS - start)) s; ${summary}"
      return 0
    fi
    if [[ $((SECONDS - start)) -ge ${TRACE_TIMEOUT} ]]; then
      reason="trace ${trace_id}: no span of ${TRACE_SERVICE} with the app route and backend version after ${TRACE_TIMEOUT} s (got: ${spans:-nothing})"
      return 1
    fi
    sleep 3
  done
}

# The same trace ID reached Angie (traceparent passed on by Envoy) and is in
# its access log in VictoriaLogs: log <-> trace correlation.
check_trace_log() {
  tracing || return
  [[ -n ${UI_PASSWORD} && -n ${trace_id} ]] || {
    reason="no traced request (previous check skipped)"
    return 2
  }
  local records versions
  records="$(ui_get logs /select/logsql/query \
    --data-urlencode "query=trace_id:=\"${trace_id}\" kubernetes.container_name:=angie" 2>/dev/null || true)"
  versions="$(jq -r 'select(.traffic != "shadow") | .version' <<<"${records}" 2>/dev/null | sort -u | xargs || true)"
  if [[ -z ${versions} ]]; then
    reason="trace_id ${trace_id}: no Angie access log record in VictoriaLogs yet"
    return 1
  fi
  reason="trace_id ${trace_id} in the Angie access log (version ${versions}) and in the trace"
}

# Grafana: the traces datasource returns the trace by its ID, and the
# datasources link both ways (VictoriaLogs derived field trace_id -> traces,
# traces "Related logs" -> VictoriaLogs).
check_grafana_traces() {
  tracing || return
  [[ -n ${trace_id} ]] || {
    reason="no traced request (previous check skipped)"
    return 2
  }
  local user=${GRAFANA_USER:-} password=${GRAFANA_PASSWORD:-} body spans derived related
  if [[ -z ${password} ]] && have_kubectl; then
    user="$(kubectl -n monitoring get secret "${GRAFANA_ADMIN_SECRET}" -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d || true)"
    password="$(kubectl -n monitoring get secret "${GRAFANA_ADMIN_SECRET}" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
  fi
  [[ -n ${password} ]] || {
    reason="GRAFANA_PASSWORD not set (no kubectl access to read it)"
    return 2
  }
  grafana() {
    https grafana -u "${user:-admin}:${password}" "$@"
  }
  body="$(printf '{"queries":[{"refId":"A","datasource":{"type":"jaeger","uid":"%s"},"query":"%s"}],"from":"now-1h","to":"now"}' \
    "${TRACES_DATASOURCE}" "${trace_id}")"
  spans="$(grafana -H 'Content-Type: application/json' -X POST --data "${body}" \
    "https://grafana.${DOMAIN}/api/ds/query" 2>/dev/null |
    jq -r '.results.A.frames[0].data.values[0] // [] | length' 2>/dev/null || true)"
  derived="$(grafana "https://grafana.${DOMAIN}/api/datasources/uid/${LOGS_DATASOURCE}" 2>/dev/null |
    jq -r '[.jsonData.derivedFields[]? | select(.matcherRegex == "trace_id") | .datasourceUid] | first // empty' 2>/dev/null || true)"
  related="$(grafana "https://grafana.${DOMAIN}/api/datasources/uid/${TRACES_DATASOURCE}" 2>/dev/null |
    jq -r '.jsonData.tracesToLogsV2.datasourceUid // empty' 2>/dev/null || true)"
  reason="trace ${trace_id} via datasource \"${TRACES_DATASOURCE}\": ${spans:-0} spans; logs -> trace: ${derived:-no link}; trace -> logs: ${related:-no link}"
  [[ ${spans:-0} -gt 0 && ${derived} == "${TRACES_DATASOURCE}" && ${related} == "${LOGS_DATASOURCE}" ]]
}

# --- Main ---------------------------------------------------------------------

setup() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '${tmp_dir}'" EXIT

  # Right after a boot the node has a kubeconfig, but the API server is
  # still starting: wait for it instead of giving up.
  local kube=false deadline=$((SECONDS + WAIT)) waited=
  if command -v kubectl >/dev/null 2>&1 && kubectl config current-context >/dev/null 2>&1; then
    until kubectl get --raw /readyz >/dev/null 2>&1 || [[ ${SECONDS} -ge ${deadline} ]]; do
      [[ -n ${waited} ]] || printf 'Waiting for the API server (up to %d s)...\n' "${WAIT}"
      waited=true
      sleep 5
    done
  fi
  have_kubectl && kube=true
  if [[ -z ${GATEWAY_IP:-} ]]; then
    [[ ${kube} == true ]] || die "no kubectl access: set GATEWAY_IP (and CA_FILE, UI_PASSWORD), see the header of $0"
    # With workers the Gateway has an address on every node; the checks
    # below that look at the control plane (etcd, its metrics proxy) need
    # the control plane's, which is also the API server address.
    local addresses server
    addresses="$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
      -o jsonpath='{range .status.addresses[*]}{.value}{"\n"}{end}' 2>/dev/null || true)"
    server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    server=${server#https://}
    server=${server%:*}
    if grep -qxF "${server}" <<<"${addresses}"; then
      GATEWAY_IP=${server}
    else
      GATEWAY_IP="$(head -n1 <<<"${addresses}")"
    fi
    [[ -n ${GATEWAY_IP} ]] || die "Gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME} has no address yet"
  fi
  if [[ -z ${CA_FILE:-} || ! -s ${CA_FILE:-} ]]; then
    [[ ${kube} == true ]] || die "CA_FILE is not set or empty (\`make ca\` on the node writes ca.crt)"
    CA_FILE="${tmp_dir}/ca.crt"
    kubectl -n "${CA_NAMESPACE}" get secret "${CA_SECRET}" -o jsonpath='{.data.ca\.crt}' |
      base64 -d >"${CA_FILE}" || die "cannot read the demo CA from ${CA_NAMESPACE}/${CA_SECRET}"
  fi
  if [[ -z ${UI_PASSWORD:-} && ${kube} == true ]]; then
    UI_PASSWORD="$(kubectl -n "${GATEWAY_NAMESPACE}" get secret "${BASIC_AUTH_SECRET}" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  fi
  UI_PASSWORD=${UI_PASSWORD:-}
  if [[ -z ${ENVOY_REPLICAS} && ${kube} == true ]]; then
    ENVOY_REPLICAS="$(kubectl -n envoy-gateway-system get deployments \
      -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME},gateway.envoyproxy.io/owning-gateway-namespace=${GATEWAY_NAMESPACE}" \
      -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || true)"
  fi
  ENVOY_REPLICAS=${ENVOY_REPLICAS:-2}
  readonly GATEWAY_IP CA_FILE UI_PASSWORD ENVOY_REPLICAS

  # Tracing deployed? From the cluster if possible, else from the traces
  # UI route (it exists only with tracing on).
  local code
  if [[ ${kube} == true ]]; then
    if kubectl -n "${TRACING_NAMESPACE}" get deployment "${TRACING_DEPLOYMENT}" >/dev/null 2>&1 ||
      kubectl get namespace "${TRACING_NAMESPACE}" >/dev/null 2>&1; then
      tracing_state=on
    else
      tracing_state=off
    fi
  elif [[ -n ${UI_PASSWORD} ]]; then
    code="$(ui_get traces /select/jaeger/api/services -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
    case ${code} in
      200) tracing_state=on ;;
      404) tracing_state=off ;;
      *) tracing_state=unknown ;;
    esac
  fi
  tracing_reason="tracing is off (TRACING=false, or TRACING=auto and the control plane has little memory; see \`make status\`)"
  if [[ ${tracing_state} == on ]]; then
    KEY_JOBS+=(victoria-traces)
  fi
  readonly KEY_JOBS tracing_state tracing_reason
}

main() {
  setup
  printf 'Verifying https://app.%s at %s (from %s)\n\n' "${DOMAIN}" "${GATEWAY_IP}" "$(hostname)"

  check 1 "Node Ready" check_node "${WAIT}"
  check 1 "All pods Running and Ready" check_pods "${WAIT}"
  check 1 "All Helm releases deployed" check_releases
  check 2 "Gateway Programmed, address = node IP" check_gateway 120
  check 2 "HTTPRoutes Accepted, references resolved" check_routes 60

  # Baseline of the Envoy request counter, before the traffic below.
  [[ -z ${UI_PASSWORD} ]] || envoy_requests_before="$(envoy_requests)"
  traffic_start=${SECONDS}

  check 3 "HTTP -> 301 to HTTPS" check_http_redirect 60
  check 3 "HTTPS -> 200 \"Hello World!\"" check_https_app 60
  check 4 "Canary split (weights 90/10)" check_canary
  check 4 "Path /v2 -> v2" check_canary_path
  check 4 "Header X-Canary: true -> v2" check_canary_header
  check 4 "Response headers set/removed by the route" check_response_headers
  check 5 "Rate limit /limited -> 429" check_rate_limit
  check 6 "Request ID in VictoriaLogs (<= ${LOG_TIMEOUT} s)" check_logs
  check 6 "Request header overwritten by the route" check_request_header 30
  check 6 "Mirror: shadow copy of the request at v2" check_mirror 30
  check 7 "Prometheus: key targets up" check_targets "${WAIT}"
  check 7 "Prometheus: Envoy request counter grew" check_envoy_counter 120
  check 7 "Prometheus: Angie requests by version" check_angie_metrics 120
  check 7 "kubectl top nodes / pods (metrics-server)" check_kubectl_top 120
  check 7 "Alerts delivered: Watchdog in receiver log" check_alert_delivery "${ALERT_TIMEOUT}"
  check 8 "Prometheus UI requires password" check_prometheus_auth
  check 8 "Logs UI requires password" check_logs_auth
  check 8 "Lifecycle/insert endpoints not routed" check_closed_endpoints
  check 8 "etcd :2381 not reachable" check_etcd_closed
  check 8 "etcd metrics proxy requires token" check_etcd_proxy_auth
  check 8 "node-exporter :9100 requires token" check_node_exporter
  check 8 "Cilium metrics :9962 closed to the LAN" check_cilium_metrics
  local rc=0
  multinode || rc=$?
  if [[ ${rc} -eq 1 ]]; then
    result 9 "Several nodes" fail "${reason}"
  elif [[ ${rc} -eq 0 ]]; then
    check 9 "Nodes: DaemonSets ready on every node" check_daemonsets "${WAIT}"
    check 9 "Nodes: Envoy and demo app on several nodes" check_spread
    check 9 "Nodes: Gateway answers on every node address" check_gateway_addresses 60
    check 9 "Nodes: kubectl logs / top on every worker" check_worker_kubelet 120
    check 9 "Nodes: worker pod logs in VictoriaLogs" check_worker_logs 120
    check 9 "Nodes: node-exporter, kubelet up per node" check_worker_metrics 120
  else
    result 9 "Several nodes" skip "${reason}"
  fi
  if tracing; then
    check 10 "Tracing: trace by traceparent (<= ${TRACE_TIMEOUT} s)" check_trace
    check 10 "Tracing: trace_id in the Angie access log" check_trace_log "${LOG_TIMEOUT}"
    check 10 "Tracing: Grafana trace by ID, log <-> trace" check_grafana_traces 60
  else
    result 10 "Tracing" skip "${reason}"
  fi

  printf '\nPassed: %d, failed: %d, skipped: %d\n' "${passed}" "${failed}" "${skipped}"
  if [[ ${failed} -gt 0 ]]; then
    printf 'RESULT: FAILED\n'
    exit 1
  fi
  printf 'RESULT: OK\n'
}

main "$@"
