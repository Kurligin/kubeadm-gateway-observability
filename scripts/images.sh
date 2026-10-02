#!/usr/bin/env bash
# Container images of the platform: list, check and pre-pull.
#
#   scripts/images.sh list <python>          images to pre-pull, rendered from helmfile
#   scripts/images.sh check <python> <file>  every rendered image is pinned by
#                                            digest and <file> is up to date
#   scripts/images.sh pull <file>            pull the images listed in <file> (and
#                                            the kubeadm control plane images) into
#                                            containerd on this node
#
# list/check render every release with `helmfile template` offline: no
# cluster is needed (the API server address is a placeholder), only the
# chart repositories. <python> is an interpreter with PyYAML (make passes the
# one from .venv). pull needs root (asks sudo) and is safe to repeat: images
# already present are skipped. Called by `make images-list`, `make lint` and
# `make images`.
set -euo pipefail

readonly CONTAINERD_NAMESPACE=k8s.io
readonly PULL_ATTEMPTS=3
# Address used to render without a cluster (TEST-NET-1, never contacted).
readonly PLACEHOLDER_NODE_IP=192.0.2.10

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    # Keep the proxy settings: sudo drops the environment otherwise.
    sudo --preserve-env=HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy "$@"
  fi
}

render() {
  command -v helmfile >/dev/null || die "helmfile not found (make cluster installs it)"
  local errors
  errors="$(mktemp)"
  # KUBECONFIG=/dev/null: never look at a real cluster. TRACING=true: the
  # optional tracing releases are rendered (and checked) too.
  if ! KUBECONFIG=/dev/null NODE_IP=${PLACEHOLDER_NODE_IP} TRACING=true \
    helmfile --quiet --file helmfile.yaml.gotmpl template 2>"${errors}"; then
    cat "${errors}" >&2
    rm -f "${errors}"
    die "helmfile template failed"
  fi
  rm -f "${errors}"
}

pull_one() {
  local image=$1 attempt
  if [[ -n "$(as_root ctr --namespace "${CONTAINERD_NAMESPACE}" images list --quiet "name==${image}")" ]]; then
    log "present: ${image}"
    return
  fi
  for attempt in $(seq "${PULL_ATTEMPTS}"); do
    log "pulling ${image} (attempt ${attempt}/${PULL_ATTEMPTS})"
    if as_root ctr --namespace "${CONTAINERD_NAMESPACE}" images pull --platform linux/amd64 "${image}" >/dev/null; then
      return
    fi
    sleep 5
  done
  die "could not pull ${image}"
}

pull() {
  local file=$1 image
  [[ -r ${file} ]] || die "image list not found: ${file}"
  command -v ctr >/dev/null || die "ctr not found: run 'make cluster' first (installs containerd)"
  local count=0
  while read -r image; do
    [[ -z ${image} || ${image} == \#* ]] && continue
    pull_one "${image}"
    count=$((count + 1))
  done <"${file}"
  log "${count} images from ${file} are in containerd"
  # Control plane images by tag, as kubeadm references them (kubeadm has no
  # digest pinning); kube-proxy is not used (Cilium replaces it).
  if command -v kubeadm >/dev/null; then
    log "kubeadm control plane images (Kubernetes v${K8S_VERSION:?})"
    count=0
    while read -r image; do
      [[ ${image} == */kube-proxy:* ]] && continue
      pull_one "${image}"
      count=$((count + 1))
    done < <(kubeadm config images list --kubernetes-version "v${K8S_VERSION}" 2>/dev/null)
    [[ ${count} -gt 0 ]] || die "kubeadm config images list returned nothing"
  fi
}

main() {
  local cmd=${1:-}
  case ${cmd} in
    list)
      [[ $# -eq 2 ]] || die "usage: $0 list <python>"
      render | "$2" scripts/images.py list
      ;;
    check)
      [[ $# -eq 3 ]] || die "usage: $0 check <python> <file>"
      render | "$2" scripts/images.py check "$3"
      ;;
    pull)
      [[ $# -eq 2 ]] || die "usage: $0 pull <file>"
      pull "$2"
      ;;
    *) die "usage: $0 list|check|pull ... (see the header of $0)" ;;
  esac
}

main "$@"
