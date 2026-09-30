# kubeadm + Gateway API + observability

> Черновик. Сейчас реализован базовый слой: узел, кластер kubeadm, CNI и
> хранилище. Gateway API, приложение, мониторинг и логи появятся следующими
> этапами; полный README будет по готовности.

Одна команда на чистой Ubuntu 24.04 поднимает одноузловой кластер Kubernetes
(kubeadm) без kube-proxy: сеть — Cilium, StorageClass по умолчанию —
local-path-provisioner. Повторный запуск ничего не меняет.

## Что уже есть

| Слой | Инструмент | Что делает |
|---|---|---|
| Узел | Ansible, роль `node_prep` | пакеты, модули `overlay`/`br_netfilter`, sysctl, отключение swap |
| Рантайм | Ansible, роль `containerd` | containerd и runc из официальных релизов с проверкой sha256, конфиг целиком из шаблона |
| Kubernetes | Ansible, роли `kube_packages`, `kubeadm_init` | kubeadm/kubelet/kubectl из pkgs.k8s.io (hold), `kubeadm init` без kube-proxy, kubeconfig |
| Инструменты | Ansible, роль `helm_tools` | helm, helmfile, плагин helm-diff |
| Платформа | helmfile | Cilium (kube-proxy replacement, node IPAM, Hubble), local-path-provisioner |

Все версии и контрольные суммы — в одном файле [`versions.env`](versions.env)
(`make versions` выводит их списком). Kubernetes — **1.36.5**, способ создания
кластера — **kubeadm**, протестировано на **Ubuntu 24.04.5 LTS (amd64)**.

## Требования

- Ubuntu 24.04 LTS, amd64; от 2 vCPU / 4 ГБ ОЗУ (рекомендуем 4 / 8), 20 ГБ диска;
- доступ в интернет (пакеты, релизы, образы);
- пользователь с `sudo`.

## Запуск

```bash
git clone <repo-url> && cd kubeadm-gateway-observability
./deploy.sh
```

`deploy.sh` ставит `python3-venv` и `make` (если их нет), создаёт `.venv` с
закреплённой версией ansible-core и вызывает `make deploy`:

1. `make cluster` — Ansible (`ansible/site.yml`) готовит узел и поднимает кластер;
2. `make platform` — `helmfile apply` ставит Cilium и local-path-provisioner.

IP узла определяется автоматически (интерфейс маршрута по умолчанию). Если
интерфейсов несколько — задайте явно: `NODE_IP=10.0.0.5 ./deploy.sh`.

Развёртывание на удалённый хост по SSH (только слой кластера):
`cp ansible/inventory/remote.example.yml ansible/inventory/remote.yml`,
поправить адрес, затем `make cluster INVENTORY=ansible/inventory/remote.yml`.

## Команды

| Команда | Что делает |
|---|---|
| `./deploy.sh` / `make deploy` | узел → кластер → платформа; идемпотентно |
| `make cluster` | только Ansible |
| `make platform` | только helmfile |
| `make status` | узлы, поды, релизы Helm (предварительная версия) |
| `make destroy FORCE=1` | `kubeadm reset` и очистка (пакеты и бинарники остаются) |
| `make lint-deps && make lint` | shellcheck, yamllint, ansible-lint |

## Проверка

```bash
kubectl get nodes -o wide          # Ready, v1.36.5
kubectl get pods -n kube-system    # все Running
kubectl get storageclass           # local-path (default)
curl -k https://<IP узла>:6443/healthz   # ok
```

Повторный `./deploy.sh` должен завершиться с `changed=0` в итоге Ansible и
без изменений в `helmfile apply`.

## Особенности

- **Метка `node.kubernetes.io/exclude-from-external-load-balancers`.** kubeadm
  ставит её на control-plane, и Cilium node IPAM не выдаёт такому узлу адреса
  LoadBalancer. На одном узле метка снимается вместе с taint control-plane.
- **Предустановленный Docker/containerd** (например, раннер GitHub Actions):
  пакет не удаляется, но `containerd.service` переопределяется юнитом из
  `/etc/systemd/system` и запускает закреплённую версию с включённым CRI.
- **Swap** отключается сразу (`swapoff -a`) и в `/etc/fstab`.
- Метрики controller-manager, scheduler и etcd слушают `0.0.0.0` — их будет
  собирать Prometheus.
