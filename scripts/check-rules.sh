#!/usr/bin/env bash
# Validate the Prometheus rules of charts/observability-extras with promtool
# and run their unit tests.
#
#   scripts/check-rules.sh [python]
#
# Renders the chart, takes spec.groups of every PrometheusRule (promtool
# reads plain rule files, not Kubernetes objects) into rules.yaml, runs
# `promtool check rules` on it and `promtool test rules` on every test file
# in tests/prometheus/ (they load rules.yaml from their own directory). The
# optional argument is the Python interpreter with PyYAML (default: python3;
# `make lint` passes the one from .venv). Called by `make lint`.
set -euo pipefail

readonly CHART="charts/observability-extras"
readonly TESTS_DIR="tests/prometheus"

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

main() {
  local python=${1:-python3}
  command -v promtool >/dev/null || die "promtool not found"
  command -v helm >/dev/null || die "helm not found"

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '${work}'" EXIT

  helm template rules "${CHART}" --set victoriaLogs.url=http://victoria-logs:9428 \
    --set alertReceiver.image=lint |
    "${python}" -c '
import sys
import yaml

groups = []
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "PrometheusRule":
        groups.extend(doc["spec"]["groups"])
if not groups:
    sys.exit("no PrometheusRule found")
yaml.safe_dump({"groups": groups}, sys.stdout, sort_keys=False)
' >"${work}/rules.yaml"

  promtool check rules "${work}/rules.yaml"

  local tests=("${TESTS_DIR}"/*.yaml)
  [[ -e ${tests[0]} ]] || die "no rule tests found in ${TESTS_DIR}"
  cp "${tests[@]}" "${work}/"
  (cd "${work}" && promtool test rules "${tests[@]##*/}")
}

main "$@"
