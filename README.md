# kubeadm + Gateway API + observability

> Черновик. Реализованы узел, кластер kubeadm, CNI, хранилище, TLS,
> Gateway API и демо-приложение. Мониторинг и логи появятся следующими
> этапами; полный README будет по готовности.

Одна команда на чистой Ubuntu 24.04 поднимает одноузловой кластер Kubernetes
(kubeadm) без kube-proxy: сеть — Cilium, StorageClass по умолчанию —
local-path-provisioner, вход — Envoy Gateway (Gateway API) с TLS от
cert-manager, за ним демо-приложение на Angie в двух версиях (canary).
Повторный запуск ничего не меняет.

## Что уже есть

| Слой | Инструмент | Что делает |
|---|---|---|
| Узел | Ansible, роль `node_prep` | пакеты, модули `overlay`/`br_netfilter`, sysctl, отключение swap |
| Рантайм | Ansible, роль `containerd` | containerd и runc из официальных релизов с проверкой sha256, конфиг целиком из шаблона |
| Kubernetes | Ansible, роли `kube_packages`, `kubeadm_init` | kubeadm/kubelet/kubectl из pkgs.k8s.io (проверка отпечатка ключа, apt pinning, hold), `kubeadm init` без kube-proxy, kubeconfig |
| Инструменты | Ansible, роль `helm_tools` | helm, helmfile, плагин helm-diff |
| Платформа | helmfile | Cilium (kube-proxy replacement, node IPAM, Hubble), local-path-provisioner |
| Namespaces | чарт `charts/namespaces` | `demo`, `gateway` и `envoy-gateway-system` с Pod Security Admission `restricted` (enforce) |
| TLS | cert-manager + чарт `charts/pki` | self-signed корень → CA `demo-ca` (ClusterIssuer) → сертификат `demo.local`, `*.demo.local` |
| Вход | Envoy Gateway (CRD Gateway API — канал standard) + чарт `charts/gateway` | Gateway `public` на IP узла: HTTP 80 → 301 на HTTPS 443; маршруты, canary, политики |
| Приложение | чарт `charts/demo-app` | Angie `web-v1` / `web-v2` по 2 реплики, JSON access-лог, метрики `/p8s` |

Все версии и контрольные суммы — в одном файле [`versions.env`](versions.env)
(`make versions` выводит их списком). Kubernetes — **1.36.5**, способ создания
кластера — **kubeadm**, протестировано на **Ubuntu 24.04.5 LTS (amd64)**.

## Требования

- Ubuntu 24.04 LTS, amd64; от 2 vCPU / 4 ГБ ОЗУ (рекомендуем 4 / 8), 20 ГБ диска;
- постоянный IP узла (статический или резервирование DHCP): kubeadm вшивает
  адрес в кластер, и если после перезагрузки узел получит другой, control
  plane не поднимется (развёртывание это распознает и подскажет, что делать);
- пользователь с `sudo` (с паролем или без);
- прямой доступ в интернет (пакеты, релизы, образы); HTTP(S)-прокси не
  поддерживается (см. «Ограничения»).

## Запуск

```bash
git clone <repo-url> && cd kubeadm-gateway-observability
./deploy.sh
```

`deploy.sh` ставит `python3-venv` и `make` (если их нет), создаёт `.venv` с
закреплённой версией ansible-core и вызывает `make deploy`. Запускать можно
от обычного пользователя (если `sudo` спросит пароль, Ansible попросит его
один раз — `BECOME password`) или целиком от root: `sudo ./deploy.sh`,
`sudo make deploy`. Способы можно чередовать: `.venv` всегда принадлежит
владельцу каталога репозитория, а не root. Учтите, что `sudo` не передаёт
переменные окружения: `sudo NODE_IP=10.0.0.5 ./deploy.sh`.

1. `make cluster` — Ansible (`ansible/site.yml`) готовит узел и поднимает кластер;
2. `make platform` — `helmfile apply` ставит платформу и приложение в порядке
   зависимостей (`needs`): Cilium → local-path-provisioner, namespaces,
   cert-manager → pki, namespaces → Envoy Gateway (перед ним — его CRD) →
   demo-app → gateway; после этого проверяется Secret для basic auth.

IP узла определяется автоматически (интерфейс маршрута по умолчанию). Если
интерфейсов несколько — задайте явно: `NODE_IP=10.0.0.5 ./deploy.sh`.
Адрес задаётся один раз, при создании кластера: kubeadm вшивает его в
сертификаты и kubeconfig. Повторные запуски берут его из существующего
кластера (`NODE_IP` можно не указывать); если `NODE_IP` указан и отличается,
развёртывание остановится с подсказкой и ничего не изменит. Сменить адрес
можно только пересозданием: `make destroy FORCE=1`, затем `./deploy.sh`.

Развёртывание на удалённый хост по SSH (только слой кластера):
`cp ansible/inventory/remote.example.yml ansible/inventory/remote.yml`,
поправить адрес, затем `make cluster INVENTORY=ansible/inventory/remote.yml`.

## Команды

| Команда | Что делает |
|---|---|
| `./deploy.sh` / `make deploy` | узел → кластер → платформа; идемпотентно |
| `make cluster` | только Ansible |
| `make platform` | только helmfile |
| `make status` | узлы, поды, релизы Helm, Gateway и сертификаты (предварительная версия) |
| `make ca` | выгрузить корневой сертификат CA в `ca.crt` (для `curl --cacert`) |
| `make destroy FORCE=1` | `kubeadm reset` и очистка следов кластера и Cilium (пакеты и бинарники остаются) |
| `make lint-deps && make lint` | shellcheck, yamllint, ansible-lint, `helm lint` своих чартов |

## Проверка

```bash
kubectl get nodes -o wide          # Ready, v1.36.5
kubectl get pods -n kube-system    # все Running
kubectl get storageclass           # local-path (default)
curl -k https://<IP узла>:6443/healthz   # ok
```

Повторный `./deploy.sh` должен завершиться с `changed=0` в итоге Ansible и
без изменений в `helmfile apply` (ревизии релизов в `helm list -A` не растут,
сертификаты и секреты не перевыпускаются).

Если `kubeadm init` когда-то прервался (следы есть — `admin.conf`, манифесты
control plane, данные etcd, — а рабочего кластера нет), развёртывание
остановится с подсказкой: автоматически такое состояние не чинится, нужен
`make destroy FORCE=1` и повторный `./deploy.sh`.

### Gateway и приложение

DNS не нужен: `curl --resolve` подставляет IP узла для имени. Сертификат
выпущен своим CA, поэтому curl нужен его корневой сертификат:

```bash
# на узле
make ca                        # пишет ./ca.crt
kubectl -n gateway get gateway public   # PROGRAMMED=True, ADDRESS=<IP узла>

# с любой машины в той же сети (ca.crt скопировать с узла, например scp)
IP=<IP узла>
curl -i http://$IP/ -H 'Host: app.demo.local'          # 301, location: https://app.demo.local/
curl --resolve app.demo.local:443:$IP --cacert ca.crt https://app.demo.local/
# Hello World! version=v1 pod=web-v1-...
```

Canary и маршрутизация:

```bash
c() { curl -sS --resolve app.demo.local:443:$IP --cacert ca.crt "$@"; }

# 200 запросов: примерно 90 % v1 и 10 % v2
for i in $(seq 200); do c https://app.demo.local/; done | awk '{print $3}' | sort | uniq -c

c https://app.demo.local/v2                     # по пути: всегда v2
c -H 'X-Canary: true' https://app.demo.local/   # по заголовку: всегда v2
```

Rate limit (путь `/limited` — 10 запросов в минуту, дальше 429; основной
маршрут ограничен 500 запросами в секунду и обычным трафиком не упирается):

```bash
for i in $(seq 20); do c -o /dev/null -w '%{http_code}\n' https://app.demo.local/limited; done | sort | uniq -c
#  10 200
#  10 429
```

Сквозной идентификатор запроса: Envoy сохраняет присланный `X-Request-ID`
(или генерирует свой) и передаёт его приложению; он есть и в access-логе
Envoy, и в access-логе Angie:

```bash
c -H 'X-Request-ID: demo-123' https://app.demo.local/
kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=public \
  -c envoy --tail=-1 | grep demo-123
kubectl -n demo logs -l app.kubernetes.io/name=demo-app --tail=-1 | grep demo-123
```

Метрики приложения (порт 9113, внутри кластера):

```bash
kubectl -n demo port-forward svc/web-v1 9113:9113 >/dev/null &
curl -s localhost:9113/p8s | grep angie_http_server_zones_requests_total
kill %1
```

## Особенности

- **Метка `node.kubernetes.io/exclude-from-external-load-balancers`.** kubeadm
  ставит её на control-plane, и Cilium node IPAM не выдаёт такому узлу адреса
  LoadBalancer. На одном узле метка снимается вместе с taint control-plane.
- **Предустановленный Docker/containerd** (например, раннер GitHub Actions):
  пакет не удаляется, но `containerd.service` переопределяется юнитом из
  `/etc/systemd/system` и запускает закреплённую версию с включённым CRI.
- **Swap** отключается сразу (`swapoff -a`) и в `/etc/fstab`.
- **Метрики control plane.** controller-manager (10257) и scheduler (10259)
  слушают IP узла, а не `0.0.0.0`: их будет собирать Prometheus, эндпоинты
  HTTPS с аутентификацией через API. Метрики etcd — по умолчанию kubeadm,
  только `127.0.0.1:2381` (без TLS, снаружи недоступны).
- **Чужой apt-репозиторий с kubeadm** (например, packages.microsoft.com на
  раннерах GitHub): пакеты `kubeadm kubelet kubectl kubernetes-cni cri-tools`
  закреплены за pkgs.k8s.io (`/etc/apt/preferences.d/kubernetes`, приоритет
  1001). Ключ репозитория принимается, только если его отпечаток совпал с
  `K8S_APT_KEY_FINGERPRINT` из `versions.env`.
- **sysctl** пишутся в `/etc/sysctl.d/zz-kubernetes.conf`: имя идёт после всех
  `99-*`, включая `99-sysctl.conf` (`/etc/sysctl.conf`), поэтому наши значения
  побеждают и после перезагрузки. Если другой файл всё же перебивает их при
  загрузке, развёртывание остановится и назовёт этот файл.
- **Резервные копии.** Существующий `~/.kube/config` и `config.toml` пакетного
  containerd перед заменой сохраняются рядом с суффиксом-датой (`config.<дата>~`).
  `make destroy` удаляет `~/.kube/config`, только если это неизменённая копия
  `admin.conf` этого кластера.
- **Адрес Gateway = IP узла.** Сервис Envoy имеет тип LoadBalancer с
  `loadBalancerClass: io.cilium/node` (Cilium node IPAM): пулы адресов не
  нужны, порты 80/443 открыты прямо на узле; NodePort не выделяются
  (`allocateLoadBalancerNodePorts: false`).
- **Где живут маршруты.** Gateway, HTTPRoute и политики — в namespace
  `gateway`, приложение — в `demo`. Доступ маршрутов к сервисам другого
  namespace разрешён явно через `ReferenceGrant` (только к нужным Service).
- **CRD.** cert-manager ставит свои CRD сам (`crds.enabled`). CRD Envoy
  Gateway и Gateway API (канал **standard**, v1.6.1) берутся из чарта
  `gateway-crds-helm` той же версии, что Envoy Gateway, и применяются
  `kubectl apply --server-side` (`scripts/apply-gateway-crds.sh`, presync-хук
  релиза `envoy-gateway`), как рекомендует документация Envoy Gateway. Так они
  обновляются вместе с контроллером (CRD из каталога `crds/` чарта Helm
  создаёт только при первой установке), а отдельный Helm-релиз невозможен:
  CRD весят ~3,7 МБ, и запись релиза превышает лимит Secret в 1 МиБ. В
  основном чарте установка CRD выключена. Релизы `pki` и `gateway`, которые
  используют CRD, идут после них (`needs`), а их первый diff выполняется без
  проверки по кластеру (`disableValidationOnInstall`) — CRD ещё нет.
- **Ретраи.** Envoy повторяет запросы независимо от метода, поэтому
  повторяются только сбои, при которых запрос гарантированно не дошёл до
  приложения (`connect-failure`, `refused-stream`, `reset-before-request`):
  так безопасно и для POST. Ответы 5xx не повторяются.
- **Basic auth для UI.** Пароль генерируется при первом деплое в Secret
  `gateway/ui-basic-auth` (`scripts/ensure-basic-auth.sh`, формат htpasswd
  `{SHA}`, как требует Envoy Gateway) и в git не попадает; существующий
  Secret не пересоздаётся, а удалённый — восстанавливается при следующем
  `make platform`. Пароль передаётся `kubectl` через stdin и не виден в
  списке процессов. Хеш `{SHA}` (SHA-1 без соли) — ограничение Envoy Gateway;
  это допустимо, потому что пароль случайный, 128 бит. Маршруты на UI
  добавляются списком `uiRoutes` в values чарта `gateway` (флаг
  `basicAuth: true` включает защиту).
- **Приложение без root.** Angie работает от пользователя образа (uid 100),
  корневая ФС только для чтения (pid и временные файлы — в emptyDir),
  capabilities сброшены, seccomp `RuntimeDefault`; порты 8080 (HTTP) и 9113
  (метрики). Ответ `Hello World! version=v1 pod=<имя пода>` задан в конфиге
  (ConfigMap на каждую версию).

## Ограничения

- **Прокси не поддерживается.** Узлу нужен прямой доступ в интернет: apt,
  релизы GitHub, Helm-репозитории и реестры образов. Переменные
  `HTTP(S)_PROXY` не прокидываются ни в containerd, ни в kubelet, ни в Ansible.
- **Один узел, IPv4, amd64.** Адрес API-сервера (IP узла) после создания
  кластера не меняется, см. «Запуск».
