# kubeadm + Gateway API + observability

[![lint](https://github.com/Kurligin/kubeadm-gateway-observability/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/Kurligin/kubeadm-gateway-observability/actions/workflows/lint.yml)
[![e2e](https://github.com/Kurligin/kubeadm-gateway-observability/actions/workflows/e2e.yml/badge.svg?branch=main)](https://github.com/Kurligin/kubeadm-gateway-observability/actions/workflows/e2e.yml)

> Черновик README. Реализованы узел, кластер kubeadm, CNI, хранилище, TLS,
> Gateway API, демо-приложение, мониторинг (Prometheus, Grafana, алерты),
> логи (Fluentd → VictoriaLogs), политики безопасности и сквозная проверка
> `make verify`. Итоговая документация — следующим этапом.

Одна команда на чистой Ubuntu 24.04 поднимает одноузловой кластер Kubernetes
(kubeadm) без kube-proxy: сеть — Cilium, StorageClass по умолчанию —
local-path-provisioner, вход — Envoy Gateway (Gateway API) с TLS от
cert-manager, за ним демо-приложение на Angie в двух версиях (canary).
Метрики собирает Prometheus (kube-prometheus-stack), логи контейнеров —
Fluentd (не Fluent Bit) в VictoriaLogs, трейсы запросов через Gateway —
Envoy (OpenTelemetry) в VictoriaTraces; смотреть — Grafana, Prometheus UI,
vmui и UI трейсов через тот же Gateway. Повторный запуск ничего не меняет,
`make verify` одной командой проверяет всё это сквозными запросами.

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
| Порты метрик на узле | Ansible, роль `node_firewall` | nftables: порты метрик Cilium и node-exporter и API cilium-health доступны только с самого узла, из сети подов и с других узлов кластера |
| TLS | cert-manager + чарт `charts/pki` | self-signed корень → CA `demo-ca` (ClusterIssuer) → сертификат `demo.local`, `*.demo.local` |
| Вход | Envoy Gateway (CRD Gateway API — канал standard) + чарт `charts/gateway` | Gateway `public` на IP узла: HTTP 80 → 301 на HTTPS 443; маршруты, canary, зеркалирование (`RequestMirror`), заголовки (`RequestHeaderModifier`/`ResponseHeaderModifier`), таймауты HTTPRoute, политики; Envoy — 2 реплики с PodDisruptionBudget |
| UI | чарт `charts/ui-routes` | маршруты к Grafana, Prometheus, Alertmanager и vmui на том же Gateway, basic auth, только нужные методы и пути |
| Приложение | чарт `charts/demo-app` | Angie `web-v1` / `web-v2` по 2 реплики, JSON access-лог, метрики `/p8s` |
| CRD мониторинга | чарт `prometheus-operator-crds` | ServiceMonitor, PodMonitor, PrometheusRule и др. — самым первым релизом |
| Метрики | kube-prometheus-stack | Prometheus (3 дня, PVC), Alertmanager, Grafana, node-exporter (за kube-rbac-proxy), kube-state-metrics, правила и дашборды по кластеру |
| Метрики etcd | чарт `charts/etcd-metrics-proxy` | kube-rbac-proxy: TLS + токен + RBAC перед `127.0.0.1:2381` etcd |
| Логи | VictoriaLogs + чарт `charts/logging` (Fluentd) | Fluentd DaemonSet читает логи всех контейнеров, добавляет метаданные Kubernetes, шлёт в VictoriaLogs (7 дней, PVC) |
| Алерты, дашборды, SLO | чарт `charts/observability-extras` | цели Envoy и Envoy Gateway, PrometheusRule, SLO с burn-rate алертами (unit-тесты `promtool test rules`), дашборды «Demo app — golden signals» и «Gateway / SLO», datasource VictoriaLogs |
| Трейсинг | VictoriaTraces + `telemetry.tracing` в EnvoyProxy (`charts/gateway`) | спан Envoy на каждый запрос (OTLP/gRPC), `trace_id` в access-логах Envoy и Angie, Grafana: трейс ↔ логи; включается сам на узле от 6 ГБ (`TRACING`, см. «Трейсинг») |
| Доставка алертов | Alertmanager + webhook-получатель в `charts/observability-extras` | каждый алерт — JSON-строкой в лог получателя → Fluentd → VictoriaLogs; Watchdog — сквозная проверка доставки |
| `kubectl top` | metrics-server | Resource Metrics API; TLS проверяется в обе стороны (сертификаты kubelet подписаны CA кластера) |
| Образы | `versions.env`, `images.txt` | все образы закреплены `tag@sha256:…`; `make images` — предзагрузка в containerd |

Все версии и контрольные суммы — в одном файле [`versions.env`](versions.env)
(`make versions` выводит их списком). Kubernetes — **1.36.5**, способ создания
кластера — **kubeadm**, протестировано на **Ubuntu 24.04.5 LTS (amd64)**.

## Требования

- Ubuntu 24.04 LTS, amd64; **рекомендуем 4 vCPU / 8 ГБ ОЗУ и 30 ГБ
  диска**. Минимум — 2 vCPU / 4 ГБ и 20 ГБ: всё поднимается, но запаса мало
  (см. замеры ниже).
- Память (замер через 5+ мин после деплоя):

  | ВМ | занято ОЗУ (`free`) | доступно | рабочий набор подов (`kubectl top`) | крупнейшие |
  |---|---|---|---|---|
  | 4 vCPU / 8 ГБ | 3,5 ГБ | 4,3–4,4 ГБ | 2,8–3,3 ГБ | kube-apiserver 0,8, Grafana 0,42–0,58, Prometheus 0,32–0,43, Cilium 0,23–0,42 ГБ |
  | 2 vCPU / 4 ГБ | 3,4–3,5 ГБ | 0,37–0,48 ГБ | 2,8–2,9 ГБ | kube-apiserver 0,82–0,89, Grafana 0,39–0,43, Prometheus 0,36–0,43, Cilium 0,26 ГБ |

  Трейсинг по умолчанию включается только на узле control plane от 6 ГБ,
  на 4 ГБ — выключен (см. «Трейсинг»); строка 2/4 выше — без него. Сама
  VictoriaTraces занимает 10–15 МиБ; на 2 vCPU / 4 ГБ с принудительным
  `TRACING=true` доступно 0,57 ГБ против 0,69 ГБ без него (в разницу
  входит и рост Prometheus за время замера), `make verify` проходит и так.

  Вторая реплика Envoy, metrics-server и получатель алертов вместе
  добавляют ~0,1 ГБ (Envoy ~40 МиБ на реплику, metrics-server 20–30 МиБ,
  получатель ~13 МиБ). На 2 vCPU / 4 ГБ `make verify` проходит, но запас
  стал меньше (было 0,65 ГБ доступно, стало 0,37–0,48 ГБ — Prometheus
растёт с числом серий и правил; если нужно
больше, на такой ВМ можно оставить одну реплику Envoy —
`envoyProxy.replicas: 1` в `charts/gateway/values.yaml`, ~40 МиБ); под нагрузкой
  (первый деплой) control plane может перезапуститься — развёртывание это
  переживает.
- Диск. Сразу после деплоя занято ~9,7 ГБ (Ubuntu 2,3 ГБ, образы
  контейнеров 6 ГБ, остальное — etcd, kubelet, кэши). Дальше растут только
  данные, и у каждого есть потолок:

  | Что | Потолок |
  |---|---|
  | метрики Prometheus | 3 ГБ (`retentionSize`) + WAL ~0,5 ГБ |
  | логи в VictoriaLogs | 2 ГБ (`retentionDiskSpaceUsage`) |
  | трейсы в VictoriaTraces (если включены) | 1 ГБ (`retentionDiskSpaceUsage`), 3 дня |
  | буфер Fluentd | 256 МБ |
  | логи контейнеров на узле | ротация kubelet (10 МБ × 5 файлов на контейнер, старые сжаты), на практике < 0,5 ГБ |

  Итого пик ~16 ГБ. На диске 20 ГБ это ~80 %: чуть ниже порога, с
  которого kubelet начинает удалять образы (85 %), поэтому 20 ГБ — минимум,
  а с запасом — 30 ГБ.
- постоянный IP узла (статический или резервирование DHCP): kubeadm вшивает
  адрес в кластер, и если после перезагрузки узел получит другой, control
  plane не поднимется (развёртывание это распознает и подскажет, что делать);
- пользователь с `sudo` (с паролем или без);
- доступ в интернет (пакеты, релизы, образы) — напрямую или через
  HTTP(S)-прокси (см. «Прокси»).

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

Трейсинг ставится, если у узла control plane не меньше 6 ГБ памяти;
включить или выключить явно — `TRACING=true ./deploy.sh` или
`TRACING=false ./deploy.sh` (подробнее — «Трейсинг»).

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

### Прокси

Если узел выходит в интернет только через HTTP(S)-прокси, задайте его при
каждом запуске (без этих переменных про прокси ничего не настраивается, а
настройки прошлого запуска с прокси удаляются):

```bash
export HTTP_PROXY=http://proxy.example:3128 HTTPS_PROXY=http://proxy.example:3128
./deploy.sh            # и make verify / make images из той же сессии
```

Годится любое написание (`HTTP_PROXY` или `http_proxy`); `NO_PROXY` можно
дополнить своими адресами. Что делается:

| Кто ходит в интернет | Как получает прокси |
|---|---|
| `deploy.sh`: apt (`python3-venv`, `make`), pip | переменные окружения (sudo их сохраняет) |
| Ansible: `get_url` (containerd, runc, helm, helmfile, ключ pkgs.k8s.io), apt | окружение плея; apt — файл `/etc/apt/apt.conf.d/95kubeadm-gateway-proxy` |
| containerd (все образы, в т. ч. для kubeadm) | systemd drop-in `/etc/systemd/system/containerd.service.d/http-proxy.conf` → `EnvironmentFile=/etc/kubeadm-gateway/containerd-proxy.env` (0600) |
| helm/helmfile (чарты), `make images` | окружение `make` |
| Grafana (плагин VictoriaLogs с grafana.com) | переменные `HTTP(S)_PROXY` из Secret, который рендерит чарт Grafana (`envRenderSecret`; только при заданном прокси) |

kubelet прокси не нужен: образы тянет containerd, а сам kubelet ходит только
в API-сервер на этом узле. `NO_PROXY` дополняется автоматически
(`scripts/no-proxy.sh`): `localhost`, `127.0.0.1`, все IPv4-адреса узла,
адрес API-сервера, сеть подов `10.244.0.0/16`, сервисов `10.96.0.0/12`,
`.svc`, `.cluster.local`, `demo.local`. `kubeadm init` запускается без
прокси: иначе kubeadm навсегда вписал бы его в манифесты control plane
(образы для него тянет containerd со своей настройкой).

Прокси с логином и паролем (`http://user:pass@proxy:3128`; спецсимволы в
пароле — в URL-кодировке, `%` → `%25`) поддерживается: адрес с паролем
лежит только в файлах, доступных root (`0600`: apt-конфиг — если в URL есть
пароль, файл окружения containerd), в Secret для Grafana и в Secret
релиза Helm; `deploy.sh` печатает адрес прокси без пароля, `helmfile`
не показывает diff Secret'ов. Запросы `make verify`
к Gateway всегда идут напрямую (`curl --noproxy '*'`). Если вызываете
`kubectl` руками в сессии с `HTTPS_PROXY`, добавьте в `NO_PROXY` IP узла —
иначе запрос к API-серверу уйдёт в прокси.

Проверено на стенде: исходящий трафик узла в интернет закрыт nftables,
открыт только прокси (squid на соседней ВМ); `./deploy.sh` с чистой ОС
прошёл за 8 мин, `make verify` — все проверки ✓, в `access.log` squid —
apt (archive.ubuntu.com), pkgs.k8s.io, github.com, get.helm.sh,
репозитории чартов, реестры (quay.io, registry-1.docker.io, registry.k8s.io,
docker.angie.software), grafana.com. Повторный запуск без прокси убрал
настройки (changed=3), следующий — changed=0.

### Нет Ubuntu 24.04? `vagrant up`

[`Vagrantfile`](Vagrantfile) поднимает ВМ Ubuntu 24.04 (box
`bento/ubuntu-24.04` закреплённой версии), копирует в неё репозиторий и
запускает `./deploy.sh`; Gateway слушает адрес ВМ в private network, до
которого есть доступ с вашей машины.

Нужно: amd64 (x86_64) с аппаратной виртуализацией, Vagrant ≥ 2.4 и
VirtualBox ≥ 7 или libvirt/KVM с плагином `vagrant-libvirt`, `rsync`,
~8 ГБ свободной памяти и ~30 ГБ диска. **Apple Silicon (arm64) не
поддерживается**: решение и образы — только amd64. Берите последний
Vagrant: каждая его версия поддерживает VirtualBox только до определённой
версии.

На Windows `vagrant` запускайте из Git Bash (rsync — из MSYS2 или Cygwin в
`PATH`) или из WSL (`VAGRANT_WSL_ENABLE_WINDOWS_ACCESS=1`, репозиторий на
`/mnt/c/...`). `.gitattributes` сохраняет в checkout окончания строк LF,
поэтому скрипты в ВМ работают и после `git clone` на Windows. Команды проверки
с хоста ниже — для bash; для PowerShell `vagrant up` печатает свой вариант
(сертификат пишется через `Set-Content -Encoding ascii`, а не `>`, иначе
выйдет UTF-16).

```bash
vagrant up                        # VirtualBox
vagrant up --provider=libvirt     # libvirt/KVM
VM_CPUS=2 VM_MEMORY=4096 vagrant up            # минимум (по умолчанию 4 vCPU / 8 ГБ)
VM_IP=192.168.57.10 vagrant up    # другой адрес (по умолчанию 192.168.56.10)
```

В конце `vagrant up` печатает, как проверить:

```bash
vagrant ssh -c 'cd kubeadm-gateway-observability && make verify'      # внутри ВМ
# с вашей машины (нужны curl и jq)
vagrant ssh --no-tty -c 'cd kubeadm-gateway-observability && make ca >/dev/null && cat ca.crt' > ca.crt
curl --cacert ca.crt --resolve app.demo.local:443:192.168.56.10 https://app.demo.local/
```

`vagrant provision` повторяет развёртывание (идемпотентно), после правок
на хосте — сначала `vagrant rsync`. `HTTP(S)_PROXY`/`NO_PROXY`, если заданы,
передаются в `./deploy.sh`; прокси на `127.0.0.1` хоста из ВМ недоступен —
укажите адрес хоста, видимый из ВМ (например, `http://192.168.56.1:3128`
для сети по умолчанию), и проверьте, что прокси слушает этот адрес. У box диск 64 ГБ (тонкий), корневой раздел
в госте — 31 ГБ.

Box и сам Vagrant раздаёт HashiCorp; из некоторых сетей (в том числе из
России) `vagrant up` получает 404 при скачивании box. Тогда box
(`https://vagrantcloud.com/bento/boxes/ubuntu-24.04/versions/202508.03.0/providers/<libvirt|virtualbox>/amd64/vagrant.box`)
скачивается любым доступным способом и регистрируется локально с версией,
которую ждёт `Vagrantfile`, плагин vagrant-libvirt ставится с rubygems.org:

```bash
cat > box.json <<'JSON'
{"name": "bento/ubuntu-24.04", "versions": [{"version": "202508.03.0", "providers": [
  {"name": "libvirt", "architecture": "amd64", "default_architecture": true,
   "url": "file:///path/to/vagrant.box"}]}]}
JSON
vagrant box add box.json
vagrant plugin install vagrant-libvirt --plugin-clean-sources --plugin-source https://rubygems.org
```

Проверено с libvirt (Vagrant 2.4.9, vagrant-libvirt 0.12.2, libvirt 10.0.0
и QEMU 8.2 из Ubuntu 24.04, вложенная виртуализация на ВМ Ubuntu 24.04): `VM_CPUS=2 VM_MEMORY=4096 vagrant up
--provider=libvirt` — 12,7 мин до готового решения, `make verify` в ВМ —
26 ✓ и 1 пропуск (порт метрик Cilium с самого узла не проверить), с хоста
по адресу 192.168.56.10 — 21 ✓, остальные 6 проверок требуют kubectl и
пропускаются. С VirtualBox проверен только `vagrant validate`: машины с
VirtualBox у нас не было.

## Команды

| Команда | Что делает |
|---|---|
| `./deploy.sh` / `make deploy` | узел → кластер → платформа; идемпотентно |
| `make verify` | сквозная проверка: таблица ✓/✗ с причинами, код возврата ≠ 0 при провале |
| `make cluster` | только Ansible |
| `make platform` | только helmfile |
| `make status` | узел и версии, адрес Gateway, ссылки UI, релизы Helm, краткое здоровье (без паролей) |
| `make ui` | адреса UI (Grafana, Prometheus, Alertmanager, vmui, трейсы) и пароли к ним |
| `make ca` | выгрузить корневой сертификат CA в `ca.crt` (для `curl --cacert`) |
| `make destroy FORCE=1` | `kubeadm reset` и очистка следов кластера и Cilium (пакеты и бинарники остаются) |
| `make add-worker WORKER=<адрес>` | присоединить воркер по SSH (см. «Несколько узлов») |
| `make remove-worker WORKER=<адрес>` | вывести воркер: drain, сброс узла, удаление из кластера |
| `make images` | после `make cluster`: скачать в containerd все образы из `images.txt` (по digest) и образы control plane kubeadm; уже скачанные пропускаются |
| `make images-list` | пересобрать `images.txt` из отрендеренных манифестов (после смены версий в `versions.env`) |
| `make lint-deps && make lint` | только Ubuntu amd64 (на macOS и других ОС — внутри ВМ `vagrant up`), без кластера, но с интернетом (проверка образов рендерит чарты `helmfile template`, им нужны репозитории чартов): shellcheck, yamllint, ansible-lint, `helm lint` своих чартов, `promtool check rules` и `promtool test rules`, ruff/black и unit-тесты Python, проверка образов: у каждого образа в отрендеренных манифестах есть digest, `images.txt` актуален; kubeconform, trivy config и kube-linter по отрендеренным манифестам (см. «CI/CD») |

## Проверка

### Одной командой: `make verify`

```bash
make verify        # на узле: адрес, CA и пароль берутся из кластера
```

Скрипт `scripts/verify.sh` проходит те же 8 шагов, что описаны ниже для
ручной проверки (шаг 9 — если в кластере есть воркеры, шаг 10 — если
включён трейсинг), и печатает строку на каждую проверку: `✓` — прошла, `✗` —
нет (с причиной), `-` — пропущена (с причиной). В конце — итог и код
возврата: `0`, если провалов нет, иначе `1`. Сразу после деплоя не всё
готово мгновенно (цели Prometheus появляются через 1–2 интервала сбора),
поэтому такие проверки повторяются до 5 минут (`WAIT=<секунды>`), а
запись в логах ищется до 45 с.

| Шаг | Что проверяется |
|---|---|
| 1 | узел `Ready`; все поды `Running` и готовы (перезапуски — не провал); все релизы Helm `deployed` |
| 2 | Gateway `public`: `Programmed=True`, адрес = IP узла; все HTTPRoute `Accepted` и `ResolvedRefs` (с фильтрами и таймаутами) |
| 3 | `http://` → 301 на `https://`; `https://app.demo.local/` → 200 и `Hello World!` (сертификат проверяется по CA кластера) |
| 4 | 200 запросов: доля v2 в коридоре 5–20 % (вес 10 %); `/v2` и `X-Canary: true` → всегда v2; в ответах `/` и `/v2` есть заголовок `x-gateway-route` с именем правила, внутреннего `x-backend-pod` нет |
| 5 | `/limited`: из 25 запросов (10 × 2 реплики Envoy + 5) не больше 20 успешных и хотя бы один 429 от rate limit Envoy (заголовок `x-ratelimit-limit: 10`); основной маршрут при этом отвечает 200 |
| 6 | запрос с уникальным `X-Request-ID` → запись с этим ID в VictoriaLogs и в access-логе Angie, и в access-логе Envoy (LogsQL через API); поддельный `X-Gateway-Route` клиента до Angie не дошёл (заменён фильтром маршрута); копия этого же запроса (зеркало) пришла в web-v2 на теневой порт (`traffic: shadow`) |
| 7 | Prometheus: ключевые цели (API-сервер, kubelet, controller-manager, scheduler, etcd, CoreDNS, node-exporter, kube-state-metrics, Cilium, Envoy, Envoy Gateway, web-v1/v2, Fluentd, VictoriaLogs) в состоянии `up` по API целей (`/api/v1/targets`: сразу после перезагрузки ряды `up` ещё содержат старые точки); счётчик запросов Envoy вырос на трафик шагов 3–6; PromQL по метрикам Angie (запросы по версиям); `kubectl top nodes` и `kubectl top pods -A` (metrics-server); алерт Watchdog за последние 10 мин дошёл до webhook-получателя и лежит в VictoriaLogs |
| 8 | Prometheus и логи без пароля → 401; `POST /-/quit` и `/insert` даже с паролем через Gateway не проходят (404); etcd `:2381` снаружи недоступен; прокси метрик etcd и node-exporter без токена → 401 или соединение сброшено; метрики Cilium `:9962` закрыты для локальной сети (проверяется только с другой машины) |
| 10 | только при включённом трейсинге (иначе одна строка «пропущено» с причиной): запрос со сгенерированным `traceparent` (W3C) через Gateway → трейс с этим ID в VictoriaTraces (Jaeger API через `traces.demo.local`) за ≤ 60 с, в нём спан Envoy с маршрутом приложения (`gateway.route`) и версией ответившего бэкенда (`backend.version`); этот `trace_id` есть в access-логе Angie в VictoriaLogs; Grafana: datasource трейсов отдаёт этот трейс, ссылки лог → трейс и трейс → логи настроены |
| 9 | только при нескольких узлах (на одном — одна строка «пропущено»): поды всех DaemonSet готовы на каждом узле (Cilium, Fluentd, node-exporter — на всех); Envoy и web-v1/web-v2 работают больше чем на одном узле; Gateway отвечает 200 по адресу каждого узла; `kubectl logs` пода на воркере и `kubectl top` воркера; логи подов воркера есть в VictoriaLogs; node-exporter и kubelet каждого узла `up` в Prometheus |

Повторный запуск в течение минуты корректен: rate limit `/limited`
считается поминутно, и если лимит ещё исчерпан прошлым запуском, все 25
запросов получат 429 — это тоже работа лимита (успешных не больше 20),
а 429 «не от лимита» (без заголовка `x-ratelimit-limit`) засчитывается как
провал. Лимит локальный — у каждой из двух реплик Envoy своё ведро
(глобальный лимит через отдельный сервис и Redis не делали), поэтому
проверка шлёт больше, чем пропустят обе реплики вместе, и результат не
зависит от того, как запросы разошлись по репликам.

Сразу после **обновления** уже работающего кластера (не первой установки)
Prometheus Operator может пересоздать под Prometheus дважды; на 2 vCPU
второй перезапуск ждёт завершения первого до ~10 мин, и проверки шага 7
до этого не проходят — повторите `make verify` через несколько минут. Там
же, на 2 vCPU / 4 ГБ, при таком обновлении (перезапускается почти всё)
бывают однократные перезапуски контроллеров (kube-controller-manager,
kube-scheduler, контроллер Envoy Gateway по liveness) из-за медленного
etcd; они поднимаются сами, `make verify` после этого зелёный. На 4/8 этого
не видели.

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

Rate limit (путь `/limited` — 10 запросов в минуту на каждую из двух
реплик Envoy, дальше 429; основной маршрут ограничен 500 запросами в секунду
на реплику и обычным трафиком не упирается). Один `curl` держит одно
соединение, то есть одну реплику:

```bash
c -w '%{http_code}\n' $(for i in $(seq 15); do echo "-o /dev/null https://app.demo.local/limited"; done) | sort | uniq -c
#  10 200
#   5 429
```

Заголовки, зеркало и таймауты (стандартные фильтры Gateway API в правилах
HTTPRoute `app`):

```bash
c -sI https://app.demo.local/ | grep -iE 'x-gateway-route|x-backend-pod|^server'
# x-gateway-route: weighted    — добавлен ResponseHeaderModifier;
# x-backend-pod и server Angie убраны им же
c -sI https://app.demo.local/v2 | grep -i x-gateway-route    # path-v2

# RequestHeaderModifier: поддельное значение клиента заменено именем правила,
# RequestMirror: копия запроса ушла в web-v2 на теневой порт 8081
c -H 'X-Gateway-Route: forged' -H 'X-Request-ID: mirror-1' https://app.demo.local/
kubectl -n demo logs -l app.kubernetes.io/name=demo-app --tail=-1 | grep mirror-1
# {..."gateway_route":"weighted","traffic":"app","version":"v1"...}     — ответ клиенту
# {..."gateway_route":"weighted","traffic":"shadow","version":"v2"...}  — зеркало, ответ отброшен

# таймауты: timeouts.request 10s в HTTPRoute, на попытку — 3s (BackendTrafficPolicy)
kubectl -n gateway get httproute app -o jsonpath='{.spec.rules[*].timeouts}'; echo
```

Зеркальные копии Angie считает в отдельной зоне `shadow`, а Envoy — в
отдельном кластере `…/rule/2-mirror-2`, поэтому ни раскладка canary, ни
SLO и алерты их не учитывают. Зеркалируется 100 % запросов правила `/`
любым методом (в том числе POST): для демо-приложения без состояния это
безопасно, для настоящего сервиса с записью зеркало надо ограничивать
(`fraction`/`percent` в `RequestMirror`, отдельное правило для GET).

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
# для графиков и PromQL: 10 запросов и подождать 60 с (сбор раз в 30 с)
for i in $(seq 10); do c -o /dev/null https://app.demo.local/broken; done; sleep 60
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
| UI трейсов (VictoriaTraces, если включён трейсинг) | `https://traces.demo.local/select/vmui/` | тот же basic auth | только `/select/*` (UI, Jaeger API, LogsQL API) |

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
строку `<IP узла> app.demo.local grafana.demo.local prometheus.demo.local alertmanager.demo.local logs.demo.local traces.demo.local`
и импортируйте `ca.crt` (или согласитесь с предупреждением браузера). Для
curl хватает `--resolve`, как выше.

### Мониторинг (Prometheus, шаг 7)

kube-prometheus-stack ставит Prometheus Operator, Prometheus (интервал
сбора 30 с, хранение 3 дня, но не больше 3 ГБ, PVC 4 ГиБ на local-path),
Alertmanager (1 реплика, получатель — webhook в кластере, см. «Доставка
алертов»), Grafana, node-exporter и
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
| `victoria-traces` (если включён трейсинг) | хранилище трейсов: принятые спаны (`vt_rows_ingested_total{type="opentelemetry_traces_otlpgrpc"}`), запросы, диск; со стороны Envoy — кластер `tracing` в его метриках (`envoy_cluster_upstream_rq_total{envoy_cluster_name="tracing"}`) |
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
sum(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"})
sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"}[5m]))
# canary-раскладка: запросы по версиям (счётчики Angie)
sum by (version) (rate(angie_http_server_zones_requests_total{namespace="demo", zone="app"}[5m]))
# p95 времени ответа приложения, мс (гистограмма Envoy)
histogram_quantile(0.95, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"}[5m])))
# доля 5xx за 10 мин и отказы rate limit (429); серия 5xx появляется
# с первым ответом 5xx (например, после 10 запросов к /broken, см. выше)
sum(increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+", envoy_response_code_class="5"}[10m]))
  / sum(increase(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/gateway/app/rule/[0-9]+"}[10m]))
sum(increase(envoy_http_local_rate_limit_rate_limited[1h]))
# SLO: доля ошибок за 1 ч и скорость расхода бюджета (1 = ровно за 30 дней)
slo:sli_error:ratio_rate1h
slo:sli_error:ratio_rate1h / on (slo) slo:error_budget:ratio
# Gateway запрограммирован (1 = True)
gatewayapi_gateway_status{type="Programmed"}
```

Чтобы увидеть рост счётчика: выполнить первый запрос, отправить пачку
запросов (цикл из раздела «Canary»), подождать 30 с и повторить.

**Grafana.** Дашборд **Gateway / SLO**: SLI доступности и задержки за
выбранный интервал, цель, остаток бюджета ошибок (по темпу последних 3 дней
— столько хранит Prometheus), burn rate по окнам 5 мин / 1 ч / 6 ч / 1 д /
3 д с порогами алертов, сработавшие SLO-алерты; RPS, коды ответов, p95 и
p99 по каждому правилу каждого маршрута (включая зеркало), 429 по репликам
Envoy, число живых реплик. Все запросы панелей проверены на стенде через API
Prometheus (данные есть после трафика `make verify`; окно 5 мин без трафика
даёт пустую линию — делить нечего). Дашборд **Demo app — golden signals** (папка General): запросы
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
| `FluentdBufferErrors`, `FluentdBufferAlmostFull` | ретраи/ошибки отправки за 10 мин; буфер заполнен больше чем на 80 % |
| `EtcdMetricsMissing` | метрики etcd (через прокси) не собираются 5 мин |
| `TracingNoSpans` (если включён трейсинг) | приложение получает запросы через Gateway, а VictoriaTraces 5 мин не принимает ни одного спана или недоступна — по аналогии с `FluentdNoOutput`, судим по принимающей стороне; 4 сценария `promtool test rules` в `tests/prometheus/tracing.test.yaml` |
| `AppAvailabilityBudgetBurnFast` / `…Slow` | SLO 99,9 % ответов без 5xx (30 дней): бюджет ошибок тратится в 14,4× быстрее за 1 ч и 5 мин или в 6× за 6 ч и 30 мин (critical); в 3× за 1 д и 2 ч или в 1× за 3 д и 6 ч (warning) — схема multi-window multi-burn-rate из Google SRE Workbook |
| `AppLatencyBudgetBurnFast` / `…Slow` | SLO 99 % запросов быстрее 250 мс (время ответа приложения по гистограмме Envoy), те же окна и пороги |

SLO считаются по записанным правилам `slo:sli_error:ratio_rate<окно>`
(5m … 3d) только для маршрута приложения (зеркало и UI не входят); без
запросов в окне значения нет вовсе (не NaN), и панели пишут «no requests».
Алерты срабатывают только при трафике не меньше 0,01 запроса/с в длинном
окне (36 в час, `slo.minRequestRate`): пара ошибок в простаивающем
демо-кластере — не авария. Запрос, оборванный таймаутом (504), считается
ошибкой доступности, а в SLI задержки не попадает. Логику алертов
проверяют unit-тесты `tests/prometheus/slo.test.yaml` (`promtool test
rules` в `make lint`, 11 сценариев): 5 % ошибок → fast и slow; 0,5 % →
только slow; 0,7 % → fast через пару 6 ч / 30 мин; ошибки час назад, а
короткие окна уже чистые → fast нет; ошибки зеркала и других маршрутов →
ничего; трафик ниже порога → ничего; нет трафика → ни значения, ни алерта
(и для задержки); 20 % медленных запросов → fast по задержке; граница
гистограммы `250` и `250.0` дают одно и то же.

`FluentdBufferErrors` смотрит на рост счётчиков ретраев за 10 минут, поэтому
после простоя VictoriaLogs или перезагрузки узла он может гореть ещё до
~10 мин после восстановления, хотя логи уже доставлены (буфер
дозагрузился) — это ожидаемо.

**Доставка алертов.** Alertmanager отправляет все алерты (кроме служебного
`InfoInhibitor`) в webhook-получатель внутри кластера — Deployment
`monitoring/alert-receiver`: скрипт на стандартной библиотеке Python
(`charts/observability-extras/files/alert_receiver.py`, unit-тесты в
`tests/`), образ `python` по digest, Pod Security `restricted`, принимать
запросы разрешено только от Alertmanager (NetworkPolicy). Каждый алерт он
пишет одной JSON-строкой в stdout, Fluentd разбирает её в поля
(`alertname`, `status`, `severity`, `labels.*`), и алерты ищутся в
VictoriaLogs рядом с логами. Watchdog (горит всегда) уходит туда каждые
~5 мин — это сквозная проверка цепочки Prometheus → Alertmanager →
получатель → Fluentd → VictoriaLogs, её делает `make verify`:

```logsql
_time:15m kubernetes.container_name:receiver alertname:Watchdog
kubernetes.container_name:receiver status:firing severity:critical
```

**`kubectl top`.** metrics-server (kube-system) отдаёт Resource Metrics
API: `kubectl top nodes`, `kubectl top pods -A`. Флага
`--kubelet-insecure-tls` нет: kubelet получает серверный сертификат от CA
кластера (`serverTLSBootstrap`, см. «Особенности»), а сертификат самого
metrics-server выпускает cert-manager, и API-сервер его проверяет.

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

### Трейсинг (шаг 10)

**Зачем.** Метрики говорят «стало медленно», логи — что было в одном
месте; трейс связывает запрос целиком: что сделал Gateway (какой маршрут,
сколько ждал бэкенд, ушла ли копия в зеркало) и какой бэкенд ответил, — и
по `trace_id` ведёт к строкам логов Envoy и Angie этого запроса.

**Как устроено.**

```mermaid
flowchart LR
  C[клиент<br/>traceparent или без него] --> E[Envoy Gateway<br/>спан ingress + egress<br/>sampling 100 %]
  E -->|traceparent<br/>тот же trace ID| A[Angie web-v1/v2<br/>trace_id в JSON access-логе]
  E -->|OTLP/gRPC :4317<br/>раз в 5 с| T[(VictoriaTraces<br/>3 дня, ≤ 1 ГБ)]
  E -->|access-лог: trace_id| F[Fluentd] --> L[(VictoriaLogs)]
  A --> F
  G[Grafana] -->|Jaeger API| T
  G -->|LogsQL| L
```

- **Источник спанов — Envoy** (`EnvoyProxy.spec.telemetry.tracing`,
  провайдер OpenTelemetry): на каждый запрос спан `ingress` (сервер) и
  спан к бэкенду `router … egress` (и `mirror` для теневой копии). Входящий
  W3C `traceparent` продолжается (тот же trace ID), без него Envoy начинает
  новый трейс; бэкенду уходит `traceparent` со спаном Envoy как родителем.
  Теги: `gateway.route` (маршрут Envoy, `httproute/gateway/app/rule/2/…`),
  `gateway.rule` (имя правила: `weighted`, `path-v2`, …), `backend.version`
  (из заголовка ответа Angie `X-App-Version`), плюс штатные `http.url`,
  `http.status_code`, `upstream_address`, `guid:x-request-id`. Sampling
  100 %: трафика в демо мало, и `make verify` должен найти свой запрос; под
  реальной нагрузкой разумно 1–10 % (`tracing.samplingRate` в
  `charts/gateway/values.yaml`).
- **Без OTel Collector.** Envoy отправляет спаны пачками сам (буфер, сброс
  раз в 5 с), хвостовая выборка (tail sampling) при 100 % не нужна, а
  Collector — это ещё ~100 МБ памяти и ещё один компонент. Envoy пишет
  прямо в VictoriaTraces по OTLP/gRPC (Service с `appProtocol: grpc` — иначе
  Envoy Gateway говорил бы с ним по HTTP/1.1). Внутри кластера gRPC без TLS,
  как Fluentd → VictoriaLogs; принимать спаны NetworkPolicy разрешает
  только Envoy-прокси.
- **Angie** своих спанов не создаёт: в образе `angie:*-minimal` нет
  динамических модулей (модуль OpenTelemetry — отдельный пакет, с ним
  пришлось бы брать другой образ). Он берёт trace ID из `traceparent`
  (`map` по регулярному выражению W3C) и пишет его в JSON access-лог полем
  `trace_id`; то же поле (`%TRACE_ID%`) — в access-логе Envoy. Так лог и
  трейс связаны честно, без «рисованных» спанов приложения.
- **Хранилище — VictoriaTraces** (single node, Deployment с PVC local-path
  на control plane, namespace `tracing`, Pod Security `restricted`). Почему
  оно, а не Tempo или Jaeger:

  | | VictoriaTraces 0.11.1 | Grafana Tempo (single binary) | Jaeger v2 (на базе OTel Collector) |
  |---|---|---|---|
  | память на одном узле | ~10–30 МиБ на демо-трафике (у нас); по данным разработчиков в 3,7× меньше Tempo | сотни МиБ (ingester, блоки в памяти) | ~100+ МиБ (Collector + Badger) |
  | приём | OTLP gRPC и HTTP | OTLP, Jaeger, Zipkin | OTLP, Jaeger, Zipkin |
  | Grafana | встроенный datasource Jaeger (Jaeger query API), трейс ↔ логи с VictoriaLogs | свой datasource (TraceQL) | встроенный datasource Jaeger |
  | стиль платформы | та же экосистема и тот же движок хранения, что у VictoriaLogs: флаги, метрики, ретеншн по диску, vmui | отдельная экосистема | отдельная экосистема |
  | зрелость | молодой проект (с 2025, версия 0.x) | зрелый (3.x) | зрелый (2.x) |
  | лицензия | Apache 2.0 | AGPL 3.0 | Apache 2.0 |

  Решили память на 8-гигабайтном узле и единый стиль с VictoriaLogs;
  молодость VictoriaTraces компенсирована тем, что Grafana с ним работает
  через стабильный Jaeger API, а не через собственный плагин. Хранение 3
  дня, не больше 1 ГБ на диске (PVC 2 ГиБ). Метрики — ServiceMonitor, алерт
  `TracingNoSpans` (см. «Мониторинг»).
- **Grafana**: источник `Traces` (тип Jaeger, `…/select/jaeger`); у спана
  кнопка «Related logs» открывает в VictoriaLogs записи с тем же
  `trace_id:="<id>"` (Envoy и Angie, `tracesToLogsV2`); у записи лога с
  полем `trace_id` в VictoriaLogs — ссылка «View trace» (derived field
  плагина VictoriaLogs). На дашборде «Demo app — golden signals» — панель
  «Traced requests» (access-лог Angie с `trace_id`) и ссылка «Traces
  (Explore)» вверху.

**Включение и выключение.** Переменная `TRACING` (окружение `./deploy.sh`
/ `make deploy` / `make platform`):

| `TRACING` | что будет |
|---|---|
| `auto` (по умолчанию) | включён, если у узла control plane не меньше 5632 МиБ памяти (так ядро показывает ВМ на 6 ГБ; ВМ на 8 ГБ — ~7,9 ГиБ, на 4 ГБ — ~3,8 ГиБ). Решение — по памяти control plane: VictoriaTraces живёт там (её том привязан к узлу) |
| `true` | включён всегда (например, на 4 ГБ: доступной памяти остаётся ~0,57 ГБ вместо ~0,69, проверено) |
| `false` | выключен; если был включён — всё удаляется |

`make platform` печатает решение (`==> tracing: on (TRACING=auto, control
plane memory 7941 MiB >= 5632 MiB)`), `make status` — что развёрнуто
сейчас. Выключение удаляет релиз VictoriaTraces (вместе с томом и
данными), namespace `tracing`, его NetworkPolicy, маршрут
`traces.demo.local`, источник `Traces` в Grafana (у него `prune: true`) и
блок `tracing` в EnvoyProxy (без перезапуска подов Envoy: это xDS); поле
`trace_id` в access-логах при этом пустое (VictoriaLogs пустые поля не
хранит). Проверить, что ничего не осталось:

```bash
TRACING=false make platform
kubectl get ns tracing                     # NotFound
kubectl get pv | grep tracing              # пусто
kubectl -n envoy-gateway-system get envoyproxy node-lb -o jsonpath='{.spec.telemetry.tracing}'   # пусто
make verify                                # шаг 10: «- Tracing  tracing is off (…)»
TRACING=true make platform                 # обратно; повтор — без изменений
```

Без кластера (`make lint`, `make images-list`) рендер всегда с трейсингом —
его манифесты тоже проверяются; если кластер в kubeconfig есть, но
прочитать узел нельзя, `TRACING=auto` останавливает развёртывание, а не
угадывает.

**Как найти трейс своего запроса** (на узле, `c` и `ca.crt` — как в
разделе «Gateway и приложение»):

```bash
TID=$(openssl rand -hex 16)
c -H "traceparent: 00-$TID-$(openssl rand -hex 8)-01" https://app.demo.local/
sleep 15            # Envoy сбрасывает спаны раз в 5 с, VictoriaTraces прячет последние 10 с
T="curl -s --resolve traces.demo.local:443:$IP --cacert ca.crt -u admin:<пароль>"
$T https://traces.demo.local/select/jaeger/api/traces/$TID \
  | jq -c '.data[0].spans[] | {op: .operationName, tags: [.tags[] | select(.key | test("gateway|backend|status")) | "\(.key)=\(.value)"]}'
# {"op":"ingress","tags":["gateway.route=httproute/gateway/app/rule/2/match/0/app_demo_local","gateway.rule=weighted","backend.version=v1","http.status_code=200"]}
# {"op":"router httproute/gateway/app/rule/2 egress", ...}
# тот же запрос в логах (Envoy и Angie):
$L https://logs.demo.local/select/logsql/query --data-urlencode "query=trace_id:=\"$TID\"" \
  | jq -c '{c: ."kubernetes.container_name", trace_id, version, traffic}'
```

Запрос без `traceparent` тоже трассируется: его trace ID — в поле
`trace_id` access-логов (найти запрос по `X-Request-ID` в VictoriaLogs →
взять `trace_id` → «View trace»). В Grafana: Explore → `Traces` → вкладка
TraceID (ввести ID) или Search (сервис `envoy-gateway`).

**Свой `X-Request-ID` — только UUID.** Envoy принимает решение о
трассировке по `X-Request-ID`: признак «трассировать» упакован в UUID, и
запрос с произвольным ID (например, `verify-…` шага 6 или `check-…` из
раздела «Логи») Envoy не трассирует вовсе — даже с `traceparent`. Запрос
без своего ID (Envoy создаёт UUID сам) или с UUID трассируется. Отключить
это в Envoy Gateway 1.9 можно только патчем xDS (EnvoyPatchPolicy) — не
делали. Чтобы ссылки не вели в пустоту, Angie пишет `trace_id` только для
трейсов с флагом sampled; в access-логе Envoy поле есть всегда.

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

## Несколько узлов

По умолчанию кластер одноузловой, и всё выше относится к нему. К нему можно
добавить воркеры: теми же ролями Ansible (`node_prep`, `node_firewall`,
`containerd`, `kube_packages`) узел готовится, затем присоединяется
`kubeadm join`. Команда запускается на control plane после `./deploy.sh`:

```bash
# на control plane; воркер — Ubuntu 24.04 amd64, доступ по SSH, sudo без пароля
make add-worker WORKER=192.0.2.21 WORKER_USER=ubuntu SSH_KEY=~/.ssh/id_ed25519
kubectl get nodes -o wide
make verify                    # шаг 9 проверяет каждый узел

make remove-worker WORKER=192.0.2.21   # вывести воркер обратно
```

Ключ воркера должен быть в `~/.ssh/authorized_keys` пользователя на воркере,
а его host key — известен (один раз `ssh ubuntu@192.0.2.21`). Несколько
воркеров — копией `ansible/inventory/multinode.example.yml`:
`make add-worker INVENTORY=ansible/inventory/multinode.yml` (а вывести всех
воркеров такого inventory — `make remove-worker INVENTORY=… FORCE=1`).

Как устроено:

- **Токен присоединения.** На control plane создаётся bootstrap-токен
  `kubeadm token create --ttl 15m` только для этого присоединения. Он
  попадает на воркер в файле `JoinConfiguration` с правами 0600, который
  удаляется сразу после `kubeadm join`, и сразу же удаляется из кластера
  (`kubeadm token delete`). В git, командную строку и вывод Ansible токен не
  попадает (`no_log`). Сертификат CA проверяется по хешу открытого ключа
  (`caCertHashes`). Если связь с воркером оборвалась посреди присоединения,
  токен удалит следующий запуск (в начале и в конце `make add-worker`
  удаляются все токены с описанием `kubeadm-gateway: join`), а не удалённый
  никем живёт не дольше 15 минут. Токен самого `kubeadm init` тоже живёт
  15 минут, а не 24 часа по умолчанию.
- **Проверки до изменений.** Сначала проверяются SSH, ОС (Ubuntu, amd64; не
  24.04 — предупреждение, как на control plane) и состояние узла; при любой
  проблеме команда останавливается, ничего не изменив: воркер недоступен по
  SSH; с воркера не открывается API-сервер (TCP 6443); WORKER — это сам
  control plane; на узле есть свой control plane; узел уже в другом кластере
  (другой адрес API-сервера или CA, в том числе от недоделанного join);
  имена воркеров в inventory повторяются; имя узла уже занято в кластере;
  узел присоединялся раньше, но его Node удалён. Сообщение объясняет, что
  сделать.
- **Прерванное присоединение.** Если `kubeadm join` этого кластера
  остановился после своих preflight-проверок (обрыв сети, прерванный
  запуск), на воркере остаются CA кластера, bootstrap-kubeconfig и
  конфигурация kubelet, но нет `kubelet.conf`. Повторный `make add-worker`
  распознаёт такой узел (CA совпадает с CA кластера), делает на нём
  `kubeadm reset` и присоединяет заново.
- **Cordoned-воркер** (`kubectl cordon`) остаётся таким: повторный
  `make add-worker` проходит и только напоминает про `kubectl uncordon`;
  при перераспределении реплик такие узлы не учитываются.
- **Идемпотентность.** Присоединённый узел повторно не трогается: повторный
  `make add-worker` и `./deploy.sh` на control plane дают `changed=0`,
  ревизии Helm не меняются.
- **Память control plane о воркерах.** Имена и адреса воркеров из фактов
  Ansible сохраняются на control plane в `/etc/kubeadm-gateway/workers.json`
  (0600). Поэтому обычный `./deploy.sh` на control plane (inventory —
  только он сам) не теряет воркеры: одобритель сертификатов kubelet и
  nftables продолжают их знать. На одном узле файла нет, и всё работает
  ровно как раньше.
- **Сертификат kubelet воркера** (`serverTLSBootstrap` приходит из ConfigMap
  `kube-system/kubelet-config`) одобряет тот же скрипт с теми же проверками:
  в сертификате только имя воркера и его IP из фактов Ansible. Продление —
  ежечасным таймером на control plane. Отсюда работают `kubectl logs`,
  `kubectl exec` и `kubectl top` для воркера без `--kubelet-insecure-tls`.
- **Порты метрик (nftables).** Под с другого узла ходит к портам узла с
  адресом своего узла (маскарадинг Cilium): Prometheus на control plane
  скрейпит node-exporter и Cilium воркера с адреса `192.0.2.10`, а не из
  сети подов. Так же, с адреса узла, cilium-health проверяет соседей на
  порту 4240. Поэтому в таблицу `kubeadm_gateway_metrics` воркера
  добавлены адреса control plane и воркеров, известных на момент его
  присоединения, а в таблицу control plane — адреса всех воркеров. Таблицы
  уже присоединённых воркеров при добавлении следующего обновляются, только
  если они тоже перечислены в inventory (multinode); с `WORKER=` — нет. Для
  сбора метрик это не важно (Prometheus работает на control plane), а
  проверки cilium-health между двумя воркерами без этого получают отказ —
  перечисляйте всех воркеров в inventory. Для остальной сети порты
  по-прежнему закрыты (проверено с третьей машины: TCP reset на обоих узлах).
- **NetworkPolicy** не менялись. Cilium различает трафик своего узла
  (`host`, всегда разрешён — пробы kubelet) и соседнего (`remote-node`),
  и политики к нему применяются. Проверено: с control plane к поду
  демо-приложения на воркере — отказ (пускают только Envoy), а к правилам
  «отовсюду на порт» (слушатели Envoy, вебхуки cert-manager и Envoy Gateway,
  куда ходит API-сервер) — пропускает. Трафик между подами разных узлов
  несёт identity пода (VXLAN), поэтому правила «от Prometheus»,
  «от Fluentd» и т. п. работают как на одном узле.
- **Gateway.** Cilium node IPAM с `externalTrafficPolicy: Cluster` выдаёт
  Service адрес каждого узла: у Gateway становится два адреса (control plane
  и воркер), запрос на любой из них доходит до любой реплики Envoy. `make
  verify`, `make status`, `make ui` по-прежнему используют адрес control
  plane (он же адрес API-сервера).
- **Реплики Envoy и демо-приложения** разнесены по узлам topologySpread
  (`ScheduleAnyway`, `matchLabelKeys: [pod-template-hash]` — при раскатке
  считаются только поды новой ревизии, иначе старые поды на одном узле
  выталкивают все новые на другой). Планировщик не переносит уже запущенные
  поды, поэтому `make add-worker` в конце перезапускает (rolling, с учётом
  PodDisruptionBudget) те Deployment со спредом по узлам, у которых все поды
  на одном узле; если уже разнесены — ничего не делает. `ScheduleAnyway` —
  пожелание, а не гарантия: планировщик учитывает и другие факторы (ресурсы
  узлов, наличие образа). На стенде реплики каждый раз расходились 1/1; если
  нет — `make verify` (шаг 9) это покажет, повторный `make add-worker`
  перезапустит их снова.
- **DaemonSet'ы** (Cilium, cilium-envoy, Fluentd, node-exporter) сами
  появляются на воркере: логи его подов идут в VictoriaLogs, метрики узла —
  в Prometheus. etcd-metrics-proxy — только на control plane.
- **Control plane остаётся рабочим узлом** (taint и метка
  `exclude-from-external-load-balancers` сняты, как на одном узле): тома
  local-path Prometheus и VictoriaLogs созданы на нём и к нему привязаны
  (PV с nodeAffinity), а Gateway сохраняет адрес control plane.
- **`make remove-worker`**: drain (DaemonSet'ы пропускаются, PDB
  соблюдаются), сброс воркера тем же `scripts/destroy.sh`, что и
  `make destroy`, удаление Node, затем control plane забывает воркер
  (nftables, одобритель). Хост трогается, только если он доказуемо воркер
  этого кластера: его `kubelet.conf` смотрит в этот API-сервер, CA на нём
  совпадает с CA кластера (sha256), Node ищется по адресам самого хоста (а
  не по имени: у другой машины может быть такое же), и control plane на нём
  нет. Иначе команда останавливается до drain: «Nothing has been changed».
  Control plane и узел с томами local-path команда выводить отказывается
  (данные лежат только на нём). Недоступный по SSH воркер ищется по адресу
  из WORKER и всё равно выводится из кластера, сбросить его нужно позже
  вручную (`sudo kubeadm reset`). На воркере после вывода остаётся то же,
  что после `make destroy`: пакеты kubeadm/kubelet/kubectl (kubelet
  остановлен), containerd и runc, кэш загрузок, sysctl и модули ядра, apt
  pinning; стёрты состояние kubeadm и kubelet, Cilium, правила iptables,
  таблица nftables, логи подов и состояние Fluentd.

Проверено на стенде: control plane 4 vCPU / 8 ГБ + воркер 2 vCPU / 4 ГБ
(Ubuntu 24.04.5). `make add-worker` — 1,5–2 мин (на воркере уже стояли
пакеты после `make destroy`; на новой машине добавится их загрузка, как в
первом `./deploy.sh`); `make verify` — 32 ✓ и 1 пропуск; повторный
`make add-worker` и повторный `./deploy.sh` — `changed=0`, ревизии Helm
те же; перезагрузка воркера — через ~1 мин снова `Ready`, `make verify`
зелёный; `make remove-worker` — около минуты, на воркере не осталось
kubelet, Cilium и nftables-таблицы, одноузловой `make verify` зелёный
(26 ✓). Отказы и восстановление: хост вне кластера с тем же именем, что у
узла кластера, — `remove-worker` ничего не трогает; хост с адресом узла, но
с `kubelet.conf` другого кластера, — отказ до drain; прерванный join —
повторный `make add-worker` сбрасывает остатки и присоединяет узел, забытый
токен удаляется; cordoned-воркер — `make add-worker` проходит с
`changed=0`; cilium-health между узлами — все проверки OK при закрытом для
сети порте 4240.

Ограничения: один control plane (etcd без HA: потеря control plane — потеря
кластера); тома local-path привязаны к узлу, на котором созданы; воркеры —
Ubuntu 24.04 amd64 в одной сети с control plane (нужны TCP 6443, 10250 и
UDP 8472 между узлами); `make destroy` на control plane воркеры не
сбрасывает (предупреждает о них) — сначала `make remove-worker`; e2e в CI
проверяет только одноузловой сценарий.

## CI/CD

Два workflow GitHub Actions на раннерах `ubuntu-24.04`:

- [`lint`](https://github.com/Kurligin/kubeadm-gateway-observability/actions/workflows/lint.yml)
  ([`.github/workflows/lint.yml`](.github/workflows/lint.yml)) — на каждый
  push и на pull request из форков (PR из веток репозитория уже проверены
  push'ем): `make lint-deps && make lint`, то есть всё, что
  проверяется локально, и падает, если какая-то проверка пропущена.
  Проверки отрендеренных манифестов (`helmfile template`, без кластера,
  [`scripts/check-manifests.sh`](scripts/check-manifests.sh)):
  - **kubeconform** — каждый объект по схемам Kubernetes 1.36.5 и CRD, в
    строгом режиме (неизвестное поле — ошибка). Схемы CRD генерируются из
    тех самых CRD, что ставятся в кластер (Gateway API и Envoy Gateway
    тоже), — версии схем и CRD не расходятся. Пропускаются только сами
    объекты CustomResourceDefinition: для них схемы не публикуются.
  - **trivy config** — ошибки конфигурации: HIGH и CRITICAL во всех
    релизах, для своих чартов ещё и MEDIUM. Принятые находки (права
    контроллеров, доступ Cilium и node-exporter к узлу и т. п.) — в
    [`.trivyignore.yaml`](.trivyignore.yaml), у каждой записано обоснование.
  - **kube-linter** — все встроенные проверки по своим чартам; отключённые
    проверки и причины — в [`.kube-linter.yaml`](.kube-linter.yaml),
    единичные исключения — аннотацией на самом объекте с причиной.

  Версии и sha256 инструментов — в `versions.env`, actions закреплены по
  SHA коммита (их обновления раз в неделю предлагает Dependabot,
  [`.github/dependabot.yml`](.github/dependabot.yml), без автослияния), у
  токена только чтение.
- [`e2e`](https://github.com/Kurligin/kubeadm-gateway-observability/actions/workflows/e2e.yml)
  ([`.github/workflows/e2e.yml`](.github/workflows/e2e.yml)) — на push в
  `main` и вручную: на чистом раннере, как эксперт: `./deploy.sh` (кластер
  kubeadm на самом раннере) → `make verify` → проверка таймера одобрения
  сертификатов kubelet → повторный `./deploy.sh`, который ничего не должен
  изменить (Ansible `changed=0`, helmfile не обновил ни одного релиза,
  ревизии Helm те же — [`scripts/check-idempotency.sh`](scripts/check-idempotency.sh))
  → `make verify` ещё раз. При падении поды, события, `describe` и логи
  неготовых подов, журналы kubelet и containerd собираются в артефакт
  ([`scripts/collect-diagnostics.sh`](scripts/collect-diagnostics.sh)).
  Перед развёртыванием workflow освобождает место на диске раннера (из
  ~14 ГБ свободных kubelet начал бы выселять поды). Проверка «Cilium
  metrics :9962 closed to the LAN» на раннере пропускается с причиной:
  `make verify` идёт на самом узле, где порт открыт намеренно.
  Полный прогон на раннере (2 vCPU / 7 ГБ) — ~12 мин: очистка диска ~3,5
  мин, `./deploy.sh` ~6,5 мин, `make verify` ~20 с (26 ✓, 1 пропуск),
  повторный `./deploy.sh` ~1 мин — замер до трейсинга; на раннере с 7 ГБ
  `TRACING=auto` его включает, это ещё релиз VictoriaTraces и 3 проверки
  шага 10.

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
  9965 (Hubble), 4240 (API cilium-health), без аутентификации; node-exporter
  — 9100 и 8888 (`/healthz` прокси). Роль Ansible `node_firewall` ставит
  свою таблицу nftables (`inet kubeadm_gateway_metrics`, юнит
  `kubeadm-gateway-metrics-firewall`, переживает перезагрузку): на эти порты
  пускают только сам узел, сеть подов (`10.244.0.0/16`, откуда ходит
  Prometheus) и другие узлы кластера, если они есть, остальным — TCP reset.
  Остальные порты и правила (SSH, 6443, 80/443, Cilium) таблица не трогает.
  Выбрали nftables, а не host firewall Cilium: тот при первой же политике
  узла запрещает всё, что не разрешено явно (риск отрезать SSH и
  kubelet), а здесь правило одно и узкое. Проверка с другой машины:
  `curl http://$IP:9962/metrics` → `Connection refused`. `make destroy`
  снимает таблицу.
- **Pod Security по namespaces.** `restricted` — `demo`, `gateway`,
  `envoy-gateway-system`, `cert-manager`, `monitoring` (Prometheus,
  Alertmanager, Grafana, оператор, kube-state-metrics), `logging`
  (VictoriaLogs) и `tracing` (VictoriaTraces, если трейсинг включён). Компонентам уровня узла нужен хост, а это запрещает даже
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
  `logging`, `logging-node`, `tracing`) входящий трафик запрещён по умолчанию
  (`default-deny-ingress`), разрешено только:

  | Куда | Откуда |
  |---|---|
  | приложение `demo`, порты 8080 и 8081 (зеркало) | Envoy-прокси Gateway |
  | получатель алертов `alert-receiver` 8080 | Alertmanager |
  | метрики всех компонентов (Angie 9113, Envoy 19001, cert-manager 9402, Fluentd 24231, VictoriaLogs 9428, всё в `monitoring`) | Prometheus |
  | Prometheus 9090, Alertmanager 9093 | Grafana, Envoy-прокси (UI) |
  | Grafana 3000 | Envoy-прокси (UI) |
  | VictoriaLogs 9428 | Fluentd (запись), Grafana и Envoy-прокси (чтение), Prometheus |
  | VictoriaTraces 4317 (OTLP/gRPC, запись) | только Envoy-прокси |
  | VictoriaTraces 10428 (запросы, UI, метрики) | Grafana, Envoy-прокси (UI), Prometheus |
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
- **Сертификаты kubelet от CA кластера.** По умолчанию kubelet подписывает
  свой HTTPS-сертификат сам, и проверить его нельзя (отсюда популярный
  `--kubelet-insecure-tls` у metrics-server). Здесь в KubeletConfiguration
  включён `serverTLSBootstrap: true`: kubelet запрашивает сертификат у CA
  кластера (CSR, signer `kubernetes.io/kubelet-serving`). Такие запросы
  Kubernetes сам не одобряет — запрос доказывает только, какой узел его
  прислал, но не то, что имена в нём принадлежат узлу. Одобряет скрипт
  `ansible/roles/kubeadm_init/files/approve-kubelet-serving-csr.sh`: запрос
  от `system:node:<имя>` проходит, только если узел с таким именем есть в
  inventory Ansible, subject — `CN=system:node:<имя>, O=system:nodes`, а в
  сертификате только имя этого узла и его IP из фактов Ansible (IPv6
  сравниваются в нормализованном виде); остальное остаётся pending с
  сообщением. Список узлов (`/etc/kubeadm-gateway/kubelet-serving-nodes.json`,
  0600) пишется на каждом деплое из хостов inventory и воркеров, известных
  control plane (см. «Несколько узлов»). Скрипт запускают каждый `make
  deploy` и раз в час systemd-таймер `kubeadm-gateway-kubelet-cert-approver.timer` на control
  plane — так продление сертификата (kubelet просит новый на 70–90 % срока
  в год) одобряется и без деплоя; `make destroy` таймер снимает. Для уже
  созданного кластера та же задача включает настройку на узле и в ConfigMap
  `kube-system/kubelet-config` (её берут `kubeadm upgrade` и новые узлы) и
  перезапускает kubelet — поды при этом не останавливаются. Если прогон
  прервали между правкой конфига и перезапуском, следующий прогон увидит
  «настройка есть, сертификата и запроса нет» и перезапустит kubelet сам.
  Отдельный контроллер-одобритель (kubelet-csr-approver) не ставили: это
  ещё один под на узле, где памяти впритык.
- **Образы по digest.** Каждый образ задан как `tag@sha256:…` (digest
  мультиархитектурного индекса): в `versions.env` — `<ИМЯ>_DIGEST` для
  образов, чей тег уже есть там как версия, и `<ИМЯ>_IMAGE` (тег и digest)
  для образов, чей тег — значение по умолчанию чарта. Где чарт умеет поле
  digest/sha (cert-manager, kube-prometheus-stack, Grafana,
  kube-state-metrics, node-exporter), задаётся оно; где нет
  (local-path-provisioner, VictoriaLogs, metrics-server, Envoy Gateway) —
  `tag@digest` в поле тега или образа. Чарт Cilium сам прописывает digest
  своих образов. Исключение — образы control plane kubeadm (`kube-apiserver`,
  `etcd`, `coredns`, `pause`): kubeadm берёт их по тегу версии Kubernetes и
  digest задать не позволяет. `make lint` рендерит все релизы
  (`helmfile template` без кластера) и падает, если хоть у одного образа —
  включая встроенные в аргументы операторов и конфиги, например образ
  config-reloader и shutdown-manager Envoy, — нет digest или если
  `images.txt` устарел. `make images` скачивает список в containerd
  (`ctr -n k8s.io images pull` по `repo@sha256`, ровно под теми именами, что
  ищет kubelet), повторяя загрузку при сбое; образы, которые только
  упоминаются, но не запускаются (rate limit Envoy Gateway, ACME-solver
  cert-manager, Thanos), закреплены, но не скачиваются.
- **Envoy в двух репликах.** EnvoyProxy: `replicas: 2`, PodDisruptionBudget
  `minAvailable: 1`, rolling update `maxUnavailable: 0` / `maxSurge: 1`,
  topologySpread по узлам (`ScheduleAnyway`: на одном узле обе реплики
  рядом). Обе стоят за одним Service LoadBalancer (Cilium node IPAM), адрес
  Gateway — по-прежнему IP узла.
- **Приложение без root.** Angie работает от пользователя образа (uid 100),
  корневая ФС только для чтения (pid и временные файлы — в emptyDir),
  capabilities сброшены, seccomp `RuntimeDefault`; порты 8080 (HTTP) и 9113
  (метрики). Ответ `Hello World! version=v1 pod=<имя пода>` задан в конфиге
  (ConfigMap на каждую версию).

## Ограничения

- **Rate limit локальный, на реплику Envoy**: при двух репликах Gateway
  пропускает до 2× лимита. Общий лимит потребовал бы сервис rate limit
  Envoy Gateway и Redis — не делали.
- **Один control plane, IPv4, amd64.** Воркеры добавляются
  (`make add-worker`, см. «Несколько узлов»), но control plane один, etcd
  без HA. Адрес API-сервера (IP узла) после создания кластера не меняется,
  см. «Запуск».
- **Плагин VictoriaLogs для Grafana** скачивается с grafana.com при каждом
  старте Grafana (она без PVC: дашборды и источники данных — из
  ConfigMap). Если сайт недоступен, панели логов в Grafana пустые, логи
  смотрятся в vmui и через API.
- **Хранилище — local-path** (каталог на узле): метрики и логи переживают
  перезапуск подов, но не потерю узла.
- **Алерты не уходят за пределы кластера**: единственный получатель —
  webhook, который пишет их в лог (VictoriaLogs); почты, мессенджеров и
  дежурств нет. SLO-бюджет за 30 дней оценивается по темпу последних 3 дней:
  Prometheus хранит 3 дня метрик.
- **Исходящий трафик подов не ограничен** (политики только на входящий).
- **Трейс — это Gateway.** Спаны создаёт только Envoy; у Angie своих спанов
  нет (образ minimal без модуля OpenTelemetry), он связан с трейсом через
  `trace_id` в логе. VictoriaTraces — версия 0.x (молодой проект); Grafana
  работает с ним через стабильный Jaeger API. Sampling 100 % — под
  демо-нагрузку, не под продакшен. На узле control plane меньше 6 ГБ
  трейсинг по умолчанию выключен. Запросы с собственным `X-Request-ID` не
  в формате UUID Envoy не трассирует (см. «Трейсинг»).
- **Сеть при развёртывании.** Короткие сбои сети (репозитории чартов,
  реестры образов) переживаются повторами, но долгий обрыв прерывает
  развёртывание — тогда достаточно запустить `./deploy.sh` ещё раз.
