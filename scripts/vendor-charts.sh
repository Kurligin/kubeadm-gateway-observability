#!/usr/bin/env bash
# Upstream Helm charts kept in the repository (vendor/charts/*.tgz).
#
#   scripts/vendor-charts.sh check   offline: every chart below is in
#                                    vendor/charts at the version of
#                                    versions.env, with its pinned sha256, and
#                                    nothing else is there
#   scripts/vendor-charts.sh fetch   download what is missing or differs
#                                    from the upstream repositories (helm
#                                    pull), checked against the same sha256,
#                                    and remove archives of other versions
#   scripts/vendor-charts.sh sha     download every chart and print its
#                                    <KEY>=<sha256> line for versions.env
#                                    (after a version bump)
#
# helmfile installs these archives, so neither a deployment nor offline
# rendering (`make lint`, `make images-list`) needs a chart repository:
# github.io and OCI registries that are blocked or unreliable in some
# networks are never contacted. A chart archive is the very file the
# upstream repository serves, so its sha256 is stable. `make lint` and
# `make platform` run `check`; `fetch` and `sha` need helm and the network.
# Paths are relative to the repository root (make runs from there).
set -euo pipefail

readonly VERSIONS_FILE="versions.env"
readonly VENDOR_DIR="vendor/charts"

# <chart name> <Helm repository URL or oci:// registry path> <version key>
# <version prefix, "-" for none> <sha256 key>. The archive is
# <chart name>-<prefix><version>.tgz, the name `helm pull` gives it.
readonly CHARTS=(
  "prometheus-operator-crds https://prometheus-community.github.io/helm-charts PROMETHEUS_OPERATOR_CRDS_VERSION - PROMETHEUS_OPERATOR_CRDS_CHART_SHA256"
  "cilium https://helm.cilium.io CILIUM_VERSION - CILIUM_CHART_SHA256"
  "cert-manager https://charts.jetstack.io CERT_MANAGER_VERSION v CERT_MANAGER_CHART_SHA256"
  "gateway-helm oci://docker.io/envoyproxy ENVOY_GATEWAY_VERSION v ENVOY_GATEWAY_CHART_SHA256"
  "gateway-crds-helm oci://docker.io/envoyproxy ENVOY_GATEWAY_VERSION v ENVOY_GATEWAY_CRDS_CHART_SHA256"
  "kube-prometheus-stack https://prometheus-community.github.io/helm-charts KUBE_PROMETHEUS_STACK_VERSION - KUBE_PROMETHEUS_STACK_CHART_SHA256"
  "victoria-logs-single https://victoriametrics.github.io/helm-charts VICTORIA_LOGS_CHART_VERSION - VICTORIA_LOGS_CHART_SHA256"
  "victoria-traces-single https://victoriametrics.github.io/helm-charts VICTORIA_TRACES_CHART_VERSION - VICTORIA_TRACES_CHART_SHA256"
  "metrics-server https://kubernetes-sigs.github.io/metrics-server METRICS_SERVER_CHART_VERSION - METRICS_SERVER_CHART_SHA256"
)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
die() {
  err "$*"
  exit 1
}

# setting <key>: its value in versions.env (empty if it is not there).
setting() {
  sed -n "s/^$1=//p" "${VERSIONS_FILE}" | tail -n 1
}

# Fields of one CHARTS entry, resolved against versions.env.
parse() {
  local entry=$1 prefix version_key
  read -r name source version_key prefix sha_key <<<"${entry}"
  [[ ${prefix} == "-" ]] && prefix=""
  version="$(setting "${version_key}")"
  [[ -n ${version} ]] || die "${version_key} is not set in ${VERSIONS_FILE}"
  version="${prefix}${version}"
  sha256="$(setting "${sha_key}")"
  file="${VENDOR_DIR}/${name}-${version}.tgz"
}

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# chart_meta <archive> <field>: name or version from <chart>/Chart.yaml.
chart_meta() {
  tar -xzOf "$1" "${name}/Chart.yaml" 2>/dev/null |
    sed -n "s/^$2:[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}[[:space:]]*\$/\1/p" | head -n 1
}

# check_archive <archive>: matches the pinned sha256 and is the chart it
# claims to be. Prints the reason and fails otherwise.
check_archive() {
  local archive=$1 actual
  [[ -n ${sha256} ]] || {
    err "${sha_key} is not set in ${VERSIONS_FILE} (scripts/vendor-charts.sh sha prints it)"
    return 1
  }
  actual="$(sha256_of "${archive}")"
  [[ ${actual} == "${sha256}" ]] || {
    err "${archive}: sha256 ${actual}, ${VERSIONS_FILE} pins ${sha_key}=${sha256}"
    return 1
  }
  [[ "$(chart_meta "${archive}" name)" == "${name}" && "$(chart_meta "${archive}" version)" == "${version}" ]] || {
    err "${archive}: not chart ${name} ${version} inside"
    return 1
  }
}

expected_files() {
  local entry name source version_key prefix sha_key version sha256 file
  for entry in "${CHARTS[@]}"; do
    parse "${entry}"
    printf '%s\n' "${file}"
  done
}

check() {
  local entry name source sha_key version sha256 file rc=0 count=0 extra
  for entry in "${CHARTS[@]}"; do
    parse "${entry}"
    if [[ ! -f ${file} ]]; then
      err "${file} is missing: run scripts/vendor-charts.sh fetch"
      rc=1
      continue
    fi
    check_archive "${file}" || rc=1
    count=$((count + 1))
  done
  # Anything else in vendor/charts (an archive of an older version) is
  # stale: helmfile would never use it.
  while read -r extra; do
    [[ -n ${extra} ]] || continue
    err "${extra}: not a chart of ${VERSIONS_FILE} (stale? scripts/vendor-charts.sh fetch removes it)"
    rc=1
  done < <(comm -23 <(find "${VENDOR_DIR}" -type f -name '*.tgz' 2>/dev/null | sort) <(expected_files | sort))
  [[ ${rc} -eq 0 ]] && log "${count} vendored charts match ${VERSIONS_FILE} (version and sha256)"
  return "${rc}"
}

# pull <dir>: downloads the chart of the current entry into <dir>.
pull() {
  local dir=$1
  command -v helm >/dev/null || die "helm not found (make lint-deps or make cluster installs it)"
  if [[ ${source} == oci://* ]]; then
    helm pull "${source}/${name}" --version "${version}" --destination "${dir}" >/dev/null
  else
    helm pull "${name}" --repo "${source}" --version "${version}" --destination "${dir}" >/dev/null
  fi
  [[ -f ${dir}/${name}-${version}.tgz ]] || die "helm pull gave no ${name}-${version}.tgz"
}

fetch() {
  local entry name source sha_key version sha256 file work stale
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '${work}'" EXIT
  mkdir -p "${VENDOR_DIR}"
  for entry in "${CHARTS[@]}"; do
    parse "${entry}"
    if [[ -f ${file} ]] && check_archive "${file}" 2>/dev/null; then
      log "up to date: ${file}"
      continue
    fi
    log "downloading ${name} ${version} from ${source}"
    pull "${work}"
    check_archive "${work}/${name}-${version}.tgz" || die "${name} ${version} from ${source} does not match ${VERSIONS_FILE}"
    mv "${work}/${name}-${version}.tgz" "${file}"
    log "vendored: ${file}"
  done
  while read -r stale; do
    [[ -n ${stale} ]] || continue
    rm -f -- "${stale}"
    log "removed: ${stale}"
  done < <(comm -23 <(find "${VENDOR_DIR}" -type f -name '*.tgz' | sort) <(expected_files | sort))
  check
}

print_sha() {
  local entry name source sha_key version sha256 file work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '${work}'" EXIT
  for entry in "${CHARTS[@]}"; do
    parse "${entry}"
    pull "${work}"
    printf '%s=%s\n' "${sha_key}" "$(sha256_of "${work}/${name}-${version}.tgz")"
  done
}

main() {
  [[ -r ${VERSIONS_FILE} ]] || die "${VERSIONS_FILE} not found: run from the repository root"
  case ${1:-} in
    check) check ;;
    fetch) fetch ;;
    sha) print_sha ;;
    *) die "usage: $0 check|fetch|sha (see the header of $0)" ;;
  esac
}

main "$@"
