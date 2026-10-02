# Безопасность

Модель угроз демо-стенда и меры против них. Безопасность включена по
умолчанию: ничего не нужно включать флагами. Команды проверки используют
переменные `IP`, `PASS` и файл `ca.crt` из
[verification.md](verification.md#переменные).

- [Модель угроз](#модель-угроз)
- [Доступ к UI и API наблюдаемости](#доступ-к-ui-и-api-наблюдаемости)
- [Метрики etcd через kube-rbac-proxy](#метрики-etcd-через-kube-rbac-proxy)
- [node-exporter за kube-rbac-proxy](#node-exporter-за-kube-rbac-proxy)
- [Порты метрик на узле закрыты для сети](#порты-метрик-на-узле-закрыты-для-сети)
- [Pod Security](#pod-security)
- [Сертификаты kubelet от CA кластера](#сертификаты-kubelet-от-ca-кластера)
- [Секреты](#секреты)
- [Цепочка поставки](#цепочка-поставки)
- [Принятые риски](#принятые-риски)

## Модель угроз

Стенд — один или несколько узлов в локальной сети, наружу опубликован только
Gateway (80/443). Защищаем: управление кластером, данные наблюдаемости
(метрики, логи, трейсы), целостность приложения и самих компонентов
наблюдаемости, секреты.

| Угроза | Мера | Как проверить |
|---|---|---|
| Кто угодно из сети читает метрики, логи и трейсы через Gateway | basic auth (SecurityPolicy) на Prometheus, Alertmanager, vmui, UI трейсов; Grafana — своя форма входа | без пароля → 401, `make verify` шаг 8 |
| Через UI останавливают Prometheus или пишут поддельные логи | наружу открыто только чтение: `POST /-/quit`, `/-/reload`, `/insert/*` не маршрутизируются (404 даже с паролем) | [verification.md, шаг 8](verification.md#8-безопасность) |
| Скомпрометированный под приложения атакует соседей | NetworkPolicy default-deny во всех наших namespaces; PSA `restricted`; non-root, read-only FS, drop ALL, seccomp | под в `demo` не достаёт до Prometheus (таймаут) |
| Метрики узла, etcd и Cilium читаются из локальной сети без аутентификации | etcd только на `127.0.0.1` + kube-rbac-proxy (TLS, токен, RBAC); node-exporter за kube-rbac-proxy; nftables закрывает порты Cilium | `:2381` refused, `:2382`/`:9100` без токена 401, `:9962` с другой машины refused |
| Подмена сертификата kubelet (MITM между API и kubelet) | `serverTLSBootstrap`, CSR одобряется только с именем и IP узла из inventory | `kubectl get csr`: чужие SAN остаются pending |
| Пароли и токены утекают через git, логи, список процессов | пароли генерируются при первом деплое в Secret; join-токен TTL 15 мин, `no_log`; прокси-учётки только в файлах 0600 | `git grep` по репозиторию; `make ui` — единственный способ увидеть пароли |
| Подмена образов, бинарников, пакетов | образы по digest, бинарники по sha256, ключ apt по отпечатку | `make lint` (проверка digest), `versions.env` |
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
`127.0.0.1`):

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

## Порты метрик на узле закрыты для сети

Компоненты с host network слушают все адреса узла без аутентификации:
Cilium — 9962 (agent), 9963 (operator), 9964 (его Envoy), 9965 (Hubble),
4240 (cilium-health); node-exporter — 9100 и 8888 (`/healthz` прокси). Роль
Ansible `node_firewall` ставит свою таблицу nftables (`inet
kubeadm_gateway_metrics`, юнит `kubeadm-gateway-metrics-firewall`,
переживает перезагрузку): на эти порты пускают только сам узел, сеть подов
(`10.244.0.0/16`, откуда ходит Prometheus) и другие узлы кластера,
остальным — TCP reset. Остальные порты и правила (SSH, 6443, 80/443,
Cilium) таблица не трогает. `make destroy` снимает таблицу.

Почему не host firewall Cilium: он при первой же политике узла запрещает
всё, что не разрешено явно (риск отрезать SSH и kubelet), а здесь правило
одно и узкое.

С другой машины в той же сети обе команды печатают `Failed to connect`
(TCP reset):

```bash
curl -sS -m 5 http://$IP:9962/metrics
curl -sS -m 5 -k https://$IP:9100/metrics
```

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
- Бинарники (containerd, runc, helm, helmfile, helm-diff, инструменты lint)
  проверяются по sha256 из `versions.env`.
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
- **Порт 10428 VictoriaTraces** внутри кластера принимает и OTLP/HTTP:
  NetworkPolicy не различает пути; снаружи через Gateway проходит только
  `/select/*`.
