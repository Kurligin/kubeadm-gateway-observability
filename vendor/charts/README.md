# Vendored Helm charts

Upstream charts installed by `helmfile.yaml.gotmpl`, kept as the unmodified
archives their repositories serve, so that deploying and rendering need no
chart repository (`*.github.io`, helm.cilium.io, charts.jetstack.io and
docker.io OCI are not reachable from every network).

| Archive | Chart, version | Source | License |
|---|---|---|---|
| `prometheus-operator-crds-32.0.1.tgz` | prometheus-operator-crds 32.0.1 | https://prometheus-community.github.io/helm-charts | Apache-2.0 |
| `cilium-1.20.2.tgz` | cilium 1.20.2 | https://helm.cilium.io | Apache-2.0 |
| `cert-manager-v1.21.2.tgz` | cert-manager v1.21.2 | https://charts.jetstack.io | Apache-2.0 |
| `gateway-helm-v1.9.2.tgz` | gateway-helm v1.9.2 (Envoy Gateway) | oci://docker.io/envoyproxy/gateway-helm | Apache-2.0 |
| `gateway-crds-helm-v1.9.2.tgz` | gateway-crds-helm v1.9.2 (Envoy Gateway) | oci://docker.io/envoyproxy/gateway-crds-helm | Apache-2.0 |
| `kube-prometheus-stack-91.8.2.tgz` | kube-prometheus-stack 91.8.2 | https://prometheus-community.github.io/helm-charts | Apache-2.0 |
| `victoria-logs-single-0.13.8.tgz` | victoria-logs-single 0.13.8 | https://victoriametrics.github.io/helm-charts | Apache-2.0 |
| `victoria-traces-single-0.1.11.tgz` | victoria-traces-single 0.1.11 | https://victoriametrics.github.io/helm-charts | Apache-2.0 |
| `metrics-server-3.14.0.tgz` | metrics-server 3.14.0 | https://kubernetes-sigs.github.io/metrics-server | Apache-2.0 |

All of them are licensed under the Apache License 2.0
([LICENSE-Apache-2.0.txt](LICENSE-Apache-2.0.txt)); the archives are
redistributed unchanged, with the license and notices they contain.

Versions and checksums are pinned in [`versions.env`](../../versions.env)
(`<NAME>_VERSION`, `<NAME>_CHART_SHA256`). The sha256 is that of the archive
downloaded from the source above with `helm pull` on 2026-10-02; for the
Helm repositories it equals the `digest` of the chart in the repository's
`index.yaml`. [`scripts/vendor-charts.sh`](../../scripts/vendor-charts.sh):
`check` (offline, run by `make lint` and `make platform`) compares the
archives with `versions.env`, `sha` prints the checksums of new versions,
`fetch` downloads them.
