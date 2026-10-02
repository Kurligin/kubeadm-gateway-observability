#!/usr/bin/env bash
# Install a binary from a release tarball, checksum verified.
#
#   scripts/install-tool.sh <url of a .tar.gz> <sha256 of it> <path in the archive> <bin dir>
#
# <url> may list several sources of the same archive, "<url>|<url>|...":
# they are tried in order until one serves an archive with this checksum,
# so a source that is blocked or down only costs a retry.
# Installs <path in the archive> as <bin dir>/<its base name>. Does nothing if
# that binary was already installed from an archive with this checksum (a
# stamp file next to it records the checksum). Called by `make lint-deps`
# for promtool, helm, helmfile, kubeconform, trivy and kube-linter;
# linux/amd64 only (versions.env pins the linux-amd64 checksums).
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

main() {
  [[ $# -eq 4 ]] || die "usage: $0 <url>[|<url>...] <sha256> <path in the archive> <bin dir>"
  local urls=$1 sha256=$2 member=$3 bin_dir=$4
  local url=${urls%%|*}
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

  local -a sources
  local ok=false
  IFS='|' read -r -a sources <<<"${urls}"
  for url in "${sources[@]}"; do
    log "Downloading ${url}"
    # A source that cannot be reached in 15 s, or stalls below 1 KiB/s for
    # 30 s, is given up on (after the retries) for the next one.
    if ! curl -fsSL --retry 2 --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
      -o "${tmp}/archive.tar.gz" "${url}"; then
      warn "download failed: ${url}"
      continue
    fi
    if ! printf '%s  %s\n' "${sha256}" "${tmp}/archive.tar.gz" | sha256sum --check --quiet; then
      warn "checksum mismatch, archive ignored: ${url}"
      continue
    fi
    ok=true
    break
  done
  [[ ${ok} == true ]] || die "no source served ${name} with sha256 ${sha256}: ${urls//|/, }"
  tar -xzf "${tmp}/archive.tar.gz" -C "${tmp}" "${member}"
  mkdir -p "${bin_dir}"
  install -m 0755 "${tmp}/${member}" "${bin_dir}/${name}"
  printf '%s\n' "${sha256}" >"${stamp}"
  log "${name} installed to ${bin_dir}"
}

main "$@"
