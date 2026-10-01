# kubeadm + Gateway API + observability

> Черновик. Реализованы узел, кластер kubeadm, CNI, хранилище, TLS,
> Gateway API, демо-приложение, мониторинг (Prometheus, Grafana, алерты) и
> логи (Fluentd → VictoriaLogs). `make verify` и полный README — следующими
> этапами.

Одна команда на чистой Ubuntu 24.04 поднимает одноузловой кластер Kubernetes
(kubeadm) без kube-proxy: сеть — Cilium, StorageClass по умолчанию —
local-path-provisioner, вход — Envoy Gateway (Gateway API) с TLS от
cert-manager, за ним демо-приложение на Angie в двух версиях (canary).
Метрики собирает Prometheus (kube-prometheus-stack), логи контейнеров —
Fluentd (не Fluent Bit) в VictoriaLogs; смотреть — Grafana, Prometheus UI и
vmui через тот же Gateway. Повторный запуск ничего не меняет.

## Что уже есть

| Слой | Инструмент | Что делает |
|---|---|---|
| Узел | Ansible, роль `node_prep` | пакеты, модули `overlay`/`br_netfilter`, sysctl, отключение swap |
| Рантайм | Ansible, роль `containerd` | containerd и runc из официальных релизов с проверкой sha256, конфиг целиком из шаблона |
| Kubernetes | Ansible, роли `kube_packages`, `kubeadm_init` | kubeadm/kubelet/kubectl из pkgs.k8s.io (проверка отпечатка ключа, apt pinning, hold), `kubeadm init` без kube-proxy, kubeconfig |
| Инструменты | Ansible, роль `helm_tools` | helm, helmfile, плагин helm-diff |
| Платформа | helmfile | Cilium (kube-proxy replacement, node IPAM, Hubble), local-path-provisioner |
| Namespaces | чарт `charts/namespaces` | namespaces с Pod Security Admission (enforce): `restricted` везде, кроме `monitoring-node` и `logging-node` (DaemonSet-ы, которым нужен доступ к узлу, см. «Особенности») |
| TLS | cert-manager + чарт `charts/pki` | self-signed корень → CA `demo-ca` (ClusterIssuer) → сертификат `demo.local`, `*.demo.local` |
| Вход | Envoy Gateway (CRD Gateway API — канал standard) + чарт `charts/gateway` | Gateway `public` на IP узла: HTTP 80 → 301 на HTTPS 443; маршруты, canary, политики |
| Приложение | чарт `charts/demo-app` | Angie `web-v1` / `web-v2` по 2 реплики, JSON access-лог, метрики `/p8s` |
| CRD мониторинга | чарт `prometheus-operator-crds` | ServiceMonitor, PodMonitor, PrometheusRule и др. — самым первым релизом |
| Метрики | kube-prometheus-stack | Prometheus (3 дня, PVC), Alertmanager, Grafana, node-exporter, kube-state-metrics, правила и дашборды по кластеру |
| Метрики etcd | чарт `charts/etcd-metrics-proxy` | kube-rbac-proxy: TLS + токен + RBAC перед `127.0.0.1:2381` etcd |
| Логи | VictoriaLogs + чарт `charts/logging` (Fluentd) | Fluentd DaemonSet читает логи всех контейнеров, добавляет метаданные Kubernetes, шлёт в VictoriaLogs (7 дней, PVC) |
| Алерты, дашборд | чарт `charts/observability-extras` | цели Envoy и Envoy Gateway, PrometheusRule, дашборд «Demo app — golden signals», datasource VictoriaLogs |

Все версии и контрольные суммы — в одном файле [`versions.env`](versions.env)
(`make versions` выводит их списком). Kubernetes — **1.36.5**, способ создания
кластера — **kubeadm**, протестировано на **Ubuntu 24.04.5 LTS (amd64)**.

## Требования

- Ubuntu 24.04 LTS, amd64; **рекомендуем 4 vCPU / 8 ГБ ОЗУ**, 20 ГБ диска
  (на 40 ГБ после деплоя занято ~10 ГБ). Минимум — 2 vCPU / 4 ГБ: всё
  поднимается, но свободной памяти остаётся ~0,6 ГБ, и под нагрузкой
  (первый деплой) control plane может перезапуститься. Замеры через 5+ мин
  после деплоя:

  | ВМ | занято ОЗУ (`free`) | доступно | рабочий набор подов | крупнейшие |
  |---|---|---|---|---|
  | 4 vCPU / 8 ГБ | 3,5 ГБ | 4,3 ГБ | 2,7 ГБ | kube-apiserver 0,86, Grafana 0,45, Prometheus 0,3 ГБ |
  | 2 vCPU / 4 ГБ | 3,2 ГБ | 0,6 ГБ | 2,8 ГБ | то же |
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
   зависимостей (`needs`): CRD Prometheus Operator → Cilium →
   local-path-provisioner, namespaces, cert-manager → pki, Envoy Gateway
   (перед ним — его CRD) → kube-prometheus-stack, etcd-metrics-proxy,
   VictoriaLogs → Fluentd, observability-extras, demo-app → gateway; после
   этого проверяются Secret'ы с паролями (basic auth и admin Grafana).

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
| `make status` | узлы, поды, релизы Helm, Gateway, сертификаты, адреса UI и пароли (предварительная версия) |
| `make ui` | только адреса UI (Grafana, Prometheus, vmui) и пароли к ним |
| `make ca` | выгрузить корневой сертификат CA в `ca.crt` (для `curl --cacert`) |
| `make destroy FORCE=1` | `kubeadm reset` и очистка следов кластера и Cilium (пакеты и бинарники остаются) |
| `make lint-deps && make lint` | shellcheck, yamllint, ansible-lint, `helm lint` своих чартов, `promtool check rules` |

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

Метрики приложения (порт 9113, внутри кластера; зона `app` — запросы
приложения, `probes` — проверки kubelet, они в трафик не попадают):

```bash
kubectl -n demo port-forward svc/web-v1 9113:9113 >/dev/null &
curl -s localhost:9113/p8s | grep angie_http_server_zones_requests_total
kill %1
```

Отказ по запросу: `/broken` всегда отвечает 502 (Angie не может
подключиться к upstream) и пишет строку `[error]` в error-лог — так
проверяются error-логи и алерт на 5xx:

```bash
c -o /dev/null -w '%{http_code}\n' https://app.demo.local/broken   # 502
```

### Веб-интерфейсы мониторинга и логов

Все три UI опубликованы через тот же Gateway (HTTPS, сертификат демо-CA):

| UI | Адрес | Вход |
|---|---|---|
| Grafana | `https://grafana.demo.local` | своя форма входа: `admin` / пароль из Secret `monitoring/grafana-admin` |
| Prometheus | `https://prometheus.demo.local` | basic auth Gateway: `admin` / пароль из Secret `gateway/ui-basic-auth` |
| vmui (VictoriaLogs) | `https://logs.demo.local/select/vmui/` | тот же basic auth |

Пароли случайные, создаются при первом деплое, в git и в вывод деплоя не
попадают. Показать их по запросу — на узле:

```bash
make ui            # адреса и пароли
# или по отдельности
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n gateway get secret ui-basic-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Чтобы открыть UI в браузере с другой машины, добавьте в её `/etc/hosts`
строку `<IP узла> grafana.demo.local prometheus.demo.local logs.demo.local`
и импортируйте `ca.crt` (или согласитесь с предупреждением браузера). Для
curl хватает `--resolve`, как выше.

### Мониторинг (Prometheus)

kube-prometheus-stack ставит Prometheus Operator, Prometheus (интервал
сбора 30 с, хранение 3 дня, но не больше 6 ГБ, PVC 8 ГиБ на local-path),
Alertmanager (1 реплика, без внешних получателей), Grafana, node-exporter и
kube-state-metrics. Цели описаны ServiceMonitor/PodMonitor рядом с
компонентами; Prometheus берёт их из всех namespaces.

| Цель (job) | Что собирается |
|---|---|
| `envoy` (PodMonitor, `:19001/stats/prometheus`) | Envoy-прокси Gateway: запросы, коды ответов, гистограмма времени ответа по маршрутам (`envoy_cluster_upstream_rq_*`), 429 от rate limit (`envoy_http_local_rate_limit_rate_limited`) |
| `envoy-gateway` | контроллер Envoy Gateway: xDS, обновления статусов, реконсиляция |
| `web-v1`, `web-v2` (×2 пода) | Angie `/p8s`: запросы и ответы по кодам (`angie_http_server_zones_*`), метка `version` = v1/v2 |
| `apiserver`, `kubelet` (+cAdvisor, probes), `coredns` | API-сервер, узел и контейнеры (CPU, память по подам) |
| `kube-controller-manager`, `kube-scheduler` | control plane: HTTPS на IP узла, токен ServiceAccount Prometheus |
| `etcd-metrics` | etcd через kube-rbac-proxy (`<IP узла>:2382`, см. «Особенности») |
| `node-exporter`, `kube-state-metrics` | узел (CPU, память, диск, сеть) и объекты Kubernetes, в т. ч. условия Gateway (`gatewayapi_gateway_status`) |
| `cilium-agent`, `cilium-operator`, `cilium-envoy`, `hubble-metrics`, `hubble-relay-metrics` | CNI и сетевые потоки Hubble (DNS, drop, TCP, HTTP) |
| `cert-manager`, `cainjector`, `webhook` | выпуск сертификатов |
| `fluentd` | Fluentd: прочитанные записи по namespace, буфер, ретраи, ошибки вывода |
| `victoria-logs` | хранилище логов: приём, запросы, диск |
| `kube-prometheus-stack-*` | сам Prometheus, Alertmanager, Grafana, оператор |

Проверка, что цели доступны (все `up`):

```bash
P="curl -s --resolve prometheus.demo.local:443:$IP --cacert ca.crt -u admin:<пароль>"
$P https://prometheus.demo.local/api/v1/targets | jq -r '.data.activeTargets[] | [.health, .labels.job] | @tsv' | sort | uniq -c
```

Запросы PromQL (в UI Prometheus, в Grafana → Explore или через API:
`$P https://prometheus.demo.local/api/v1/query --data-urlencode 'query=<запрос>'`):

```promql
# все цели и их состояние (1 — доступна)
up
# запросы к приложению через Envoy, всего и в секунду
sum(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/.*"})
sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/.*"}[5m]))
# canary-раскладка: запросы по версиям (счётчики Angie)
sum by (version) (rate(angie_http_server_zones_requests_total{namespace="demo", zone="app"}[5m]))
# p95 времени ответа приложения, мс (гистограмма Envoy)
histogram_quantile(0.95, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/gateway/app/.*"}[5m])))
# доля 5xx и отказы rate limit (429)
sum(rate(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/gateway/app/.*", envoy_response_code_class="5"}[5m]))
sum(increase(envoy_http_local_rate_limit_rate_limited[1h]))
# Gateway запрограммирован (1 = True)
gatewayapi_gateway_status{type="Programmed"}
```

Чтобы увидеть рост счётчика: выполнить первый запрос, отправить пачку
запросов (цикл из раздела «Canary»), подождать 30 с и повторить.

**Grafana.** Дашборд **Demo app — golden signals** (папка General): запросы
в секунду, доля 5xx, p50/p95/p99 времени ответа, раскладка v1/v2, 429,
готовые реплики, CPU и память подов приложения, число строк логов
access/error и сами логи из VictoriaLogs. Рядом — стандартные дашборды
kube-prometheus-stack (узел, поды, control plane, etcd) и дашборд
VictoriaLogs. Источник данных VictoriaLogs — плагин
`victoriametrics-logs-datasource`, Grafana скачивает его с grafana.com при
старте в фоне; если сайт недоступен, Grafana всё равно запускается, а логи
остаются доступны в vmui.

**Алерты** (`charts/observability-extras`, проверяются `promtool check rules`
в `make lint`; видны в Prometheus → Alerts и в Alertmanager):

| Алерт | Условие |
|---|---|
| `AppDown` | у `web-v1` или `web-v2` нет готовых реплик 1 мин |
| `High5xxRate` | больше 5 % ответов приложения — 5xx, 5 мин (при трафике > 0,1 запроса/с) |
| `HighP95Latency` | p95 времени ответа приложения выше 0,5 с, 5 мин |
| `GatewayNotProgrammed` | у Gateway `public` условие `Programmed` не `True` (или Gateway нет), 5 мин |
| `GatewayProxyDown` | ни один Envoy-прокси не отвечает Prometheus, 2 мин |
| `FluentdDown` | Fluentd недоступен, 5 мин |
| `FluentdNoOutput` | Fluentd читает логи, но 10 мин ничего не отправил в VictoriaLogs |
| `FluentdBufferErrors`, `FluentdBufferAlmostFull` | ретраи/ошибки отправки; буфер заполнен больше чем на 80 % |
| `ControlPlaneTargetDown`, `EtcdMetricsMissing` | API-сервер, controller-manager, scheduler или etcd не отдают метрики |

Плюс стандартные правила kube-prometheus-stack (узел, поды, etcd, API-сервер
и т. д.). Демонстрация: `kubectl -n demo scale deploy/web-v1 --replicas=0`
→ через ~1,5 мин `AppDown` в состоянии firing; вернуть —
`--replicas=2`.

### Логи (Fluentd → VictoriaLogs)

**Что собирается.** Fluentd (DaemonSet, образ
`fluent/fluentd-kubernetes-daemonset`, свой `fluent.conf` из ConfigMap)
читает логи всех контейнеров узла из `/var/log/containers/*.log`, кроме
собственных:

- **access-лог Angie** (stdout, JSON): поля `method`, `uri`, `status`,
  `request_time`, `x_request_id`, `version`, `pod`… и `log_type: access`;
- **error-лог Angie** (stderr): строки `… [error] …`, поля `level`
  (`error`, `notice`, …) и `log_type: error`;
- **access-лог Envoy** (stdout, JSON): `status`, `duration_ms`,
  `upstream_host`, `route`, `x_request_id`…;
- логи остальных компонентов кластера — как есть, строкой.

**Как обрабатывается.** Формат CRI (containerd) разбирается на время, поток
(`stream`: stdout/stderr) и сообщение; строки длиннее 16 КБ, которые
containerd режет на части (`P`/`F`), склеиваются обратно. Фильтр
`kubernetes_metadata` добавляет `kubernetes.namespace_name`,
`kubernetes.pod_name`, `kubernetes.container_name`, образ, узел и метки
пода. JSON access-логов раскладывается в поля, исходная строка остаётся в
сообщении.

**Куда уходит.** Штатный плагин `out_http` → VictoriaLogs
`/insert/jsonline` (заголовки `VL-Msg-Field: message`, `VL-Time-Field:
date`, `VL-Stream-Fields`: namespace, pod, container). Буфер — файл на узле
(`/var/lib/fluentd`), сброс каждые 2 с, повтор с нарастающей паузой до
восстановления VictoriaLogs, при переполнении (256 МБ) отбрасываются самые
старые части. Запись появляется в VictoriaLogs через 5–15 с (Envoy сам
сбрасывает свой лог раз в ~10 с). VictoriaLogs хранит логи 7 дней, но не
больше 4 ГБ (PVC 5 ГиБ).

**Проверка с уникальным `X-Request-ID`** (на узле, `c` и `ca.crt` — как в
разделе «Gateway и приложение»):

```bash
RID="check-$(date +%s)"
c -H "X-Request-ID: $RID" https://app.demo.local/
sleep 15
# LogsQL через API VictoriaLogs (через Gateway, basic auth)
L="curl -s --resolve logs.demo.local:443:$IP --cacert ca.crt -u admin:<пароль>"
$L https://logs.demo.local/select/logsql/query --data-urlencode "query=x_request_id:\"$RID\"" \
  | jq -c '{_time, container: ."kubernetes.container_name", status, uri, x_request_id}'
# две записи: access-лог Angie и access-лог Envoy с этим ID
```

Ещё запросы LogsQL (в vmui или через тот же API):

```logsql
{kubernetes.namespace_name="demo"}                      # все логи приложения
{kubernetes.namespace_name="demo"} log_type:error        # только error-лог Angie
{kubernetes.namespace_name="demo"} status:>=500          # ответы 5xx
{kubernetes.container_name="envoy"} x_request_id:"<id>"  # один запрос в Envoy
{kubernetes.namespace_name="demo"} | stats by (log_type) count()
```

В Grafana те же логи — Explore → источник VictoriaLogs или нижние панели
дашборда «Demo app — golden signals».

## Особенности

- **Метка `node.kubernetes.io/exclude-from-external-load-balancers`.** kubeadm
  ставит её на control-plane, и Cilium node IPAM не выдаёт такому узлу адреса
  LoadBalancer. На одном узле метка снимается вместе с taint control-plane.
- **Предустановленный Docker/containerd** (например, раннер GitHub Actions):
  пакет не удаляется, но `containerd.service` переопределяется юнитом из
  `/etc/systemd/system` и запускает закреплённую версию с включённым CRI.
- **Swap** отключается сразу (`swapoff -a`) и в `/etc/fstab`.
- **Метрики control plane.** controller-manager (10257) и scheduler (10259)
  слушают IP узла, а не `0.0.0.0`. Prometheus ходит к ним по HTTPS со своим
  токеном ServiceAccount (компоненты проверяют его через API-сервер). Их
  серверный сертификат компонент выпускает себе сам при старте, он не
  подписан CA кластера, поэтому проверка сертификата у этих двух целей
  выключена (`insecureSkipVerify`, как по умолчанию в kube-prometheus-stack).
- **Метрики etcd через kube-rbac-proxy.** etcd отдаёт метрики по HTTP только
  на `127.0.0.1:2381` (по умолчанию kubeadm), снаружи их не видно, а
  клиентский сертификат etcd узел не покидает. На control-plane узле работает
  DaemonSet `etcd-metrics-proxy` (host network, `monitoring-node`):
  kube-rbac-proxy слушает `<IP узла>:2382` по TLS (сертификат от cert-manager,
  CA `demo-ca`), проверяет токен (TokenReview) и право `get` на
  `/metrics` (SubjectAccessReview) и только тогда проксирует запрос в
  `127.0.0.1:2381`; другие пути — 404. Prometheus ходит с токеном отдельного
  ServiceAccount `etcd-metrics-scraper`, которому разрешено только
  `get /metrics`, и проверяет сертификат прокси по CA. Без токена — 401, с
  токеном без прав — 403:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt https://$IP:2382/metrics   # 401
  ```
- **Pod Security по namespaces.** `restricted` — `demo`, `gateway`,
  `envoy-gateway-system`, `monitoring` (Prometheus, Alertmanager, Grafana,
  оператор, kube-state-metrics) и `logging` (VictoriaLogs). Компонентам уровня узла
  нужен хост, а это запрещает даже `baseline`, поэтому они вынесены в
  отдельные namespaces с `privileged`: `monitoring-node` — node-exporter
  (host network/PID, только чтение `/`, `/proc`, `/sys`) и прокси etcd (host
  network); `logging-node` — Fluentd (hostPath `/var/log` только на чтение и
  `/var/lib/fluentd` для позиций и буфера). Сами поды там без privileged и без
  добавленных capabilities.
- **Fluentd от root, но без capabilities.** Файлы логов контейнеров
  принадлежат root с правами `0640`, поэтому Fluentd работает с uid 0. Всё
  остальное закрыто: все capabilities сброшены (root без
  `CAP_DAC_OVERRIDE` читает только свои файлы — это и есть логи), запрет
  повышения привилегий, корневая ФС только для чтения, seccomp
  `RuntimeDefault`, `/var/log` смонтирован только на чтение. Права к API —
  только `get/list/watch` подов и namespaces (метаданные).
- **Порядок CRD Prometheus Operator.** ServiceMonitor есть почти у каждого
  чарта, начиная с Cilium, поэтому CRD Prometheus Operator ставятся самым
  первым релизом (`prometheus-operator-crds` той же версии, что оператор в
  kube-prometheus-stack; CRD в шаблонах чарта, значит, обновляются вместе с
  ним; запись релиза ~0,85 МБ — в лимит Secret укладывается). Ему не нужны
  поды, так что он ставится ещё до CNI; в самом kube-prometheus-stack
  установка CRD выключена. Релизы, которые используют эти CRD, делают первый
  diff без проверки по кластеру (`disableValidationOnInstall`).
- **Пароль Grafana.** Генерируется при первом деплое в Secret
  `monitoring/grafana-admin` (`scripts/ensure-grafana-admin.sh`, тем же
  способом, что пароль basic auth) и подключается в Grafana через
  `admin.existingSecret`; повторный деплой его не меняет. Prometheus и vmui
  своей аутентификации не имеют, их закрывает basic auth на Gateway; у
  Grafana — свой вход.
- **Пробы не портят метрики.** Счётчики Angie ведутся по ключу: проверки
  kubelet (`/healthz`) идут в зону `probes`, трафик приложения — в зону
  `app`, поэтому RPS и раскладка по версиям считаются без шума проб.
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
  проверки по кластеру (`disableValidationOnInstall`) — CRD ещё нет. CRD
  Prometheus Operator — см. ниже.
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
- **Плагин VictoriaLogs для Grafana** скачивается с grafana.com при каждом
  старте Grafana (она без PVC: дашборды и источники данных — из
  ConfigMap). Если сайт недоступен, панели логов в Grafana пустые, логи
  смотрятся в vmui и через API.
- **Хранилище — local-path** (каталог на узле): метрики и логи переживают
  перезапуск подов, но не потерю узла.
- **Алерты никуда не отправляются**: в Alertmanager нет получателей, алерты
  видны в UI Prometheus, Alertmanager и Grafana.
