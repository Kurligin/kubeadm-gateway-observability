#!/usr/bin/env bash
# One-command deployment on a fresh Ubuntu 24.04 host.
#
#   ./deploy.sh                    bootstrap tooling, then `make deploy`
#   ./deploy.sh --bootstrap-only   only prepare .venv with Ansible
#
# Extra environment variables (NODE_IP, INVENTORY, ...) are passed to make.
# Behind an HTTP(S) proxy, set HTTP_PROXY / HTTPS_PROXY (and NO_PROXY if
# needed) for every run; without them nothing proxy-related is configured.
# Safe to run repeatedly: every step checks the current state first.
# Works both as a regular user with sudo and as root (`sudo ./deploy.sh`);
# the Python environment in .venv always belongs to the owner of the
# repository, so both ways can be mixed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR
readonly VENV_DIR="${REPO_DIR}/.venv"
readonly REQUIREMENTS="${REPO_DIR}/requirements.txt"
readonly COLLECTIONS_FILE="${REPO_DIR}/ansible/requirements.yml"
readonly COLLECTIONS_DIR="${REPO_DIR}/ansible/collections"
readonly SYSTEM_PACKAGES=(python3 python3-venv make)
readonly CLOUD_INIT_TIMEOUT=900
# Kept by sudo (it resets the environment otherwise).
readonly PROXY_VARS=HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo --preserve-env="${PROXY_VARS}" "$@"
  fi
}

# apt and curl read only the lower-case proxy variables, Go programs both:
# whichever spelling is set, export both.
normalize_proxy_env() {
  local http=${HTTP_PROXY:-${http_proxy:-}} https=${HTTPS_PROXY:-${https_proxy:-}}
  local no=${NO_PROXY:-${no_proxy:-}}
  [[ -n ${http}${https} ]] || return 0
  export HTTP_PROXY=${http} http_proxy=${http} HTTPS_PROXY=${https} https_proxy=${https}
  export NO_PROXY=${no} no_proxy=${no}
  # Never print a password that may be part of the proxy URL.
  log "Using the HTTP(S) proxy $(sed -E 's#//[^/@]*@#//***@#' <<<"${https:-${http}}")"
}

check_os() {
  [[ -r /etc/os-release ]] || die "cannot detect the operating system (/etc/os-release missing)"
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} == "ubuntu" ]] || die "Ubuntu is required, found '${ID:-unknown}'"
  if [[ ${VERSION_ID:-} != "24.04" ]]; then
    warn "tested on Ubuntu 24.04, this host runs ${VERSION_ID:-unknown}"
  fi
  [[ $(uname -m) == "x86_64" ]] || die "only x86_64 (amd64) is supported, found $(uname -m)"
}

# Runs a command as the owner of the repository: when invoked as root via
# sudo, files in .venv and ansible/collections must not become root-owned.
as_repo_owner() {
  local owner
  owner="$(stat -c %U "${REPO_DIR}")"
  if [[ ${EUID} -eq 0 && ${owner} != "root" ]]; then
    sudo -H --preserve-env="${PROXY_VARS}" -u "${owner}" -- "$@"
  else
    "$@"
  fi
}

wait_for_cloud_init() {
  # On freshly created cloud VMs apt is busy until cloud-init finishes.
  command -v cloud-init >/dev/null 2>&1 || return 0
  log "Waiting for cloud-init to finish (up to $((CLOUD_INIT_TIMEOUT / 60)) min)"
  local rc=0
  timeout "${CLOUD_INIT_TIMEOUT}" cloud-init status --wait >/dev/null 2>&1 || rc=$?
  # 1 and 2 mean cloud-init finished with errors, which is not our concern.
  if [[ ${rc} -eq 124 ]]; then
    warn "cloud-init is still running after $((CLOUD_INIT_TIMEOUT / 60)) min" \
      "(see 'cloud-init status --long'); continuing, apt waits for its lock up to 10 min"
  fi
}

install_system_packages() {
  local missing=()
  local pkg
  for pkg in "${SYSTEM_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
      missing+=("${pkg}")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log "System packages already present: ${SYSTEM_PACKAGES[*]}"
    return
  fi
  log "Installing system packages: ${missing[*]}"
  as_root apt-get -o DPkg::Lock::Timeout=600 update -qq
  as_root env DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout=600 install -y -qq --no-install-recommends "${missing[@]}"
}

prepare_venv() {
  if [[ ! -x ${VENV_DIR}/bin/python ]]; then
    log "Creating Python virtual environment in .venv"
    as_repo_owner python3 -m venv "${VENV_DIR}"
  fi
  # Reinstall only when requirements.txt changes.
  local stamp="${VENV_DIR}/.requirements.sha256"
  local wanted
  wanted="$(sha256sum "${REQUIREMENTS}" | cut -d' ' -f1)"
  if [[ ! -f ${stamp} || $(<"${stamp}") != "${wanted}" ]]; then
    log "Installing pinned Python requirements"
    as_repo_owner "${VENV_DIR}/bin/pip" install --quiet --disable-pip-version-check -r "${REQUIREMENTS}"
    printf '%s\n' "${wanted}" | as_repo_owner tee "${stamp}" >/dev/null
  else
    log "Python requirements up to date ($("${VENV_DIR}/bin/ansible" --version | head -n1))"
  fi
}

install_collections() {
  # Skip Galaxy entirely when no collections are declared.
  if ! grep -Eq '^[[:space:]]*-[[:space:]]*(name:)?[[:space:]]*[a-z0-9_]+\.[a-z0-9_]+' "${COLLECTIONS_FILE}"; then
    log "No Ansible collections required"
    return
  fi
  log "Installing pinned Ansible collections"
  as_repo_owner "${VENV_DIR}/bin/ansible-galaxy" collection install --upgrade \
    -r "${COLLECTIONS_FILE}" -p "${COLLECTIONS_DIR}" >/dev/null
}

main() {
  local bootstrap_only=false
  case "${1:-}" in
    --bootstrap-only) bootstrap_only=true ;;
    "") ;;
    -h | --help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac

  cd "${REPO_DIR}"
  check_os
  normalize_proxy_env
  wait_for_cloud_init
  install_system_packages
  prepare_venv
  install_collections
  if [[ ${bootstrap_only} == true ]]; then
    return
  fi
  # `make cluster` asks for the sudo password itself if one is needed.
  log "Running make deploy"
  exec make deploy
}

main "$@"
