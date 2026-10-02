#!/usr/bin/env bash
# Static checks of the rendered Kubernetes manifests, without a cluster.
#
#   scripts/check-manifests.sh <python>
#
# Renders every release with `helmfile template` (offline: the API server
# address is a placeholder, only the chart repositories are needed), one
# directory per release, and runs:
#
#   kubeconform  every object against the schemas of Kubernetes v${K8S_VERSION}
#                (strict: unknown fields are errors) and of the CRDs it uses:
#                schemas generated from the very CRDs that get installed
#                (scripts/crd_schemas.py), Gateway API and Envoy Gateway
#                included. CustomResourceDefinition objects themselves are
#                skipped: there is no published schema for them.
#   trivy config misconfigurations: HIGH and CRITICAL in every release, also
#                MEDIUM in our own charts. Accepted findings, each with its
#                reason, are listed in .trivyignore.yaml.
#   kube-linter  our own charts (all built-in checks); excluded checks and
#                their reasons are in .kube-linter.yaml, single accepted
#                findings are annotated on the object itself
#                (ignore-check.kube-linter.io/<check>: <reason>).
#
# A tool that is not installed is skipped with a "skip:" line (`make
# lint-deps` installs them all). <python> is an interpreter with PyYAML.
# Environment (passed by `make lint`): K8S_VERSION, ENVOY_GATEWAY_VERSION,
# KUBERNETES_JSON_SCHEMA_COMMIT.
set -euo pipefail

# Releases built from the charts of this repository (the vendored
# local-path-provisioner is upstream code and is treated as such).
readonly OWN_RELEASES=(namespaces network-policies pki gateway ui-routes demo-app
  etcd-metrics-proxy logging observability-extras)
readonly PLACEHOLDER_NODE_IP=192.0.2.10
readonly GATEWAY_CRDS_CHART="oci://docker.io/envoyproxy/gateway-crds-helm"
readonly GATEWAY_CRDS_VALUES="values/envoy-gateway-crds.yaml"
readonly CACHE_DIR=".cache"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

render() {
  local out=$1 errors="${work}/helmfile.log"
  log "Rendering every release (helmfile template)"
  # KUBECONFIG=/dev/null: never look at a real cluster. TRACING=true: the
  # optional tracing releases are rendered (and checked) too.
  if ! KUBECONFIG=/dev/null NODE_IP=${PLACEHOLDER_NODE_IP} TRACING=true \
    helmfile --quiet --file helmfile.yaml.gotmpl template --output-dir "${out}" \
    --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}' >/dev/null 2>"${errors}"; then
    cat "${errors}" >&2
    die "helmfile template failed"
  fi
  local release
  for release in "${OWN_RELEASES[@]}"; do
    [[ -d ${out}/${release} ]] || die "release ${release} was not rendered"
  done
}

run_kubeconform() {
  local rendered=$1 schemas="${work}/schemas"
  log "kubeconform: Kubernetes v${K8S_VERSION} and CRD schemas, strict"
  # The Envoy Gateway and Gateway API CRDs are applied by
  # scripts/apply-gateway-crds.sh, not by a release: render them the same way.
  helm template gateway-crds "${GATEWAY_CRDS_CHART}" --version "v${ENVOY_GATEWAY_VERSION}" \
    --values "${GATEWAY_CRDS_VALUES}" >"${work}/gateway-crds.yaml"
  find "${rendered}" -name '*.yaml' -exec cat {} + | cat - "${work}/gateway-crds.yaml" |
    "${python}" scripts/crd_schemas.py "${schemas}"
  mkdir -p "${CACHE_DIR}/kubeconform"
  kubeconform -strict -summary -output text \
    -kubernetes-version "${K8S_VERSION}" \
    -cache "${CACHE_DIR}/kubeconform" \
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${KUBERNETES_JSON_SCHEMA_COMMIT}/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
    -schema-location "${schemas}/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
    -skip CustomResourceDefinition \
    "${rendered}"
}

trivy_scan() {
  local target=$1 severity=$2
  trivy config --quiet --skip-check-update --skip-version-check --disable-telemetry \
    --cache-dir "${CACHE_DIR}/trivy" --misconfig-scanners kubernetes \
    --ignorefile .trivyignore.yaml --severity "${severity}" --exit-code 1 \
    --format table --table-mode detailed "${target}"
}

run_trivy() {
  local rendered=$1 own="${work}/own" release rc=0
  log "trivy config: HIGH and CRITICAL in every release"
  trivy_scan "${rendered}" HIGH,CRITICAL || rc=1
  # The same relative paths as in the full scan, so that .trivyignore.yaml
  # applies to both.
  mkdir -p "${own}"
  for release in "${OWN_RELEASES[@]}"; do
    cp -r "${rendered}/${release}" "${own}/"
  done
  log "trivy config: MEDIUM, HIGH and CRITICAL in our own charts"
  trivy_scan "${own}" MEDIUM,HIGH,CRITICAL || rc=1
  [[ ${rc} -eq 0 ]] && log "trivy config: no findings beyond .trivyignore.yaml"
  return "${rc}"
}

run_kube_linter() {
  local rendered=$1 release
  log "kube-linter: our own charts"
  # One input file: cross-object checks (NetworkPolicy and ServiceMonitor
  # selectors, PodDisruptionBudgets) see every object of our charts.
  for release in "${OWN_RELEASES[@]}"; do
    find "${rendered}/${release}" -name '*.yaml' | sort | while read -r file; do
      printf -- '---\n'
      cat "${file}"
    done
  done >"${work}/own.yaml"
  kube-linter lint --config .kube-linter.yaml "${work}/own.yaml"
}

main() {
  [[ $# -eq 1 ]] || die "usage: $0 <python>"
  python=$1
  : "${K8S_VERSION:?}" "${ENVOY_GATEWAY_VERSION:?}" "${KUBERNETES_JSON_SCHEMA_COMMIT:?}"
  command -v helmfile >/dev/null || die "helmfile not found (make lint-deps)"
  command -v helm >/dev/null || die "helm not found (make lint-deps)"

  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '${work}'" EXIT
  local rendered="${work}/rendered" rc=0
  render "${rendered}"

  if command -v kubeconform >/dev/null; then
    run_kubeconform "${rendered}" || rc=1
  else
    echo 'skip: kubeconform not installed (make lint-deps)'
  fi
  if command -v trivy >/dev/null; then
    run_trivy "${rendered}" || rc=1
  else
    echo 'skip: trivy not installed (make lint-deps)'
  fi
  if command -v kube-linter >/dev/null; then
    run_kube_linter "${rendered}" || rc=1
  else
    echo 'skip: kube-linter not installed (make lint-deps)'
  fi
  return "${rc}"
}

main "$@"
