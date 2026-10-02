# Проверка

Полная версия раздела «Проверка» [README](../README.md): что делает
`make verify`, как проверить каждый шаг руками и как увидеть алерты в
действии. Все команды работают в bash и zsh (Linux, macOS), нужны `curl` и
`jq` (для трейсов ещё `openssl`).

- [Одной командой: `make verify`](#одной-командой-make-verify)
- [Переменные](#переменные)
- [Шаги вручную](#шаги-вручную): [1. Кластер](#1-кластер) ·
  [2. Gateway](#2-gateway) · [3–5. Приложение через Gateway](#35-приложение-через-gateway) ·
  [6. Логи](#6-логи) · [7. Мониторинг](#7-мониторинг) ·
  [8. Безопасность](#8-безопасность) · [9. Несколько узлов](#9-несколько-узлов) ·
  [10. Трейсинг](#10-трейсинг)
- [Веб-интерфейсы](#веб-интерфейсы)
- [Демонстрация алертов](#демонстрация-алертов)

## Одной командой: `make verify`

```bash
make verify        # на узле: адрес, CA и пароли берутся из кластера
```

Скрипт [`scripts/verify.sh`](../scripts/verify.sh) печатает строку на каждую
проверку: `✓` — прошла, `✗` — нет (с причиной), `-` — пропущена (с
причиной). В конце — итог и код возврата: `0`, если провалов нет, иначе `1`.
Сразу после деплоя не всё готово мгновенно (цели Prometheus появляются через
1–2 интервала сбора), поэтому такие проверки повторяются до 5 минут
(`WAIT=<секунды>`), запись в логах ищется до 45 с, трейс — до 60 с, алерт
Watchdog — до 240 с. Прогон занимает ~45 с.

| Шаг | Что проверяется |
|---|---|
| 1 | узлы `Ready`; все поды `Running` и готовы (перезапуски — не провал); все релизы Helm `deployed` |
| 2 | Gateway `public`: `Programmed=True`, адрес = IP узла; все HTTPRoute `Accepted` и `ResolvedRefs` |
| 3 | `http://` → 301 на `https://`; `https://app.demo.local/` → 200 и `Hello World!` (сертификат проверяется по CA кластера) |
| 4 | 200 запросов: доля v2 в коридоре 5–20 % (вес 10 %); `/v2` и `X-Canary: true` → всегда v2; в ответах `/` и `/v2` есть `x-gateway-route` с именем правила, внутреннего `x-backend-pod` нет |
| 5 | `/limited`: из 25 запросов (10 × 2 реплики Envoy + 5) не больше 20 успешных и хотя бы один 429 от rate limit Envoy (заголовок `x-ratelimit-limit: 10`); основной маршрут при этом отвечает 200 |
| 6 | запрос с уникальным `X-Request-ID` → записи с этим ID в VictoriaLogs из access-логов Angie и Envoy; поддельный `X-Gateway-Route` клиента до Angie не дошёл (заменён фильтром маршрута); копия запроса (зеркало) пришла в web-v2 на теневой порт (`traffic: shadow`) |
| 7 | Prometheus: ключевые цели (API-сервер, kubelet, controller-manager, scheduler, etcd, CoreDNS, node-exporter, kube-state-metrics, Cilium, Envoy, Envoy Gateway, web-v1/v2, Fluentd, VictoriaLogs, а при трейсинге и VictoriaTraces) `up` по `/api/v1/targets`; счётчик запросов Envoy вырос на трафик шагов 3–6 (по каждому поду Envoy); PromQL по метрикам Angie (запросы по версиям); `kubectl top nodes` и `kubectl top pods -A`; алерт Watchdog за последние 10 мин дошёл до webhook-получателя и лежит в VictoriaLogs |
| 8 | Prometheus и логи без пароля → 401; `POST /-/quit` и `/insert` даже с паролем через Gateway → 404; etcd `:2381` снаружи недоступен; прокси метрик etcd и node-exporter без токена → 401 или соединение сброшено; метрики Cilium `:9962` закрыты для сети (проверяется только с другой машины) |
| 9 | только при нескольких узлах: DaemonSet'ы готовы на каждом узле; Envoy и web-v1/web-v2 больше чем на одном узле; Gateway отвечает 200 по адресу каждого узла; `kubectl logs`/`top` воркера; логи подов воркера в VictoriaLogs; node-exporter и kubelet каждого узла `up` |
| 10 | только при включённом трейсинге: запрос со сгенерированным `traceparent` → трейс с этим ID в VictoriaTraces (Jaeger API) за ≤ 60 с, в нём спан Envoy с маршрутом (`gateway.route`) и версией бэкенда (`backend.version`); этот `trace_id` в access-логе Angie в VictoriaLogs; Grafana: datasource трейсов отдаёт трейс, ссылки лог ↔ трейс настроены |

Итог на стенде (control plane 4 vCPU / 8 ГБ, трейсинг включён): один узел —
`Passed: 29, failed: 0, skipped: 2`; с воркером —
`Passed: 35, failed: 0, skipped: 1` (пропуск — порт Cilium `:9962`, его
можно проверить только с другой машины).

**С другой машины** (без kubectl) — те же проверки, кроме уровня кластера
(шаги 1, 2, 9 и `kubectl top` пропускаются). Нужны `curl`, `jq`, `ca.crt` и
пароль basic auth (см. [«Переменные»](#переменные)); для проверки Grafana на
шаге 10 — ещё `GRAFANA_PASSWORD`. Если на вашей машине есть kubectl, скрипт
пользуется им, только когда текущий контекст смотрит в этот кластер.

```bash
GATEWAY_IP=$IP CA_FILE=ca.crt UI_PASSWORD=$PASS ./scripts/verify.sh
# Passed: 23, failed: 0, skipped: 8 — на стенде с двумя узлами
```

**Повторный запуск в течение минуты** корректен: rate limit `/limited`
считается поминутно, и если лимит исчерпан прошлым запуском, все 25 запросов
получат 429 — это тоже работа лимита. 429 «не от лимита» (без заголовка
`x-ratelimit-limit`) — провал. Лимит локальный, у каждой реплики Envoy своё
ведро, поэтому проверка шлёт больше, чем пропустят обе реплики вместе.

**Сразу после обновления** уже работающего кластера (не первой установки)
Prometheus Operator может пересоздать под Prometheus дважды; на 2 vCPU второй
перезапуск ждёт завершения первого до ~10 мин, и проверки шага 7 до этого не
проходят — повторите `make verify` через несколько минут. Там же, на 2 vCPU
/ 4 ГБ, бывают однократные перезапуски контроллеров из-за медленного etcd;
они поднимаются сами. На 4/8 этого не видели.

## Переменные

Задайте один раз в той же сессии терминала; команды ниже на них опираются.

**На узле** (из каталога репозитория):

```bash
make ca                                   # пишет ./ca.crt — корень демо-CA
IP=$(kubectl -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
PASS=$(kubectl -n gateway get secret ui-basic-auth -o jsonpath='{.data.password}' | base64 -d)
```

**С другой машины** в той же сети (замените адрес и пользователя SSH; путь —
каталог репозитория на узле):

```bash
IP=192.168.1.38
ssh ubuntu@$IP 'cd kubeadm-gateway-observability && make ca >/dev/null && cat ca.crt' > ca.crt
PASS=$(ssh ubuntu@$IP 'kubectl -n gateway get secret ui-basic-auth -o jsonpath={.data.password} | base64 -d')
```

**Дальше везде** — функция `gwcurl`: curl к Gateway с проверкой сертификата
по `ca.crt`, без DNS (`--resolve` подставляет IP для имён `*.demo.local`) и
мимо HTTP-прокси, если он задан в окружении:

```bash
gwcurl() {
  curl -sS --noproxy '*' --cacert ca.crt \
    --resolve "app.demo.local:443:$IP" --resolve "prometheus.demo.local:443:$IP" \
    --resolve "logs.demo.local:443:$IP" --resolve "traces.demo.local:443:$IP" "$@"
}
```

## Шаги вручную

### 1. Кластер

На узле:

```bash
kubectl get nodes -o wide          # Ready, v1.36.5, Ubuntu 24.04.5 LTS, containerd://2.3.6
kubectl get pods -A                # все Running и READY n/n (или Completed у Job)
helm list -A                       # все STATUS deployed
kubectl get storageclass           # local-path (default)
make status                        # сводка: узлы, адрес Gateway, трейсинг, релизы, здоровье
```

Повторный `./deploy.sh` должен завершиться с `changed=0` в итоге Ansible и
без изменений в `helmfile apply` (ревизии в `helm list -A` не растут,
сертификаты и секреты не перевыпускаются). В CI это проверяет
[`scripts/check-idempotency.sh`](../scripts/check-idempotency.sh).

### 2. Gateway

На узле:

```bash
kubectl get gatewayclass,gateway,httproute,referencegrant -A
kubectl get envoyproxy,clienttrafficpolicy,backendtrafficpolicy,securitypolicy -A
kubectl -n gateway get gateway public      # PROGRAMMED True, ADDRESS = IP узла
kubectl -n gateway get httproute app -o jsonpath='{.spec.rules[*].timeouts}'; echo
# {"request":"10s"} {"request":"10s"} {"request":"10s"}
```

### 3–5. Приложение через Gateway

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' -H 'Host: app.demo.local' http://$IP/
# 301 https://app.demo.local/
gwcurl https://app.demo.local/
# Hello World! version=v1 pod=web-v1-…
```

Canary и маршрутизация по пути и заголовку:

```bash
for i in $(seq 100); do gwcurl https://app.demo.local/; done | awk '{print $3}' | sort | uniq -c
#   ~90 version=v1
#   ~10 version=v2
gwcurl https://app.demo.local/v2                       # всегда version=v2
gwcurl -H 'X-Canary: true' https://app.demo.local/     # всегда version=v2
```

Заголовки (стандартные фильтры `ResponseHeaderModifier` /
`RequestHeaderModifier`):

```bash
gwcurl -I https://app.demo.local/ | grep -iE 'x-gateway-route|x-backend-pod|^server'
# x-gateway-route: weighted        (x-backend-pod и server убраны)
gwcurl -I https://app.demo.local/v2 | grep -i x-gateway-route
# x-gateway-route: path-v2
```

Rate limit: путь `/limited` — 10 запросов в минуту на каждую из двух реплик
Envoy, дальше 429. Один curl с несколькими URL держит одно соединение, то
есть одну реплику:

```bash
gwcurl -o /dev/null -w '%{http_code}\n' 'https://app.demo.local/limited?n=[1-15]' | sort | uniq -c
#   10 200
#    5 429
```

Отказ по запросу: `/broken` всегда отвечает 502 и пишет `[error]` в error-лог
Angie — так проверяются error-логи и алерт на 5xx:

```bash
gwcurl -o /dev/null -w '%{http_code}\n' https://app.demo.local/broken     # 502
# для графиков и PromQL: 10 запросов и подождать 60 с (сбор раз в 30 с)
for i in $(seq 10); do gwcurl -o /dev/null https://app.demo.local/broken; done; sleep 60
```

Зеркало и перезапись заголовка запроса (на узле: смотрим логи подов
напрямую):

```bash
gwcurl -H 'X-Gateway-Route: forged' -H 'X-Request-ID: mirror-check-1' https://app.demo.local/
kubectl -n demo logs -l app.kubernetes.io/name=demo-app --tail=-1 | grep mirror-check-1 \
  | jq -c '{gateway_route, traffic, version}'
# {"gateway_route":"weighted","traffic":"app","version":"v1"}      — ответ клиенту
# {"gateway_route":"weighted","traffic":"shadow","version":"v2"}   — зеркало, ответ отброшен
```

Метрики приложения напрямую (на узле; порт 9113 доступен только внутри
кластера):

```bash
kubectl -n demo port-forward svc/web-v1 9113:9113 >/dev/null & PF=$!
sleep 3; curl -s localhost:9113/p8s | grep angie_http_server_zones_requests_total; kill $PF
```

### 6. Логи

Fluentd собирает логи всех контейнеров и шлёт их в VictoriaLogs (что и как —
[architecture.md](architecture.md#логи)). Сквозной `X-Request-ID`: Envoy
сохраняет присланный (или генерирует свой) и передаёт приложению; он есть в
access-логах Envoy и Angie:

```bash
RID="check-$(date +%s)"
gwcurl -H "X-Request-ID: $RID" https://app.demo.local/
sleep 15
gwcurl -u "admin:$PASS" https://logs.demo.local/select/logsql/query \
  --data-urlencode "query=x_request_id:\"$RID\"" \
  | jq -c '{_time, container: ."kubernetes.container_name", traffic, status, uri}'
# {"_time":"…","container":"angie","traffic":"app","status":"200","uri":"/"}
# {"_time":"…","container":"angie","traffic":"shadow","status":"200","uri":"/"}   — копия зеркала
# {"_time":"…","container":"envoy","traffic":null,"status":"200","uri":"/"}
```

Ещё запросы LogsQL (vmui `https://logs.demo.local/select/vmui/` или тот же
API):

```logsql
{kubernetes.namespace_name="demo"}                       # все логи приложения
{kubernetes.namespace_name="demo"} log_type:error        # error-лог Angie (уровни error и notice)
{kubernetes.namespace_name="demo"} status:>=500          # ответы 5xx
{kubernetes.container_name="envoy"} x_request_id:"<id>"  # один запрос в Envoy
{kubernetes.namespace_name="demo"} | stats by (log_type) count()
_time:15m kubernetes.container_name:receiver alertname:Watchdog   # доставленные алерты
```

В Grafana те же логи — Explore → источник VictoriaLogs или нижние панели
дашборда «Demo app — golden signals».

### 7. Мониторинг

Какие цели собирает Prometheus — [architecture.md](architecture.md#метрики).
Все цели `up`:

```bash
gwcurl -u "admin:$PASS" https://prometheus.demo.local/api/v1/targets \
  | jq -r '.data.activeTargets[] | .health + " " + .labels.job' | sort | uniq -c
#    1 up apiserver
#    2 up envoy
#    1 up etcd-metrics
#    …
```

Запрос PromQL через API:

```bash
gwcurl -u "admin:$PASS" -G https://prometheus.demo.local/api/v1/query \
  --data-urlencode 'query=sum by (version) (angie_http_server_zones_requests_total{zone="app"})' \
  | jq -c '.data.result[] | {version: .metric.version, requests: .value[1]}'
# {"version":"v1","requests":"977"}
# {"version":"v2","requests":"119"}
```

Ещё запросы (в UI Prometheus, Grafana → Explore или тем же API):

```promql
# все цели и их состояние (1 — доступна)
up
# запросы к приложению через Envoy, всего и в секунду
sum(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"})
sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"}[5m]))
# canary-раскладка: запросы по версиям (счётчики Angie)
sum by (version) (rate(angie_http_server_zones_requests_total{namespace="demo", zone="app"}[5m]))
# p95 времени ответа приложения, мс (гистограмма Envoy)
histogram_quantile(0.95, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"}[5m])))
# доля 5xx за 10 мин (серия появляется с первым ответом 5xx, например после 10 запросов к /broken)
sum(increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+", envoy_response_code_class="5"}[10m]))
  / sum(increase(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"}[10m]))
# отказы rate limit (429)
sum(increase(envoy_http_local_rate_limit_rate_limited[1h]))
# SLO: доля ошибок за 1 ч и скорость расхода бюджета (1 = ровно за 30 дней)
slo:sli_error:ratio_rate1h
slo:sli_error:ratio_rate1h / on (slo) slo:error_budget:ratio
# Gateway запрограммирован (1 = True)
gatewayapi_gateway_status{type="Programmed"}
```

Чтобы увидеть рост счётчика: выполнить запрос, отправить пачку запросов
(цикл canary выше), подождать 30 с и повторить. Окно 5 мин без трафика даёт
пустую линию — делить нечего.

`kubectl top` (metrics-server), на узле: `kubectl top nodes`,
`kubectl top pods -A`.

### 8. Безопасность

```bash
# без пароля — 401
gwcurl -o /dev/null -w '%{http_code}\n' https://prometheus.demo.local/
gwcurl -o /dev/null -w '%{http_code}\n' https://logs.demo.local/select/vmui/
# служебные и пишущие пути через Gateway не проходят даже с паролем — 404
gwcurl -o /dev/null -w '%{http_code}\n' -u "admin:$PASS" -X POST https://prometheus.demo.local/-/quit
gwcurl -o /dev/null -w '%{http_code}\n' -u "admin:$PASS" -X POST https://logs.demo.local/insert/jsonline
# etcd :2381 снаружи не слушает; прокси метрик etcd без токена — 401
curl -sS -m 5 http://$IP:2381/metrics                                   # Failed to connect
curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt https://$IP:2382/metrics   # 401
# с другой машины: node-exporter и метрики Cilium закрыты (на самом узле 9100 → 401)
curl -sS -m 5 -k https://$IP:9100/metrics                               # Failed to connect
curl -sS -m 5 http://$IP:9962/metrics                                   # Failed to connect
```

Сетевые политики изнутри кластера (на узле): под в `demo` не достаёт до
Prometheus — пакеты отброшены политикой:

```bash
kubectl -n demo run np-check --rm -i --restart=Never --image=docker.io/curlimages/curl:8.16.0 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"np-check","image":"docker.io/curlimages/curl:8.16.0","args":["-sS","-m","5","-X","POST","http://kube-prometheus-stack-prometheus.monitoring:9090/-/quit"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# curl: (28) Connection timed out
```

Модель угроз и остальные меры — [security.md](security.md).

### 9. Несколько узлов

После `make add-worker` (см. [operations.md](operations.md#несколько-узлов)):

```bash
kubectl get nodes -o wide                                  # оба Ready
kubectl get pods -A -o wide | grep -E 'envoy-gateway-public|web-v'   # реплики на разных узлах
curl -sS --cacert ca.crt --resolve app.demo.local:443:<IP воркера> https://app.demo.local/   # Gateway на адресе воркера
make verify                                                # шаг 9
```

### 10. Трейсинг

Если трейсинг включён (`make status` → `Tracing deployed: on`):

```bash
TID=$(openssl rand -hex 16)
gwcurl -H "traceparent: 00-$TID-$(openssl rand -hex 8)-01" https://app.demo.local/
sleep 30            # Envoy сбрасывает спаны раз в 5 с, VictoriaTraces показывает их с задержкой ~10–20 с
gwcurl -u "admin:$PASS" https://traces.demo.local/select/jaeger/api/traces/$TID \
  | jq -r '.data[0].spans[]?.operationName'
# ingress
# router httproute/gateway/app/rule/2 egress
# mirror
# тот же запрос в логах (Envoy и Angie, включая копию зеркала):
gwcurl -u "admin:$PASS" https://logs.demo.local/select/logsql/query \
  --data-urlencode "query=trace_id:=\"$TID\"" | jq -c '{c: ."kubernetes.container_name", trace_id, version}'
```

Пусто — подождите ещё 10–20 с и повторите запрос трейса. Запрос без
`traceparent` тоже трассируется: его trace ID — в поле `trace_id`
access-логов (найти запрос по `X-Request-ID` → взять `trace_id` → «View
trace» в Grafana). В Grafana: Explore → `Traces` → TraceID или Search
(сервис `envoy-gateway`).

**Свой `X-Request-ID` — только UUID.** Envoy принимает решение о
трассировке по `X-Request-ID` (признак упакован в UUID), и запрос с
произвольным ID (например, `check-…` выше или `verify-…` шага 6) не
трассирует — даже с `traceparent`. Запрос без своего ID или с UUID
трассируется. Angie пишет `trace_id` только для семплированных трейсов,
Envoy — у каждого запроса, поэтому у нетрассируемого «View trace» из записи
Envoy покажет «trace not found».

Выключить и проверить, что ничего не осталось (на узле):

```bash
TRACING=false make platform
kubectl get ns tracing                     # NotFound
kubectl get pv | grep tracing              # пусто
kubectl -n envoy-gateway-system get envoyproxy node-lb -o jsonpath='{.spec.telemetry.tracing}'   # пусто
make verify                                # шаг 10: «- Tracing  tracing is off (…)»
TRACING=true make platform                 # обратно; повтор — без изменений
```

## Веб-интерфейсы

Все UI опубликованы через тот же Gateway (HTTPS, сертификат демо-CA),
пароли — `make ui` на узле:

| UI | Адрес | Вход |
|---|---|---|
| Grafana | `https://grafana.demo.local` | `admin` / пароль Grafana |
| Prometheus | `https://prometheus.demo.local` | basic auth `admin` / `$PASS` |
| Alertmanager | `https://alertmanager.demo.local` | basic auth |
| vmui (логи) | `https://logs.demo.local/select/vmui/` | basic auth |
| UI трейсов | `https://traces.demo.local/select/vmui/` | basic auth (если включён трейсинг) |

Пароли по отдельности (на узле):

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n gateway get secret ui-basic-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Чтобы открыть их в браузере с другой машины, добавьте в её `/etc/hosts`
строку `<IP узла> app.demo.local grafana.demo.local prometheus.demo.local alertmanager.demo.local logs.demo.local traces.demo.local`
и импортируйте `ca.crt` (или согласитесь с предупреждением браузера).

Дашборды Grafana: **Demo app — golden signals** (папка General: RPS, доля
5xx, p50/p95/p99, раскладка v1/v2, 429, реплики, CPU и память, логи
access/error, трейсы) и **Gateway / SLO** (SLI, бюджет ошибок, burn rate по
окнам, сработавшие SLO-алерты, метрики по каждому правилу маршрутов).

## Демонстрация алертов

На узле:

- `kubectl -n demo scale deploy/web-v1 --replicas=0` → через ~1,5 мин
  `AppDown` в состоянии firing (Prometheus → Alerts, Alertmanager, и
  JSON-строка в VictoriaLogs: `kubernetes.container_name:receiver
  alertname:AppDown`); вернуть — `--replicas=2`.
- `kubectl -n logging scale statefulset/victoria-logs --replicas=0` →
  `FluentdNoOutput` pending в пределах минуты, через 5 мин firing; вернуть —
  `--replicas=1`: через 1–2 мин алерт снимается, а логи за время простоя
  дозагружаются из буфера Fluentd (запрос, отправленный во время простоя,
  находится по своему `X-Request-ID`).
- `FluentdBufferErrors` смотрит на рост счётчиков ретраев за 10 минут,
  поэтому после простоя VictoriaLogs или перезагрузки узла он может гореть
  ещё до ~10 мин после восстановления, хотя логи уже доставлены — это
  ожидаемо.
