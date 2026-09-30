#!/usr/bin/env bash
# Tear down the kubeadm cluster on this host so that `make deploy` can build
# it again from scratch. Installed packages, binaries and the download cache
# are kept (re-deploy is faster and still pinned by versions.env). Only state
# created by kubeadm, kubelet, Cilium and this repository is removed.
# Called by `make destroy FORCE=1`.
set -euo pipefail

readonly CRI_SOCKET="unix:///run/containerd/containerd.sock"
readonly ADMIN_CONF="/etc/kubernetes/admin.conf"
# Rendered by the kubeadm_init role; kubeadm reset leaves it behind.
readonly KUBEADM_CONFIG="/etc/kubernetes/kubeadm-config.yaml"
readonly LOCAL_PATH_DIR="/opt/local-path-provisioner"
readonly CILIUM_CNI_CONF="/etc/cni/net.d/05-cilium.conflist"
readonly CILIUM_SYSCTL_CONF="/etc/sysctl.d/99-zzz-override_cilium.conf"
readonly BPF_FS="/sys/fs/bpf"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

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

file_sha256() {
  as_root sha256sum "$1" | cut -d' ' -f1
}

# Removes ~/.kube/config of root and the invoking user, but only if it is an
# unmodified copy of this cluster's admin.conf; anything else is kept.
remove_kubeconfigs() {
  local admin_sha=$1 user home config
  for user in $(printf '%s\n' root "${SUDO_USER:-${USER:-root}}" | sort -u); do
    home="$(user_home "${user}")"
    config="${home}/.kube/config"
    if [[ -z ${home} ]] || ! as_root test -f "${config}"; then
      continue
    fi
    if [[ -n ${admin_sha} && $(file_sha256 "${config}") == "${admin_sha}" ]]; then
      as_root rm -f "${config}"
      log "Removed ${config} (copy of this cluster's admin.conf)"
    else
      warn "Kept ${config}: it is not an unmodified copy of this cluster's admin.conf"
    fi
  done
}

cleanup_cilium() {
  log "Removing Cilium state"
  # Cilium mounts a cgroup2 hierarchy under /run/cilium; unmount it first and
  # never let rm cross into another filesystem.
  if mountpoint -q /run/cilium/cgroupv2; then
    as_root umount /run/cilium/cgroupv2
  fi
  as_root rm -rf --one-file-system /run/cilium /var/lib/cilium
  as_root rm -f "${CILIUM_CNI_CONF}" "${CILIUM_SYSCTL_CONF}"
  # Pinned BPF maps survive the agent; stale ones confuse the next install.
  as_root find "${BPF_FS}/tc/globals" -maxdepth 1 -name 'cilium_*' -delete 2>/dev/null || true
  as_root rm -rf --one-file-system "${BPF_FS}/cilium"
  local link
  for link in cilium_host cilium_net cilium_vxlan; do
    if ip link show "${link}" >/dev/null 2>&1; then
      as_root ip link delete "${link}"
    fi
  done
  local backups
  backups="$(as_root find /etc/cni/net.d -maxdepth 1 -name '*.cilium_bak' 2>/dev/null || true)"
  if [[ -n ${backups} ]]; then
    warn "CNI configs renamed by Cilium are left as they are: ${backups//$'\n'/ }"
  fi
}

# Drops the chains and rules of kubelet (KUBE-*) and Cilium (CILIUM_*) in
# every iptables backend present (nft and legacy); other rules (Docker, ufw)
# stay. A backend without such rules is not touched at all.
cleanup_iptables() {
  local variant rules
  for variant in iptables-nft ip6tables-nft iptables-legacy ip6tables-legacy; do
    command -v "${variant}-save" >/dev/null 2>&1 || continue
    rules="$(as_root "${variant}-save" 2>/dev/null)" || continue
    grep -Eq 'CILIUM|KUBE-' <<<"${rules}" || continue
    log "Removing Kubernetes and Cilium rules (${variant})"
    grep -Ev 'CILIUM|KUBE-' <<<"${rules}" | as_root "${variant}-restore"
  done
}

main() {
  # Fingerprint admin.conf before kubeadm reset deletes it.
  local admin_sha=""
  if as_root test -f "${ADMIN_CONF}"; then
    admin_sha="$(file_sha256 "${ADMIN_CONF}")"
  fi

  if command -v kubeadm >/dev/null 2>&1; then
    log "kubeadm reset"
    as_root kubeadm reset --force --cri-socket "${CRI_SOCKET}"
  else
    log "kubeadm not installed, nothing to reset"
  fi
  as_root rm -f "${KUBEADM_CONFIG}"

  cleanup_cilium
  cleanup_iptables

  log "Removing local-path volumes (${LOCAL_PATH_DIR})"
  as_root rm -rf --one-file-system "${LOCAL_PATH_DIR}"

  log "Removing kubeconfig files"
  remove_kubeconfigs "${admin_sha}"

  log "Cluster removed. Run 'make deploy' to create it again."
}

main "$@"
