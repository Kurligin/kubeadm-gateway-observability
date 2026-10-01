#!/usr/bin/env bash
# Validate the alerting rules of charts/observability-extras with promtool.
#
#   scripts/check-rules.sh [python]
#
# Renders the chart, takes spec.groups of every PrometheusRule (promtool
# reads plain rule files, not Kubernetes objects) and runs
# `promtool check rules`. The optional argument is the Python interpreter
# with PyYAML (default: python3; `make lint` passes the one from .venv).
# Called by `make lint`.
set -euo pipefail

readonly CHART="charts/observability-extras"

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

main() {
  local python=${1:-python3}
  command -v promtool >/dev/null || die "promtool not found"
  command -v helm >/dev/null || die "helm not found"

  local rules
  rules="$(mktemp)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -f '${rules}'" EXIT

  helm template rules "${CHART}" --set victoriaLogs.url=http://victoria-logs:9428 |
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
' >"${rules}"

  promtool check rules "${rules}"
}

main "$@"
