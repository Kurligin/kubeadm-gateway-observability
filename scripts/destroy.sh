#!/usr/bin/env bash
# Tear down the kubeadm cluster on this host so that `make deploy` can build
# it again from scratch. Installed packages, binaries and the download cache
# are kept (re-deploy is faster and still pinned by versions.env).
# Called by `make destroy FORCE=1`.
set -euo pipefail

readonly CRI_SOCKET="unix:///run/containerd/containerd.sock"
readonly LOCAL_PATH_DIR="/opt/local-path-provisioner"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

main() {
  if command -v kubeadm >/dev/null 2>&1; then
    log "kubeadm reset"
    as_root kubeadm reset --force --cri-socket "${CRI_SOCKET}"
  else
    log "kubeadm not installed, nothing to reset"
  fi

  log "Removing CNI configuration and Cilium state"
  # Cilium mounts a cgroup2 hierarchy under /run/cilium; unmount it first and
  # never let rm cross into another filesystem.
  if mountpoint -q /run/cilium/cgroupv2; then
    as_root umount /run/cilium/cgroupv2
  fi
  as_root rm -rf --one-file-system /etc/cni/net.d /run/cilium /var/lib/cilium
  local link
  for link in cilium_host cilium_net cilium_vxlan; do
    if ip link show "${link}" >/dev/null 2>&1; then
      as_root ip link delete "${link}"
    fi
  done
  # Drop iptables chains created by Cilium; other rules (Docker, ufw) stay.
  local tool
  for tool in iptables ip6tables; do
    if command -v "${tool}-save" >/dev/null 2>&1; then
      as_root "${tool}-save" | grep -v -e 'CILIUM' | as_root "${tool}-restore"
    fi
  done

  log "Removing local-path volumes (${LOCAL_PATH_DIR})"
  as_root rm -rf --one-file-system "${LOCAL_PATH_DIR}"

  log "Removing kubeconfig files"
  local user home
  for user in root "${SUDO_USER:-${USER:-root}}"; do
    home="$(user_home "${user}")"
    if [[ -n ${home} ]]; then
      as_root rm -f "${home}/.kube/config"
    fi
  done

  log "Cluster removed. Run 'make deploy' to create it again."
}

main "$@"
