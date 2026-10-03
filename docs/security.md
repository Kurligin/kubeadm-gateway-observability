# Безопасность

Модель угроз демо-стенда и меры против них. Безопасность включена по
умолчанию: ничего не нужно включать флагами. Команды проверки используют
переменные `IP`, `PASS` и файл `ca.crt` из
[verification.md](verification.md#переменные).

- [Модель угроз](#модель-угроз)
- [Доступ к UI и API наблюдаемости](#доступ-к-ui-и-api-наблюдаемости)
- [Метрики etcd через kube-rbac-proxy](#метрики-etcd-через-kube-rbac-proxy)
- [node-exporter за kube-rbac-proxy](#node-exporter-за-kube-rbac-proxy)
- [Порты узла: что открыто снаружи](#порты-узла-что-открыто-снаружи)
- [Pod Security](#pod-security)
- [Сертификаты kubelet от CA кластера](#сертификаты-kubelet-от-ca-кластера)
- [Секреты](#секреты)
- [Цепочка поставки](#цепочка-поставки)
- [Принятые риски](#принятые-риски)

## Модель угроз

Стенд — один или несколько узлов в локальной сети или облачная ВМ с
публичным адресом. Сервис опубликован через Gateway (80/443); кроме него
снаружи доступны только SSH, API-сервер (6443, с аутентификацией) и VXLAN
Cilium (UDP 8472) — [что и почему](#порты-узла-что-открыто-снаружи).
Защищаем: управление кластером, данные наблюдаемости (метрики, логи,
трейсы), целостность приложения и самих компонентов наблюдаемости, секреты.

| Угроза | Мера | Как проверить |
|---|---|---|
| Кто угодно из сети читает метрики, логи и трейсы через Gateway | basic auth (SecurityPolicy) на Prometheus, Alertmanager, vmui, UI трейсов; Grafana — своя форма входа | без пароля → 401, `make verify` шаг 8 |
| Через UI останавливают Prometheus или пишут поддельные логи | наружу открыто только чтение: `POST /-/quit`, `/-/reload`, `/insert/*` не маршрутизируются (404 даже с паролем) | [verification.md, шаг 8](verification.md#8-безопасность) |
| Скомпрометированный под приложения атакует соседей | NetworkPolicy default-deny во всех наших namespaces; PSA `restricted`; non-root, read-only FS, drop ALL, seccomp | под в `demo` не достаёт до Prometheus (таймаут) |
| Метрики узла, etcd и Cilium читаются из сети без аутентификации | etcd только на `127.0.0.1` + kube-rbac-proxy (TLS, токен, RBAC); node-exporter за kube-rbac-proxy; nftables закрывает порты метрик | `:2381` refused, `:2382`/`:9100` на узле без токена 401, с другой машины — сброс |
| Внутренние порты кластера (kubelet, etcd, controller-manager, scheduler, Hubble) открыты в интернет на публичной ВМ | nftables: только сам узел, узлы кластера и поды; остальным — TCP reset | с другой машины `:10250`, `:2379` — сброс, на узле `tcpdump` видит SYN и RST |
| Подмена сертификата kubelet (MITM между API и kubelet) | `serverTLSBootstrap`, CSR одобряется только с именем и IP узла из inventory | `kubectl get csr`: чужие SAN остаются pending |
| Пароли и токены утекают через git, логи, список процессов | пароли генерируются при первом деплое в Secret; join-токен TTL 15 мин, `no_log`; прокси-учётки только в файлах 0600 | `git grep` по репозиторию; `make ui` — единственный способ увидеть пароли |
| Подмена образов, бинарников, чартов, пакетов (в том числе зеркалом реестра) | образы по digest, бинарники и чарты по sha256, плагин Grafana по подписи, ключ apt по отпечатку | `make lint` (digest, sha256 чартов), `versions.env` |
| Ошибки конфигурации манифестов | kubeconform strict, trivy config, kube-linter в CI | workflow `lint` |

## Доступ к UI и API наблюдаемости

| UI | Вход | Что пропускает Gateway |
|---|---|---|
| Grafana | своя форма входа: `admin` / пароль из Secret `monitoring/grafana-admin` | всё |
| Prometheus | basic auth Gateway: `admin` / пароль из Secret `gateway/ui-basic-auth` | `GET`, `HEAD`, `POST /api/v1/*` (запросы) |
| Alertmanager | тот же basic auth | `GET`, `HEAD`, создание и удаление silence |
| vmui (VictoriaLogs) | тот же basic auth | только `/select/*` (vmui и LogsQL API) |
| UI трейсов (VictoriaTraces) | тот же basic auth | только `/select/*` (UI, Jaeger API, LogsQL API) |

У Prometheus, Alertmanager и VictoriaLogs своей аутентификации нет,
поэтому наружу открыто только чтение. Маршруты — отдельный релиз
`ui-routes` (список `routes` в `values/ui-routes.yaml.gotmpl`: `basicAuth:
true` включает защиту, `allow` — какие методы и пути пропускать).

- **Basic auth.** Пароль (128 бит) генерируется при первом деплое в Secret
  `gateway/ui-basic-auth` (`scripts/ensure-basic-auth.sh`, htpasswd `{SHA}`,
  как требует Envoy Gateway), передаётся `kubectl` через stdin и не виден в
  списке процессов. Существующий Secret не пересоздаётся, удалённый —
  восстанавливается следующим `make platform`.
- **Пароль Grafana** — так же, в Secret `monitoring/grafana-admin`
  (`scripts/ensure-grafana-admin.sh`, `admin.existingSecret`). Если Secret
  удалили, `make platform` создаёт новый пароль и перезапускает Grafana —
  иначе она принимала бы старый, а `make ui` показывал бы новый.
- **Grafana видит только свой namespace.** Сайдкары читают дашборды и
  источники данных только из ConfigMap в `monitoring`; Secret'ы не читают.
  Права — Role на `get/list/watch` ConfigMap, без ClusterRole.
- Пароли не печатаются при деплое и в `make status`; показывает их только
  `make ui` на узле.

## Метрики etcd через kube-rbac-proxy

etcd отдаёт метрики по HTTP только на `127.0.0.1:2381` (по умолчанию
kubeadm), а клиентский сертификат etcd узел не покидает. DaemonSet
`etcd-metrics-proxy` (host network, `monitoring-node`, только control plane):
kube-rbac-proxy слушает `<IP узла>:2382` по TLS (сертификат от
cert-manager), проверяет токен (TokenReview) и право (SubjectAccessReview) и
только тогда проксирует в `127.0.0.1:2381`; другие пути — 404.

Проверяется не общее право `get /metrics` (оно есть у любого, кто читает
метрики, и открывает заодно метрики API-сервера), а узкое: `get`
подресурса `services/metrics` у Service `monitoring-node/etcd-metrics`
(`authorization.resourceAttributes`). Его Role выдаёт только ServiceAccount
Prometheus. Prometheus предъявляет проецируемый короткоживущий токен
(`bearerTokenFile`, его ротирует kubelet), сертификат прокси проверяется по
CA. Пробы — HTTPS `/healthz` на отдельном порту 2383: TCP-проба на основной
порт засоряла бы лог ошибками TLS handshake.

На узле (нужен kubectl): без токена — 401, с токеном чужого ServiceAccount
— 403, а `:2381` недоступен (`Failed to connect`: etcd слушает только
`127.0.0.1`). С другой машины порт 2382 закрыт nftables (он нужен только
Prometheus):

```bash
curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt https://$IP:2382/metrics
TOKEN=$(kubectl -n demo create token default)
curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt -H "Authorization: Bearer $TOKEN" https://$IP:2382/metrics
curl -sS -m 5 http://$IP:2381/metrics
```

```text
401
403
curl: (7) Failed to connect to 192.168.1.38 port 2381 …
```

## node-exporter за kube-rbac-proxy

node-exporter слушает только `127.0.0.1`, а порт узла 9100 обслуживает
kube-rbac-proxy: TLS (сертификат от cert-manager), токен и то же узкое право
(`get services/<имя>` у своего Service), выданное только Prometheus. Без
токена — 401 (с узла), с другой машины порт закрыт nftables.

## Порты узла: что открыто снаружи

Компоненты с host network слушают все адреса узла (или его адрес), и на
облачной ВМ с публичным адресом без облачного firewall они видны из
интернета. Роль Ansible `node_firewall` ставит свою таблицу nftables (`inet
kubeadm_gateway_metrics`, юнит `kubeadm-gateway-metrics-firewall`,
переживает перезагрузку): на перечисленные ниже порты пускают только сам
узел, сеть подов (`10.244.0.0/16`: Prometheus, metrics-server, Hubble Relay)
и адреса узлов кластера (control plane и воркеры из
`/etc/kubeadm-gateway/workers.json`), остальным — TCP reset. Правила других
таблиц (Cilium, администратора) таблица не отменяет. `make destroy` снимает
таблицу.

| Порт | Кто слушает | Снаружи | Почему |
|---|---|---|---|
| 22 | SSH | открыт | управление узлом; решение его не трогает |
| 80, 443 | Gateway (Envoy, адрес узла через Cilium) | открыт | сервис |
| 6443 | API-сервер | открыт | `kubectl`, helm, удалённый inventory; без клиентского сертификата или токена анонимно доступны только `/version` и проверки здоровья (`/healthz`, `/livez`, `/readyz`), остальное — 403. `API_SERVER_OPEN=false ./deploy.sh` закрывает и его (тогда `kubectl` — только с узлов) |
| UDP 8472 | VXLAN Cilium (ядро) | открыт | туннель между узлами; адреса будущих воркеров заранее неизвестны, поэтому порт не ограничен — в облаке закрывайте его security group |
| 10250 | kubelet | закрыт | API-сервер (`logs`, `exec`), metrics-server, Prometheus |
| 2379, 2380 | etcd (клиенты, пиры) | закрыт | API-сервер ходит на `127.0.0.1:2379`, второго control plane нет |
| 2382, 2383 | прокси метрик etcd, его `/healthz` | закрыт | Prometheus, пробы kubelet |
| 10257, 10259 | controller-manager, scheduler | закрыт | метрики для Prometheus, пробы kubelet |
| 4244 | Hubble (cilium-agent) | закрыт | Hubble Relay |
| 4240 | cilium-health | закрыт | проверки связности между узлами |
| 9100, 8888 | node-exporter (kube-rbac-proxy) и его `/healthz` | закрыт | Prometheus |
| 9962–9965 | метрики Cilium (agent, operator, Envoy, Hubble) | закрыт | Prometheus, без аутентификации |

Внутри кластера всё это работает как прежде: сам узел (API-сервер к своему
kubelet, пробы kubelet) проходит по правилу «адрес источника — свой», под
своего узла — по сети подов, под или API-сервер другого узла — по адресу
узла (трафик пода к адресу соседнего узла уходит с адресом своего узла).
Порты 2379/2380/10257/10259 на воркере никто не слушает, правило там ничего
не меняет. Порты, которых нет в таблице, она не трогает.

Почему не host firewall Cilium: он при первой же политике узла запрещает
всё, что не разрешено явно (риск отрезать SSH и kubelet), а здесь правило
одно и узкое. В облаке первая линия — security group: открыть входящие TCP
22, 80, 443 (и 6443, только если нужен удалённый `kubectl`); таблица
nftables — вторая линия на случай, если облачного firewall нет.

С другой машины все команды печатают `Failed to connect` (TCP reset; за
VPN-клиентом с TUN — `Empty reply from server`,
[operations.md](operations.md#облачная-вм-nat-и-security-group)):

```bash
curl -sS -m 5 http://$IP:9962/metrics
curl -sS -m 5 -k https://$IP:9100/metrics
curl -sS -m 5 -k https://$IP:10250/healthz
curl -sS -m 5 -k https://$IP:2379/health
```

Надёжнее всего смотреть на самом узле: во время такого запроса
`sudo tcpdump -ni any 'tcp port 10250 and not src net 10.244.0.0/16'`
показывает входящий SYN с чужого адреса и ответный RST, а счётчик
`sudo nft list table inet kubeadm_gateway_metrics` — сколько раз сработал
reject.

## Pod Security

PSA в режиме enforce; уровни по namespaces — в
[architecture.md](architecture.md#namespaces-и-pod-security).

- Поды в `restricted`-namespaces: non-root, `allowPrivilegeEscalation:
  false`, capabilities `drop: [ALL]`, seccomp `RuntimeDefault` (это требует
  сам уровень `restricted`); у своих компонентов ещё и корневая ФС только
  для чтения. Исключения — ниже.
- **Angie** работает от uid 100 образа, pid и временные файлы — в emptyDir.
- **local-path-provisioner** — без root (65534), read-only FS.
- **Fluentd от root, но без capabilities.** Файлы логов контейнеров
  принадлежат root с правами `0640`, поэтому Fluentd работает с uid 0 и
  читает их как владелец. Все capabilities сброшены (без
  `CAP_DAC_OVERRIDE` обычные права файлов действуют и для root), запрет
  повышения привилегий, корневая ФС только для чтения. С узла смонтированы
  только `/var/log/pods`, `/var/log/containers` (только чтение) и
  `/var/lib/fluentd`. Права к API — `get/list/watch` подов и namespaces.
- **node-exporter и прокси etcd** — host network (и host PID у
  node-exporter), но без privileged и без capabilities; node-exporter видит
  `/`, `/proc`, `/sys` только на чтение.
- **kube-state-metrics** — без коллектора `secrets` (прав на Secret'ы нет).

## Сертификаты kubelet от CA кластера

По умолчанию kubelet подписывает свой HTTPS-сертификат сам, и проверить его
нельзя (отсюда популярный `--kubelet-insecure-tls` у metrics-server). Здесь
включён `serverTLSBootstrap: true`: kubelet запрашивает сертификат у CA
кластера (CSR, signer `kubernetes.io/kubelet-serving`). Kubernetes такие
запросы сам не одобряет — запрос доказывает, какой узел его прислал, но не
то, что имена в нём принадлежат узлу.

Одобряет скрипт `ansible/roles/kubeadm_init/files/approve-kubelet-serving-csr.sh`:
запрос от `system:node:<имя>` проходит, только если узел есть в inventory,
subject — `CN=system:node:<имя>, O=system:nodes`, а в сертификате только имя
этого узла и его IP из фактов Ansible (IPv6 сравниваются нормализованными);
остальное остаётся pending. Скрипт запускают каждый `make deploy` и раз в
час systemd-таймер `kubeadm-gateway-kubelet-cert-approver.timer` (продление
сертификата одобряется и без деплоя). Отсюда `kubectl logs/exec/top` и
metrics-server работают с проверкой TLS.

## Секреты

- В репозитории нет паролей, токенов и ключей. Пароли UI и Grafana
  генерируются при первом деплое в Secret и не меняются при повторных.
- **Join-токен** воркера — TTL 15 мин, файл 0600 на воркере удаляется сразу
  после `kubeadm join`, токен удаляется из кластера, в выводе Ansible его
  нет (`no_log`). Токен `kubeadm init` тоже живёт 15 мин.
- **Прокси с паролем** (`http://user:pass@proxy:3128`): адрес с паролем
  лежит только в файлах 0600 (apt-конфиг, EnvironmentFile containerd), в
  Secret для Grafana и в Secret релиза Helm; `deploy.sh` печатает адрес без
  пароля, `helmfile` не показывает diff Secret'ов.
- Сертификат CA демо-PKI (`ca.crt`) — публичная часть; ключ остаётся в
  Secret `cert-manager/demo-ca-keypair`.

## Цепочка поставки

- Образы — `tag@sha256:…` (digest мультиархитектурного индекса) в
  `versions.env`; `make lint` рендерит все релизы и падает, если хоть у
  одного образа (включая встроенные в аргументы операторов) нет digest или
  `images.txt` устарел. Исключение — образы control plane kubeadm: kubeadm
  берёт их по тегу версии Kubernetes и digest задать не позволяет.
- **Зеркала реестров** (Docker Hub по умолчанию,
  [operations.md](operations.md#сеть-в-рф-зеркала-и-источники)) не
  расширяют доверие. У зеркал только возможность `pull`: containerd
  спрашивает у них лишь содержимое по digest, а тег в digest переводит сам
  реестр (образы kubeadm идут по тегу — его разрешает registry.k8s.io).
  Каждый индекс, манифест и слой сверяется с digest; зеркало может
  отказать или отдать чужие байты — тогда загрузка падает и containerd
  идёт к следующему источнику, — но запустить подменённый образ не может.
  Это действует для любого образа на узле, не только для наших. То же у
  `make images`.
- Бинарники (containerd, runc, helm, helmfile, helm-diff, инструменты lint)
  проверяются по sha256 из `versions.env` — из какого бы источника они ни
  пришли (у helm их два).
- Чарты сторонних проектов лежат в `vendor/charts` (архивы, которые отдают их
  репозитории); `make lint` и `make platform` сверяют их sha256 с
  `versions.env` и версию в `Chart.yaml` внутри архива.
- Плагин VictoriaLogs для Grafana подписан Grafana Labs (тип commercial,
  организация VictoriaMetrics); Grafana проверяет подпись и хэши файлов
  встроенным ключом, неподписанные плагины не разрешены.
- Ключ pkgs.k8s.io принимается только при совпадении отпечатка
  `K8S_APT_KEY_FINGERPRINT`; пакеты закреплены apt pinning и `hold`.
- CI: kubeconform (strict), trivy config (HIGH/CRITICAL везде, MEDIUM в
  своих чартах), kube-linter; исключения с обоснованием — в
  [`.trivyignore.yaml`](../.trivyignore.yaml) и
  [`.kube-linter.yaml`](../.kube-linter.yaml). Actions закреплены по SHA,
  токен workflow — только чтение, Dependabot предлагает обновления.

## Принятые риски

- **Self-signed CA** `demo.local`: браузер и curl доверяют ему только с
  `ca.crt`. Для настоящего домена — ACME-issuer cert-manager.
- **Хеш `{SHA}`** (SHA-1 без соли) в htpasswd — ограничение Envoy Gateway;
  допустимо, потому что пароль случайный, 128 бит.
- **controller-manager и scheduler** — `insecureSkipVerify` при сборе
  метрик: их серверный сертификат самоподписан компонентом (токен при этом
  проверяется).
- **Исходящий трафик подов не ограничен** — политики только на входящий.
- **Namespaces `monitoring-node`, `logging-node`, `local-path-storage`** —
  PSA `privileged`: компонентам уровня узла нужен хост. Сами поды без privileged и
  capabilities.
- **`X-App-Version`** видна клиенту (нужна для тега спана); версия и так
  есть в теле ответа.
- **API-сервер (6443) и VXLAN (UDP 8472) открыты** по умолчанию — см.
  [таблицу портов](#порты-узла-что-открыто-снаружи); в облаке их закрывает
  security group.
- **Порт 10428 VictoriaTraces** внутри кластера принимает и OTLP/HTTP:
  NetworkPolicy не различает пути; снаружи через Gateway проходит только
  `/select/*`.
