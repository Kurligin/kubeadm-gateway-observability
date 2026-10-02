#!/usr/bin/env bash
# Install a binary from a release tarball, checksum verified.
#
#   scripts/install-tool.sh <url of a .tar.gz> <sha256 of it> <path in the archive> <bin dir>
#
# Installs <path in the archive> as <bin dir>/<its base name>. Does nothing if
# that binary was already installed from an archive with this checksum (a
# stamp file next to it records the checksum). Called by `make lint-deps`
# for promtool, helm, helmfile, kubeconform, trivy and kube-linter;
# linux/amd64 only (versions.env pins the linux-amd64 checksums).
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

main() {
  [[ $# -eq 4 ]] || die "usage: $0 <url> <sha256> <path in the archive> <bin dir>"
  local url=$1 sha256=$2 member=$3 bin_dir=$4
  [[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] || die "only linux/amd64 is supported"
  local name=${member##*/}
  local stamp="${bin_dir}/.${name}.sha256"

  if [[ -x ${bin_dir}/${name} && -f ${stamp} && $(<"${stamp}") == "${sha256}" ]]; then
    log "${name} already installed (${url##*/})"
    return
  fi

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '${tmp}'" EXIT

  log "Downloading ${url}"
  curl -fsSL --retry 3 -o "${tmp}/archive.tar.gz" "${url}"
  printf '%s  %s\n' "${sha256}" "${tmp}/archive.tar.gz" | sha256sum --check --quiet ||
    die "checksum mismatch for ${url}"
  tar -xzf "${tmp}/archive.tar.gz" -C "${tmp}" "${member}"
  mkdir -p "${bin_dir}"
  install -m 0755 "${tmp}/${member}" "${bin_dir}/${name}"
  printf '%s\n' "${sha256}" >"${stamp}"
  log "${name} installed to ${bin_dir}"
}

main "$@"
