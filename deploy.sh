#!/usr/bin/env bash
# One-command deployment on a fresh Ubuntu 24.04 host.
#
#   ./deploy.sh                    bootstrap tooling, then `make deploy`
#   ./deploy.sh --bootstrap-only   only prepare .venv with Ansible
#
# Extra environment variables (NODE_IP, INVENTORY, ...) are passed to make.
# Safe to run repeatedly: every step checks the current state first.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR
readonly VENV_DIR="${REPO_DIR}/.venv"
readonly REQUIREMENTS="${REPO_DIR}/requirements.txt"
readonly COLLECTIONS_FILE="${REPO_DIR}/ansible/requirements.yml"
readonly COLLECTIONS_DIR="${REPO_DIR}/ansible/collections"
readonly SYSTEM_PACKAGES=(python3 python3-venv make)

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
    sudo "$@"
  fi
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

wait_for_cloud_init() {
  # On freshly created cloud VMs apt is busy until cloud-init finishes.
  if command -v cloud-init >/dev/null 2>&1; then
    log "Waiting for cloud-init to finish"
    cloud-init status --wait >/dev/null 2>&1 || true
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
    python3 -m venv "${VENV_DIR}"
  fi
  # Reinstall only when requirements.txt changes.
  local stamp="${VENV_DIR}/.requirements.sha256"
  local wanted
  wanted="$(sha256sum "${REQUIREMENTS}" | cut -d' ' -f1)"
  if [[ ! -f ${stamp} || $(<"${stamp}") != "${wanted}" ]]; then
    log "Installing pinned Python requirements"
    "${VENV_DIR}/bin/pip" install --quiet --disable-pip-version-check -r "${REQUIREMENTS}"
    printf '%s\n' "${wanted}" >"${stamp}"
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
  "${VENV_DIR}/bin/ansible-galaxy" collection install --upgrade \
    -r "${COLLECTIONS_FILE}" -p "${COLLECTIONS_DIR}" >/dev/null
}

check_sudo() {
  [[ ${EUID} -eq 0 ]] && return
  if ! sudo -n true 2>/dev/null; then
    log "sudo requires a password; Ansible will ask for it (BECOME password)"
    export ANSIBLE_BECOME_ASK_PASS=true
  fi
}

main() {
  local bootstrap_only=false
  case "${1:-}" in
    --bootstrap-only) bootstrap_only=true ;;
    "") ;;
    -h | --help)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac

  cd "${REPO_DIR}"
  check_os
  wait_for_cloud_init
  install_system_packages
  prepare_venv
  install_collections
  if [[ ${bootstrap_only} == true ]]; then
    return
  fi
  check_sudo
  log "Running make deploy"
  exec make deploy
}

main "$@"
