# kubeadm + Gateway API + observability

> Черновик README. Реализованы узел, кластер kubeadm, CNI, хранилище, TLS,
> Gateway API, демо-приложение, мониторинг (Prometheus, Grafana, алерты),
> логи (Fluentd → VictoriaLogs), политики безопасности и сквозная проверка
> `make verify`. Итоговая документация — следующим этапом.

Одна команда на чистой Ubuntu 24.04 поднимает одноузловой кластер Kubernetes
(kubeadm) без kube-proxy: сеть — Cilium, StorageClass по умолчанию —
local-path-provisioner, вход — Envoy Gateway (Gateway API) с TLS от
cert-manager, за ним демо-приложение на Angie в двух версиях (canary).
Метрики собирает Prometheus (kube-prometheus-stack), логи контейнеров —
Fluentd (не Fluent Bit) в VictoriaLogs; смотреть — Grafana, Prometheus UI и
vmui через тот же Gateway. Повторный запуск ничего не меняет, `make verify`
одной командой проверяет всё это сквозными запросами.

## Что уже есть

| Слой | Инструмент | Что делает |
|---|---|---|
| Узел | Ansible, роль `node_prep` | пакеты, модули `overlay`/`br_netfilter`, sysctl, отключение swap |
| Рантайм | Ansible, роль `containerd` | containerd и runc из официальных релизов с проверкой sha256, конфиг целиком из шаблона |
| Kubernetes | Ansible, роли `kube_packages`, `kubeadm_init` | kubeadm/kubelet/kubectl из pkgs.k8s.io (проверка отпечатка ключа, apt pinning, hold), `kubeadm init` без kube-proxy, kubeconfig |
| Инструменты | Ansible, роль `helm_tools` | helm, helmfile, плагин helm-diff |
| Платформа | helmfile | Cilium (kube-proxy replacement, node IPAM, Hubble), local-path-provisioner |
| Namespaces | чарт `charts/namespaces` | namespaces с Pod Security Admission (enforce): `restricted` везде, кроме `monitoring-node`, `logging-node` и `local-path-storage` (поды, которым нужен доступ к узлу, см. «Особенности») |
| Сетевые политики | чарт `charts/network-policies` + NetworkPolicy в `charts/demo-app` | во всех наших namespaces входящий трафик запрещён по умолчанию, разрешено только нужное (см. «Особенности») |
| Порты метрик на узле | Ansible, роль `node_firewall` | nftables: порты метрик Cilium и node-exporter доступны только с самого узла и из сети подов |
| TLS | cert-manager + чарт `charts/pki` | self-signed корень → CA `demo-ca` (ClusterIssuer) → сертификат `demo.local`, `*.demo.local` |
| Вход | Envoy Gateway (CRD Gateway API — канал standard) + чарт `charts/gateway` | Gateway `public` на IP узла: HTTP 80 → 301 на HTTPS 443; маршруты, canary, политики |
| UI | чарт `charts/ui-routes` | маршруты к Grafana, Prometheus, Alertmanager и vmui на том же Gateway, basic auth, только нужные методы и пути |
| Приложение | чарт `charts/demo-app` | Angie `web-v1` / `web-v2` по 2 реплики, JSON access-лог, метрики `/p8s` |
| CRD мониторинга | чарт `prometheus-operator-crds` | ServiceMonitor, PodMonitor, PrometheusRule и др. — самым первым релизом |
| Метрики | kube-prometheus-stack | Prometheus (3 дня, PVC), Alertmanager, Grafana, node-exporter (за kube-rbac-proxy), kube-state-metrics, правила и дашборды по кластеру |
| Метрики etcd | чарт `charts/etcd-metrics-proxy` | kube-rbac-proxy: TLS + токен + RBAC перед `127.0.0.1:2381` etcd |
| Логи | VictoriaLogs + чарт `charts/logging` (Fluentd) | Fluentd DaemonSet читает логи всех контейнеров, добавляет метаданные Kubernetes, шлёт в VictoriaLogs (7 дней, PVC) |
| Алерты, дашборд | чарт `charts/observability-extras` | цели Envoy и Envoy Gateway, PrometheusRule, дашборд «Demo app — golden signals», datasource VictoriaLogs |

Все версии и контрольные суммы — в одном файле [`versions.env`](versions.env)
(`make versions` выводит их списком). Kubernetes — **1.36.5**, способ создания
кластера — **kubeadm**, протестировано на **Ubuntu 24.04.5 LTS (amd64)**.

## Требования

- Ubuntu 24.04 LTS, amd64; **рекомендуем 4 vCPU / 8 ГБ ОЗУ и 30 ГБ
  диска**. Минимум — 2 vCPU / 4 ГБ и 20 ГБ: всё поднимается, но запаса мало
  (см. замеры ниже).
- Память (замер через 5+ мин после деплоя):

  | ВМ | занято ОЗУ (`free`) | доступно | рабочий набор подов | крупнейшие |
  |---|---|---|---|---|
  | 4 vCPU / 8 ГБ | 3,4 ГБ | 4,6 ГБ | 2,7 ГБ | kube-apiserver 0,86, Grafana 0,45, Prometheus 0,3 ГБ |
  | 2 vCPU / 4 ГБ | 3,2 ГБ | 0,65 ГБ | 2,8 ГБ | kube-apiserver 0,82, Prometheus 0,29, Grafana 0,21 ГБ (RSS) |

  На 2 vCPU / 4 ГБ под нагрузкой (первый деплой) control plane может
  перезапуститься — развёртывание это переживает.
- Диск. Сразу после деплоя занято ~9,7 ГБ (Ubuntu 2,3 ГБ, образы
  контейнеров 6 ГБ, остальное — etcd, kubelet, кэши). Дальше растут только
  данные, и у каждого есть потолок:

  | Что | Потолок |
  |---|---|
  | метрики Prometheus | 3 ГБ (`retentionSize`) + WAL ~0,5 ГБ |
  | логи в VictoriaLogs | 2 ГБ (`retentionDiskSpaceUsage`) |
  | буфер Fluentd | 256 МБ |
  | логи контейнеров на узле | ротация kubelet (10 МБ × 5 файлов на контейнер, старые сжаты), на практике < 0,5 ГБ |

  Итого пик ~16 ГБ. На диске 20 ГБ это ~80 %: чуть ниже порога, с
  которого kubelet начинает удалять образы (85 %), поэтому 20 ГБ — минимум,
  а с запасом — 30 ГБ.
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
   зависимостей (`needs`): CRD Prometheus Operator → Cilium → namespaces →
   сетевые политики, local-path-provisioner, cert-manager → pki, Envoy
   Gateway (перед ним — его CRD); demo-app → gateway (приложение доступно,
   даже если дальше что-то не встанет); observability-extras →
   kube-prometheus-stack, etcd-metrics-proxy, VictoriaLogs → Fluentd; в
   конце — ui-routes. После этого проверяются Secret'ы с паролями (basic
   auth и admin Grafana). Репозитории чартов загружаются заранее, с
   повторами при сбое сети; первая установка не печатает diff (десятки тысяч строк:
   все манифесты платформы), повторные — печатают только изменения.

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
| `make verify` | сквозная проверка: таблица ✓/✗ с причинами, код возврата ≠ 0 при провале |
| `make cluster` | только Ansible |
| `make platform` | только helmfile |
| `make status` | узел и версии, адрес Gateway, ссылки UI, релизы Helm, краткое здоровье (без паролей) |
| `make ui` | адреса UI (Grafana, Prometheus, Alertmanager, vmui) и пароли к ним |
| `make ca` | выгрузить корневой сертификат CA в `ca.crt` (для `curl --cacert`) |
| `make destroy FORCE=1` | `kubeadm reset` и очистка следов кластера и Cilium (пакеты и бинарники остаются) |
| `make lint-deps && make lint` | shellcheck, yamllint, ansible-lint, `helm lint` своих чартов, `promtool check rules` |

## Проверка

### Одной командой: `make verify`

```bash
make verify        # на узле: адрес, CA и пароль берутся из кластера
```

Скрипт `scripts/verify.sh` проходит те же 8 шагов, что описаны ниже для
ручной проверки, и печатает строку на каждую проверку: `✓` — прошла, `✗` —
нет (с причиной), `-` — пропущена (с причиной). В конце — итог и код
возврата: `0`, если провалов нет, иначе `1`. Сразу после деплоя не всё
готово мгновенно (цели Prometheus появляются через 1–2 интервала сбора),
поэтому такие проверки повторяются до 5 минут (`WAIT=<секунды>`), а
запись в логах ищется до 45 с.

| Шаг | Что проверяется |
|---|---|
| 1 | узел `Ready`; все поды `Running` и готовы (перезапуски — не провал); все релизы Helm `deployed` |
| 2 | Gateway `public`: `Programmed=True`, адрес = IP узла |
| 3 | `http://` → 301 на `https://`; `https://app.demo.local/` → 200 и `Hello World!` (сертификат проверяется по CA кластера) |
| 4 | 200 запросов: доля v2 в коридоре 5–20 % (вес 10 %); `/v2` и `X-Canary: true` → всегда v2 |
| 5 | `/limited`: из 15 запросов не больше 10 успешных и хотя бы один 429 от rate limit Envoy (заголовок `x-ratelimit-limit: 10`); основной маршрут при этом отвечает 200 |
| 6 | запрос с уникальным `X-Request-ID` → запись с этим ID в VictoriaLogs и в access-логе Angie, и в access-логе Envoy (LogsQL через API) |
| 7 | Prometheus: ключевые цели (API-сервер, kubelet, controller-manager, scheduler, etcd, CoreDNS, node-exporter, kube-state-metrics, Cilium, Envoy, Envoy Gateway, web-v1/v2, Fluentd, VictoriaLogs) в состоянии `up` по API целей (`/api/v1/targets`: сразу после перезагрузки ряды `up` ещё содержат старые точки); счётчик запросов Envoy вырос на трафик шагов 3–6; PromQL по метрикам Angie (запросы по версиям) |
| 8 | Prometheus и логи без пароля → 401; `POST /-/quit` и `/insert` даже с паролем через Gateway не проходят (404); etcd `:2381` снаружи недоступен; прокси метрик etcd и node-exporter без токена → 401 или соединение сброшено; метрики Cilium `:9962` закрыты для локальной сети (проверяется только с другой машины) |

Повторный запуск в течение минуты корректен: rate limit `/limited`
считается поминутно, и если лимит ещё исчерпан прошлым запуском, все 15
запросов получат 429 — это тоже работа лимита (успешных не больше 10),
а 429 «не от лимита» (без заголовка `x-ratelimit-limit`) засчитывается как
провал.

**С другой машины** (без kubectl) — те же проверки, кроме уровня кластера
(шаги 1–2 будут пропущены). Нужны `curl`, `jq`, CA и пароль basic auth с
узла. Если на вашей машине есть kubectl, скрипт пользуется им, только когда
текущий контекст смотрит в этот кластер (адрес API-сервера = `GATEWAY_IP`):

```bash
# на узле
make ca && make ui           # ca.crt и пароль
# на своей машине (ca.crt скопировать, например, scp)
GATEWAY_IP=<IP узла> CA_FILE=ca.crt UI_PASSWORD=<пароль> ./scripts/verify.sh
```

### Руками, по шагам

Те же проверки, что делает `make verify`. Шаги 3–8 можно выполнять и с
другой машины (нужны `ca.crt` и пароль, см. выше).

**1. Кластер.**

```bash
kubectl get nodes -o wide          # Ready, v1.36.5
kubectl get pods -A                # все Running и READY n/n (или Completed у Job)
helm list -A                       # все STATUS deployed
kubectl get storageclass           # local-path (default)
```

**2. Gateway.**

```bash
kubectl -n gateway get gateway public   # PROGRAMMED True, ADDRESS = IP узла
```

Повторный `./deploy.sh` должен завершиться с `changed=0` в итоге Ansible и
без изменений в `helmfile apply` (ревизии релизов в `helm list -A` не растут,
сертификаты и секреты не перевыпускаются).

Если `kubeadm init` когда-то прервался (следы есть — `admin.conf`, манифесты
control plane, данные etcd, — а рабочего кластера нет), развёртывание
остановится с подсказкой: автоматически такое состояние не чинится, нужен
`make destroy FORCE=1` и повторный `./deploy.sh`.

### Gateway и приложение (шаги 3–6)

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

Все UI опубликованы через тот же Gateway (HTTPS, сертификат демо-CA),
маршруты — в чарте `charts/ui-routes`:

| UI | Адрес | Вход | Что пропускает Gateway |
|---|---|---|---|
| Grafana | `https://grafana.demo.local` | своя форма входа: `admin` / пароль из Secret `monitoring/grafana-admin` | всё |
| Prometheus | `https://prometheus.demo.local` | basic auth Gateway: `admin` / пароль из Secret `gateway/ui-basic-auth` | `GET`, `HEAD`, `POST /api/v1/*` (запросы) |
| Alertmanager | `https://alertmanager.demo.local` | тот же basic auth | `GET`, `HEAD`, создание и удаление silence |
| vmui (VictoriaLogs) | `https://logs.demo.local/select/vmui/` | тот же basic auth | только `/select/*` (vmui и LogsQL API) |

У Prometheus, Alertmanager и VictoriaLogs своей аутентификации нет, поэтому
наружу открыто только чтение: служебные `POST /-/reload`, `/-/quit` и
приём логов `/insert/*` через Gateway недоступны даже с паролем (Envoy
отвечает 404, запрос до сервиса не доходит). Внутри кластера к ним тоже
нельзя обратиться из чужих namespaces — см. «Сетевые политики».

Пароли случайные, создаются при первом деплое, в git и в вывод деплоя не
попадают. Показать их по запросу — на узле:

```bash
make ui            # адреса и пароли
# или по отдельности
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n gateway get secret ui-basic-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Чтобы открыть UI в браузере с другой машины, добавьте в её `/etc/hosts`
строку `<IP узла> app.demo.local grafana.demo.local prometheus.demo.local alertmanager.demo.local logs.demo.local`
и импортируйте `ca.crt` (или согласитесь с предупреждением браузера). Для
curl хватает `--resolve`, как выше.

### Мониторинг (Prometheus, шаг 7)

kube-prometheus-stack ставит Prometheus Operator, Prometheus (интервал
сбора 30 с, хранение 3 дня, но не больше 3 ГБ, PVC 4 ГиБ на local-path),
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
| `node-exporter`, `kube-state-metrics` | узел (CPU, память, диск, сеть; HTTPS через kube-rbac-proxy, см. «Особенности») и объекты Kubernetes, в т. ч. условия Gateway (`gatewayapi_gateway_status`) |
| `cilium-agent`, `cilium-operator`, `cilium-envoy`, `hubble-metrics`, `hubble-relay-metrics` | CNI и сетевые потоки Hubble (DNS, drop, TCP, HTTP) |
| `cert-manager`, `cainjector`, `webhook` | выпуск сертификатов |
| `fluentd` | Fluentd: прочитанные записи по namespace пода (метка `kube_namespace`: `namespace` у цели уже занят — это namespace самого Fluentd), буфер, ретраи, ошибки вывода |
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
| `FluentdDown`, `FluentdMissing` | под Fluentd не отвечает 5 мин; целей Fluentd нет совсем 5 мин |
| `FluentdNoOutput` | Fluentd читает логи, а VictoriaLogs 5 мин не принимает ни одной строки (`vl_rows_ingested_total` не растёт или VictoriaLogs недоступна) — судим по принимающей стороне: счётчик записей Fluentd растёт и на неудачных попытках |
| `FluentdBufferErrors`, `FluentdBufferAlmostFull` | ретраи/ошибки отправки; буфер заполнен больше чем на 80 % |
| `EtcdMetricsMissing` | метрики etcd (через прокси) не собираются 5 мин |

Плюс стандартные правила kube-prometheus-stack (узел, поды, etcd, API-сервер,
controller-manager, scheduler — `KubeAPIDown`, `KubeControllerManagerDown`,
`KubeSchedulerDown`, `TargetDown` и т. д.). Демонстрация:

- `kubectl -n demo scale deploy/web-v1 --replicas=0` → через ~1,5 мин
  `AppDown` в состоянии firing; вернуть — `--replicas=2`;
- `kubectl -n logging scale statefulset/victoria-logs --replicas=0` →
  `FluentdNoOutput` pending в пределах минуты, через 5 мин firing;
  вернуть — `--replicas=1`: через 1–2 мин алерт снимается, а логи за время
  простоя дозагружаются из буфера Fluentd (запрос, отправленный во время
  простоя, находится по своему `X-Request-ID`).

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
сообщении; временем записи становится время запроса из самого лога (поле
`time`: у Angie — `$time_iso8601`, у Envoy — `%START_TIME%`), у остальных
строк — время записи containerd.

**Куда уходит.** Штатный плагин `out_http` → VictoriaLogs
`/insert/jsonline` (заголовки `VL-Msg-Field: message`, `VL-Time-Field:
date`, `VL-Stream-Fields`: namespace, pod, container). Буфер — файл на узле
(`/var/lib/fluentd`), сброс каждые 2 с, повтор с нарастающей паузой до
восстановления VictoriaLogs, при переполнении (256 МБ) отбрасываются самые
старые части; пачку, которую VictoriaLogs отвергла насовсем (4xx), Fluentd
отбрасывает с предупреждением в своём логе, а не копит в каталоге резервных
копий (`disable_chunk_backup`). Запись появляется в VictoriaLogs через
5–15 с (Envoy сам сбрасывает свой лог раз в ~10 с). VictoriaLogs хранит
логи 7 дней, но не больше 2 ГБ (PVC 3 ГиБ).

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

### Безопасность (шаг 8)

```bash
# без пароля — 401
curl -s -o /dev/null -w '%{http_code}\n' --resolve prometheus.demo.local:443:$IP --cacert ca.crt https://prometheus.demo.local/
curl -s -o /dev/null -w '%{http_code}\n' --resolve logs.demo.local:443:$IP --cacert ca.crt https://logs.demo.local/select/vmui/
# служебные и пишущие пути через Gateway не проходят даже с паролем — 404
curl -s -o /dev/null -w '%{http_code}\n' -u admin:<пароль> -X POST --resolve prometheus.demo.local:443:$IP --cacert ca.crt https://prometheus.demo.local/-/quit
curl -s -o /dev/null -w '%{http_code}\n' -u admin:<пароль> -X POST --resolve logs.demo.local:443:$IP --cacert ca.crt https://logs.demo.local/insert/jsonline
# etcd :2381 снаружи не слушает; прокси метрик etcd без токена — 401
curl -m 5 http://$IP:2381/metrics                                   # Connection refused
curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt https://$IP:2382/metrics
# node-exporter и метрики Cilium с другой машины закрыты (на узле: 9100 -> 401)
curl -m 5 -k https://$IP:9100/metrics                               # Connection refused
curl -m 5 http://$IP:9962/metrics                                   # Connection refused
```

Сетевые политики изнутри кластера (под в `demo` не достаёт до Prometheus и
VictoriaLogs, а через Gateway приложение доступно):

```bash
kubectl -n demo run np-check --rm -i --restart=Never --image=docker.io/curlimages/curl:8.16.0 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"np-check","image":"docker.io/curlimages/curl:8.16.0","args":["-sS","-m","5","-X","POST","http://kube-prometheus-stack-prometheus.monitoring:9090/-/quit"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# curl: (28) Connection timed out — пакеты отброшены политикой
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
  `127.0.0.1:2381`; другие пути — 404. Проверяется не общее право
  `get /metrics` (оно есть у любого, кто читает метрики, и открывает заодно
  метрики API-сервера), а узкое: `get` подресурса `services/metrics` у
  Service `monitoring-node/etcd-metrics` (`--config-file`,
  `authorization.resourceAttributes`). Это право Role выдаёт только
  ServiceAccount Prometheus. Prometheus предъявляет свой собственный токен —
  проецируемый, короткоживущий, его ротирует kubelet (`bearerTokenFile` в
  ServiceMonitor), а не долгоживущий токен из Secret; сертификат прокси
  проверяется по CA. Без токена — 401, с токеном без этого права — 403:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt https://$IP:2382/metrics   # 401
  T=$(kubectl -n demo create token default)
  curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt -H "Authorization: Bearer $T" https://$IP:2382/metrics   # 403
  ```

  Пробы прокси — HTTPS `/healthz` на отдельном порту 2383
  (`--proxy-endpoints-port`): TCP-проба на основной порт засоряла бы лог
  ошибками TLS handshake.
- **node-exporter за kube-rbac-proxy.** Сам node-exporter слушает только
  `127.0.0.1`, а порт узла 9100 обслуживает kube-rbac-proxy: TLS (сертификат
  от cert-manager), токен и то же узкое право (`get services/<имя>` у своего
  Service), выданное только Prometheus. Контейнеры — без capabilities, без
  повышения привилегий, seccomp `RuntimeDefault`. Без токена — 401.
- **Порты метрик на узле закрыты для сети.** Компоненты с host network слушают
  все адреса узла: Cilium — 9962 (cilium-agent), 9963 (оператор), 9964 (его Envoy),
  9965 (Hubble), без аутентификации; node-exporter — 9100 и 8888 (`/healthz`
  прокси). Роль Ansible `node_firewall` ставит свою таблицу nftables
  (`inet kubeadm_gateway_metrics`, юнит `kubeadm-gateway-metrics-firewall`,
  переживает перезагрузку): на эти порты пускают только сам узел и сеть
  подов (`10.244.0.0/16`, откуда ходит Prometheus), остальным — TCP reset.
  Остальные порты и правила (SSH, 6443, 80/443, Cilium) таблица не трогает.
  Выбрали nftables, а не host firewall Cilium: тот при первой же политике
  узла запрещает всё, что не разрешено явно (риск отрезать SSH и
  kubelet), а здесь правило одно и узкое. Проверка с другой машины:
  `curl http://$IP:9962/metrics` → `Connection refused`. `make destroy`
  снимает таблицу.
- **Pod Security по namespaces.** `restricted` — `demo`, `gateway`,
  `envoy-gateway-system`, `cert-manager`, `monitoring` (Prometheus,
  Alertmanager, Grafana, оператор, kube-state-metrics) и `logging`
  (VictoriaLogs). Компонентам уровня узла нужен хост, а это запрещает даже
  `baseline`, поэтому они вынесены в отдельные namespaces с `privileged`:
  `monitoring-node` — node-exporter (host network/PID, только чтение `/`,
  `/proc`, `/sys`) и прокси etcd (host network); `logging-node` — Fluentd
  (hostPath каталогов логов подов только на чтение и `/var/lib/fluentd` для
  позиций и буфера); `local-path-storage` — local-path-provisioner создаёт
  каталоги томов на узле вспомогательными подами с hostPath. Сами поды там
  без privileged и без добавленных capabilities. `kube-system` остаётся как
  его создаёт kubeadm (статические поды control plane, поды Cilium).
- **Fluentd от root, но без capabilities.** Файлы логов контейнеров
  принадлежат root с правами `0640`, поэтому Fluentd работает с uid 0 и
  читает их как владелец. Остальное закрыто: все capabilities сброшены (без
  `CAP_DAC_OVERRIDE` обычные права файлов действуют и для root), запрет
  повышения привилегий, корневая ФС только для чтения, seccomp
  `RuntimeDefault`. С узла смонтированы только `/var/log/pods` и
  `/var/log/containers` (только чтение; символьные ссылки во втором ведут в
  первый, пути внутри контейнера те же) и `/var/lib/fluentd` — больше
  ничего из файлов узла Fluentd не видит. Права к API — только
  `get/list/watch` подов и namespaces (метаданные).
- **Сетевые политики.** Cilium применяет стандартные NetworkPolicy. Во всех
  наших namespaces (`demo`, `gateway`, `envoy-gateway-system`,
  `cert-manager`, `local-path-storage`, `monitoring`, `monitoring-node`,
  `logging`, `logging-node`) входящий трафик запрещён по умолчанию
  (`default-deny-ingress`), разрешено только:

  | Куда | Откуда |
  |---|---|
  | приложение `demo`, порт 8080 | Envoy-прокси Gateway |
  | метрики всех компонентов (Angie 9113, Envoy 19001, cert-manager 9402, Fluentd 24231, VictoriaLogs 9428, всё в `monitoring`) | Prometheus |
  | Prometheus 9090, Alertmanager 9093 | Grafana, Envoy-прокси (UI) |
  | Grafana 3000 | Envoy-прокси (UI) |
  | VictoriaLogs 9428 | Fluentd (запись), Grafana и Envoy-прокси (чтение), Prometheus |
  | Envoy-прокси 10080/10443 (Gateway 80/443) | откуда угодно |
  | вебхуки cert-manager (10250) и Envoy Gateway (9443) | API-сервер (порт открыт для всех: вебхук — это TLS, принимает только AdmissionReview) |
  | внутри `envoy-gateway-system` | прокси ↔ контроллер (xDS) |

  Трафик с самого узла (пробы kubelet, API-сервер) Cilium пропускает всегда.
  Исходящий трафик не ограничиваем: поды ходят в API-сервер, DNS, Grafana
  скачивает плагин, а запрет входящего уже закрывает главное — например, из
  пода в `demo` нельзя ни остановить Prometheus (`/-/quit`), ни записать
  логи в VictoriaLogs (`/insert`). Политики — в `charts/network-policies`
  (список namespaces и правил — в `values/network-policies.yaml.gotmpl`), для
  `demo` — в чарте приложения.
- **Grafana видит только свой namespace.** Сайдкары Grafana читают дашборды и
  источники данных только из ConfigMap в `monitoring` (все наши дашборды
  лежат там, включая дашборд VictoriaLogs); Secret'ы не читают вовсе. Права —
  Role в `monitoring` на `get/list/watch` ConfigMap, без ClusterRole.
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
  `admin.existingSecret`; повторный деплой его не меняет. Если Secret
  удалили, `make platform` создаёт новый пароль и перезапускает Grafana —
  иначе она продолжала бы принимать старый, а `make ui` показывал бы новый.
  Prometheus и vmui
  своей аутентификации не имеют, их закрывает basic auth на Gateway; у
  Grafana — свой вход.
- **Пробы не портят метрики.** Счётчики Angie ведутся по ключу: проверки
  kubelet (`/healthz`) идут в зону `probes`, трафик приложения — в зону
  `app`, поэтому RPS и раскладка по версиям считаются без шума проб. Общая
  зона `server`, в которой живут эти ключи, всегда нулевая — её серии
  отбрасываются при сборе (`metricRelabelings`).
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
  это допустимо, потому что пароль случайный, 128 бит. Маршруты на UI —
  отдельный релиз `ui-routes` (список `routes` в
  `values/ui-routes.yaml.gotmpl`: `basicAuth: true` включает защиту,
  `allow` — какие методы и пути пропускать). Публикация приложения от него
  не зависит: релиз `gateway` не ждёт мониторинга и логов.
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
- **Сетевые политики и закрытие портов метрик рассчитаны на один узел.**
  Вебхуки и пробы kubelet проходят как трафик самого узла; на нескольких
  узлах понадобятся правила для соседних узлов (`ipBlock` их адресов), а в
  таблицу nftables — их адреса. Исходящий трафик подов не ограничен.
- **Сеть при развёртывании.** Короткие сбои сети (репозитории чартов,
  реестры образов) переживаются повторами, но долгий обрыв прерывает
  развёртывание — тогда достаточно запустить `./deploy.sh` ещё раз.
