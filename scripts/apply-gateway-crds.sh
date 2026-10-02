#!/usr/bin/env bash
# Install or upgrade the Envoy Gateway and Gateway API CRDs.
#
#   scripts/apply-gateway-crds.sh <chart archive> <values file>
#
# Renders the upstream chart gateway-crds-helm (the archive vendored in
# vendor/charts, see scripts/vendor-charts.sh) and applies it server-side
# (field manager "envoy-gateway-crds"), the way the Envoy Gateway docs
# recommend. A Helm release is not an option: the CRDs are ~3.7 MB and the
# release record would exceed the 1 MiB Secret limit. Re-applying unchanged
# CRDs changes nothing.
# Called by helmfile (presync hook of the "envoy-gateway" release), so the
# CRDs are upgraded together with the controller.
set -euo pipefail

readonly FIELD_MANAGER="envoy-gateway-crds"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

main() {
  [[ $# -eq 2 ]] || die "usage: $0 <chart archive> <values file>"
  local chart=$1 values=$2
  [[ -r ${chart} ]] || die "chart archive not found: ${chart} (scripts/vendor-charts.sh fetch)"
  [[ -r ${values} ]] || die "values file not found: ${values}"

  local rendered applied crds
  rendered="$(mktemp)"
  applied="$(mktemp)"
  # shellcheck disable=SC2064 # expand the paths now
  trap "rm -f '${rendered}' '${applied}'" EXIT

  log "Rendering ${chart}"
  helm template "${FIELD_MANAGER}" "${chart}" --values "${values}" >"${rendered}"

  log "Applying CRDs (server-side, field manager ${FIELD_MANAGER})"
  # --force-conflicts: take over fields set by an earlier installer (e.g.
  # the CRDs bundled with the gateway-helm chart).
  kubectl apply --server-side --force-conflicts --field-manager="${FIELD_MANAGER}" \
    --filename="${rendered}" --output=name >"${applied}"

  mapfile -t crds < <(grep '^customresourcedefinition' "${applied}")
  [[ ${#crds[@]} -gt 0 ]] || die "no CRDs found in ${chart}"
  kubectl wait --for=condition=Established --timeout=120s "${crds[@]}" >/dev/null
  log "${#crds[@]} CRDs are established"
}

main "$@"
