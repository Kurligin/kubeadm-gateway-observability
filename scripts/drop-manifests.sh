#!/usr/bin/env bash
# Helm post-renderer: drop objects of a release by kind and name.
#
#   scripts/drop-manifests.sh <Kind>/<name> [<Kind>/<name> ...]
#
# Reads the rendered manifests (YAML documents separated by "---") on stdin
# and writes them to stdout without the documents whose top-level "kind"
# and "metadata.name" match one of the arguments; everything else passes
# through byte for byte. Used by helmfile (postRenderer of the
# "victoria-logs" release) for an object the chart has no switch for.
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

main() {
  [[ $# -gt 0 ]] || die "usage: $0 <Kind>/<name> [<Kind>/<name> ...]"
  local arg
  for arg in "$@"; do
    [[ ${arg} == ?*/?* ]] || die "expected <Kind>/<name>, got: ${arg}"
  done

  awk -v drop="$*" '
    BEGIN { n = split(drop, list, " "); for (i = 1; i <= n; i++) skip[list[i]] = 1 }
    function flush() {
      if (doc != "" && !((kind "/" name) in skip)) printf "%s", doc
      doc = ""; kind = ""; name = ""; in_meta = 0
    }
    /^---/ { flush(); doc = $0 "\n"; next }
    {
      doc = doc $0 "\n"
      if ($0 ~ /^kind: /) { kind = substr($0, 7); sub(/[ \t\r]+$/, "", kind) }
      else if ($0 ~ /^metadata:/) { in_meta = 1 }
      else if ($0 ~ /^[^ #]/) { in_meta = 0 }
      else if (in_meta && name == "" && $0 ~ /^  name: /) {
        name = substr($0, 9); sub(/[ \t\r]+$/, "", name); gsub(/^["\047]|["\047]$/, "", name)
      }
    }
    END { flush() }
  '
}

main "$@"
