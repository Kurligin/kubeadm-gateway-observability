#!/usr/bin/env bash
# Install promtool from the official Prometheus release, checksum verified.
#
#   scripts/install-promtool.sh <version> <sha256 of the linux-amd64 tarball> <bin dir>
#
# Does nothing if <bin dir>/promtool already has this version.
# Called by `make lint-deps`; linux/amd64 only.
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

main() {
  [[ $# -eq 3 ]] || die "usage: $0 <version> <sha256> <bin dir>"
  local version=$1 sha256=$2 bin_dir=$3
  [[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || die "only linux/amd64 is supported"

  if [[ -x ${bin_dir}/promtool ]] && "${bin_dir}/promtool" --version 2>&1 | grep -q "version ${version} "; then
    log "promtool ${version} already installed"
    return
  fi

  local name="prometheus-${version}.linux-amd64"
  local url="https://github.com/prometheus/prometheus/releases/download/v${version}/${name}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '${tmp}'" EXIT

  log "Downloading promtool ${version}"
  curl -fsSL --retry 3 -o "${tmp}/prometheus.tar.gz" "${url}"
  printf '%s  %s\n' "${sha256}" "${tmp}/prometheus.tar.gz" | sha256sum --check --quiet ||
    die "checksum mismatch for ${url}"
  tar -xzf "${tmp}/prometheus.tar.gz" -C "${tmp}" "${name}/promtool"
  install -m 0755 "${tmp}/${name}/promtool" "${bin_dir}/promtool"
  log "promtool ${version} installed to ${bin_dir}"
}

main "$@"
