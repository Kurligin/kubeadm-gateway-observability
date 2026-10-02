# Эксплуатация

Команды, варианты развёртывания и разбор проблем. Обзор — в
[README](../README.md), устройство — в [architecture.md](architecture.md).

- [Команды](#команды)
- [Развёртывание](#развёртывание)
- [IP узла](#ip-узла)
- [Прокси](#прокси)
- [Нет Ubuntu 24.04? `vagrant up`](#нет-ubuntu-2404-vagrant-up)
- [Трейсинг (`TRACING`)](#трейсинг-tracing)
- [Несколько узлов](#несколько-узлов)
- [Образы: `make images`](#образы-make-images)
- [Перезагрузка, обновление, удаление](#перезагрузка-обновление-удаление)
- [Ресурсы: память и диск](#ресурсы-память-и-диск)
- [CI/CD](#cicd)
- [Если что-то пошло не так](#если-что-то-пошло-не-так)

## Команды

| Команда | Что делает |
|---|---|
| `./deploy.sh` / `make deploy` | узел → кластер → платформа; идемпотентно; в конце подсказывает, что дальше |
| `make verify` | сквозная проверка: таблица ✓/✗ с причинами, код возврата ≠ 0 при провале |
| `make status` | узлы и версии, адрес Gateway, трейсинг, ссылки UI, релизы Helm, краткое здоровье (без паролей) |
| `make ui` | адреса UI (Grafana, Prometheus, Alertmanager, vmui, трейсы) и пароли к ним |
| `make ca` | выгрузить корневой сертификат демо-CA в `ca.crt` (для `curl --cacert` и браузера) |
| `make cluster` | только Ansible: узел и кластер |
| `make platform` | только helmfile: платформа и приложение |
| `make add-worker WORKER=<адрес>` | присоединить воркер по SSH |
| `make remove-worker WORKER=<адрес>` | вывести воркер: drain, сброс узла, удаление из кластера |
| `make images` | после `make cluster`: скачать в containerd все образы из `images.txt` (по digest) и образы control plane kubeadm |
| `make images-list` | пересобрать `images.txt` из отрендеренных манифестов (после смены версий в `versions.env`) |
| `make versions` | закреплённые версии из `versions.env` |
| `make destroy FORCE=1` | `kubeadm reset` и очистка следов кластера и Cilium (пакеты и бинарники остаются) |
| `make lint-deps && make lint` | статические проверки без кластера (только Ubuntu amd64; на macOS — внутри ВМ `vagrant up`): shellcheck, yamllint, ansible-lint, `helm lint`, `promtool check/test rules`, ruff/black, unit-тесты Python, digest у каждого образа и актуальность `images.txt`, kubeconform, trivy config, kube-linter |

`make` без аргументов печатает список целей и переменных.

## Развёртывание

```bash
git clone https://github.com/Kurligin/kubeadm-gateway-observability.git
cd kubeadm-gateway-observability
./deploy.sh
```

`deploy.sh` ставит `python3-venv` и `make` (если их нет), создаёт `.venv` с
закреплённой версией ansible-core и вызывает `make deploy`. Запускать можно
от обычного пользователя (если `sudo` спросит пароль, Ansible попросит его
один раз — `BECOME password`) или целиком от root: `sudo ./deploy.sh`,
`sudo make deploy`. Способы можно чередовать: `.venv` всегда принадлежит
владельцу каталога репозитория. `sudo` не передаёт переменные окружения,
поэтому их пишут после него: `sudo NODE_IP=10.0.0.5 ./deploy.sh`.

Время на 4 vCPU / 8 ГБ — 8–10 мин (зависит от сети), на раннере GitHub
2 vCPU / 7 ГБ — ~6,5 мин, на ВМ 2 vCPU / 4 ГБ под Vagrant — ~13 мин.
Повторный запуск — 40–50 с и ничего не меняет (`changed=0`, ревизии Helm те
же).

**Удалённо по SSH (только слой кластера):**
`cp ansible/inventory/remote.example.yml ansible/inventory/remote.yml`,
поправить адрес, затем `make cluster INVENTORY=ansible/inventory/remote.yml`.
Платформу (`make platform`) после этого запускают на самом узле.

## IP узла

IP узла определяется автоматически (интерфейс маршрута по умолчанию). Если
интерфейсов несколько — задайте явно: `NODE_IP=10.0.0.5 ./deploy.sh`.
Адрес задаётся один раз, при создании кластера: kubeadm вшивает его в
сертификаты и kubeconfig. Повторные запуски берут его из существующего
кластера; если `NODE_IP` указан и отличается, развёртывание остановится с
подсказкой и ничего не изменит. Сменить адрес можно только пересозданием:
`make destroy FORCE=1`, затем `./deploy.sh`.

Поэтому узлу нужен **постоянный IP** (статический или резервирование DHCP):
если после перезагрузки он получит другой, control plane не поднимется
(развёртывание это распознает и подскажет, что делать).

## Прокси

Если узел выходит в интернет только через HTTP(S)-прокси, задайте его при
каждом запуске (без этих переменных про прокси ничего не настраивается, а
настройки прошлого запуска с прокси удаляются):

```bash
export HTTP_PROXY=http://proxy.example:3128 HTTPS_PROXY=http://proxy.example:3128
./deploy.sh            # и make verify / make images из той же сессии
```

Годится любое написание (`HTTP_PROXY` или `http_proxy`); `NO_PROXY` можно
дополнить своими адресами.

| Кто ходит в интернет | Как получает прокси |
|---|---|
| `deploy.sh`: apt (`python3-venv`, `make`), pip | переменные окружения (sudo их сохраняет) |
| Ansible: `get_url` (containerd, runc, helm, helmfile, ключ pkgs.k8s.io), apt | окружение плея; apt — `/etc/apt/apt.conf.d/95kubeadm-gateway-proxy` |
| containerd (все образы, в т. ч. для kubeadm) | systemd drop-in → `EnvironmentFile=/etc/kubeadm-gateway/containerd-proxy.env` (0600) |
| helm/helmfile (чарты), `make images` | окружение `make` |
| Grafana (плагин VictoriaLogs с grafana.com) | `HTTP(S)_PROXY` из Secret чарта Grafana (`envRenderSecret`; только при заданном прокси) |

kubelet прокси не нужен: образы тянет containerd. `NO_PROXY` дополняется
автоматически (`scripts/no-proxy.sh`): `localhost`, `127.0.0.1`, все
IPv4-адреса узла, адрес API-сервера, сети подов и сервисов, `.svc`,
`.cluster.local`, `demo.local`. `kubeadm init` запускается без прокси:
иначе kubeadm навсегда вписал бы его в манифесты control plane. Прокси с
логином и паролем поддерживается (спецсимволы — в URL-кодировке, `%` →
`%25`), где хранится пароль — [security.md](security.md#секреты). Запросы
`make verify` к Gateway всегда идут напрямую (`curl --noproxy '*'`). Если
вызываете `kubectl` руками в сессии с `HTTPS_PROXY`, добавьте в `NO_PROXY`
IP узла — иначе запрос к API-серверу уйдёт в прокси.

Проверено: исходящий трафик узла закрыт nftables, открыт только squid на
соседней ВМ; `./deploy.sh` с чистой ОС — 8 мин, `make verify` — все ✓.
Повторный запуск без прокси убрал настройки (changed=3), следующий —
changed=0.

## Нет Ubuntu 24.04? `vagrant up`

[`Vagrantfile`](../Vagrantfile) поднимает ВМ Ubuntu 24.04 (box
`bento/ubuntu-24.04` 202508.03.0), копирует в неё репозиторий и запускает
`./deploy.sh`; Gateway слушает адрес ВМ в private network.

Нужно: amd64 (x86_64) с аппаратной виртуализацией, Vagrant ≥ 2.4 и
VirtualBox ≥ 7 или libvirt/KVM с плагином `vagrant-libvirt`, `rsync`,
~8 ГБ свободной памяти и ~30 ГБ диска. **Apple Silicon (arm64) не
поддерживается**: решение и образы — только amd64.

```bash
vagrant up                                  # VirtualBox
vagrant up --provider=libvirt               # libvirt/KVM
VM_CPUS=2 VM_MEMORY=4096 vagrant up         # минимум (по умолчанию 4 vCPU / 8 ГБ)
VM_IP=192.168.57.10 vagrant up              # другой адрес (по умолчанию 192.168.56.10)
```

В конце `vagrant up` печатает, как проверить:

```bash
vagrant ssh -c 'cd kubeadm-gateway-observability && make verify'      # внутри ВМ
# с вашей машины (нужны curl и jq)
vagrant ssh --no-tty -c 'cd kubeadm-gateway-observability && make ca >/dev/null && cat ca.crt' > ca.crt
curl --cacert ca.crt --resolve app.demo.local:443:192.168.56.10 https://app.demo.local/
```

`vagrant provision` повторяет развёртывание (идемпотентно), после правок на
хосте — сначала `vagrant rsync`. `HTTP(S)_PROXY`/`NO_PROXY`, если заданы,
передаются в `./deploy.sh`; прокси на `127.0.0.1` хоста из ВМ недоступен —
укажите адрес хоста, видимый из ВМ (например, `http://192.168.56.1:3128`).

На Windows `vagrant` запускайте из Git Bash (rsync — из MSYS2 или Cygwin)
или из WSL (`VAGRANT_WSL_ENABLE_WINDOWS_ACCESS=1`, репозиторий на
`/mnt/c/...`); `.gitattributes` сохраняет окончания строк LF. Для
PowerShell `vagrant up` печатает свой вариант команд (сертификат пишется
через `Set-Content -Encoding ascii`, иначе выйдет UTF-16).

Box и Vagrant раздаёт HashiCorp; из некоторых сетей (в том числе из России)
`vagrant up` получает 404 при скачивании box. Тогда box
(`https://vagrantcloud.com/bento/boxes/ubuntu-24.04/versions/202508.03.0/providers/<libvirt|virtualbox>/amd64/vagrant.box`)
скачивается любым доступным способом и регистрируется локально, плагин
vagrant-libvirt — с rubygems.org:

```bash
cat > box.json <<'JSON'
{"name": "bento/ubuntu-24.04", "versions": [{"version": "202508.03.0", "providers": [
  {"name": "libvirt", "architecture": "amd64", "default_architecture": true,
   "url": "file:///path/to/vagrant.box"}]}]}
JSON
vagrant box add box.json
vagrant plugin install vagrant-libvirt --plugin-clean-sources --plugin-source https://rubygems.org
```

Проверено с libvirt (Vagrant 2.4.9, vagrant-libvirt 0.12.2, QEMU 8.2,
вложенная виртуализация): `VM_CPUS=2 VM_MEMORY=4096 vagrant up
--provider=libvirt` — 12,7 мин, `make verify` в ВМ — 26 ✓ и 1 пропуск, с
хоста — 21 ✓. С VirtualBox проверен только `vagrant validate`.

## Трейсинг (`TRACING`)

Переменная окружения `./deploy.sh` / `make deploy` / `make platform`:

| `TRACING` | что будет |
|---|---|
| `auto` (по умолчанию) | включён, если у узла control plane не меньше 5632 МиБ памяти (так kubelet показывает ВМ на 6 ГБ) и не меньше 22 ГиБ диска |
| `true` | включён всегда (на 4 ГБ доступной памяти остаётся ~0,57 ГБ вместо ~0,69, проверено) |
| `false` | выключен; если был включён — всё удаляется |

`make platform` печатает решение (`==> tracing: on (TRACING=auto, control
plane memory 7941 MiB >= 5632 MiB, disk 37 GiB >= 22 GiB)`), `make status` —
что развёрнуто сейчас. `auto` решается заново при каждом развёртывании по
ёмкости узла: если память ВМ меняется на ходу (ballooning) или узел
пересоздают с другим размером, задайте `TRACING=true`/`false` явно.

Выключение удаляет релиз VictoriaTraces (с томом и данными), namespace
`tracing`, его NetworkPolicy, маршрут `traces.demo.local`, источник `Traces`
в Grafana, блок `tracing` в EnvoyProxy (без перезапуска подов Envoy: это
xDS) и BackendTrafficPolicy UI-маршрутов. Без кластера (`make lint`,
`make images-list`) рендер всегда с трейсингом; если кластер в kubeconfig
есть, но узел прочитать нельзя, `TRACING=auto` останавливает
развёртывание, а не угадывает. Проверка выключения —
[verification.md](verification.md#10-трейсинг).

## Несколько узлов

```bash
# на control plane после ./deploy.sh; воркер — Ubuntu 24.04 amd64, SSH, sudo без пароля
make add-worker WORKER=192.0.2.21 WORKER_USER=ubuntu SSH_KEY=~/.ssh/id_ed25519
kubectl get nodes -o wide
make verify                            # шаг 9 проверяет каждый узел
make remove-worker WORKER=192.0.2.21   # вывести воркер обратно
```

Ключ должен быть в `~/.ssh/authorized_keys` пользователя на воркере, а host
key воркера — известен (один раз `ssh ubuntu@192.0.2.21`). Несколько
воркеров — копией `ansible/inventory/multinode.example.yml`:
`make add-worker INVENTORY=ansible/inventory/multinode.yml` (вывести всех —
`make remove-worker INVENTORY=… FORCE=1`). Между узлами нужны TCP 6443,
10250 и UDP 8472.

`make add-worker` — 1,5–2 мин (на воркере уже стояли пакеты после
`make destroy`; на новой машине добавится их загрузка). Повторный
`make add-worker` и `./deploy.sh` — `changed=0`. Перезагрузка воркера — через
~1 мин снова `Ready`. `make remove-worker` — около минуты; на воркере после
него остаётся то же, что после `make destroy` (пакеты, containerd, кэш
загрузок), стёрты состояние kubeadm и kubelet, Cilium, правила iptables,
таблица nftables. Недоступный по SSH воркер всё равно выводится из
кластера, сбросить его нужно позже вручную (`sudo kubeadm reset`).
`make destroy` на control plane воркеры не сбрасывает (предупреждает о
них) — сначала `make remove-worker`. Как устроено —
[architecture.md](architecture.md#несколько-узлов).

## Образы: `make images`

Все образы закреплены по digest (`versions.env`, список — `images.txt`).
`make images` после `make cluster` скачивает их в containerd (`ctr -n
k8s.io images pull` по `repo@sha256`, ровно под теми именами, что ищет
kubelet) с повторами при сбое; уже скачанные пропускаются. Так все образы
скачиваются одним шагом до `make platform` (и сразу видно, доступны ли все
реестры), а установка чартов потом не ждёт загрузок. Образы, которые
только упоминаются, но не запускаются (rate limit Envoy Gateway,
ACME-solver cert-manager, Thanos), закреплены, но не скачиваются.

## Перезагрузка, обновление, удаление

- **Перезагрузка узла**: kubelet, containerd и таблица nftables поднимаются
  сами, `make verify` после этого зелёный. `FluentdBufferErrors` может
  гореть до ~10 мин после старта (окно алерта — 10 мин).
- **Обновление решения**: `git pull`, затем `./deploy.sh` — Ansible и
  helmfile применят только разницу. Смена образов на работающем кластере
  перезапускает поды; на 2 vCPU Prometheus может пересоздаваться до ~10 мин
  (см. [verification.md](verification.md#одной-командой-make-verify)).
- **Смена версии Kubernetes** на живом кластере (`kubeadm upgrade`)
  сценарием не предусмотрена и не проверялась; для другой версии —
  `make destroy FORCE=1`, правка `versions.env`, `./deploy.sh`.
- **Удаление**: `make destroy FORCE=1` — `kubeadm reset`, очистка CNI,
  nftables-таблицы, таймера одобрения сертификатов, `~/.kube/config` (если
  это неизменённая копия `admin.conf`). Пакеты kubeadm/kubelet/kubectl,
  containerd и runc остаются.

## Ресурсы: память и диск

Замер через 5+ мин после деплоя (один узел):

| ВМ | занято ОЗУ (`free`) | доступно | поды (`kubectl top`) | крупнейшие |
|---|---|---|---|---|
| 4 vCPU / 8 ГБ, трейсинг включён | 3,5 ГБ | 4,4 ГБ | 2,8 ГБ | kube-apiserver 0,8, Grafana 0,42–0,58, Prometheus 0,32–0,43, Cilium 0,23–0,42 ГБ; VictoriaTraces 15 МиБ |
| 2 vCPU / 4 ГБ, трейсинг выключен | 3,4–3,5 ГБ | 0,37–0,69 ГБ | 2,8 ГБ | kube-apiserver 0,82–0,89, Grafana 0,39–0,43, Prometheus 0,36–0,43, Cilium 0,26 ГБ |

На 2 vCPU / 4 ГБ всё работает, но запаса мало: под нагрузкой (первый
деплой) control plane может перезапуститься — развёртывание это переживает.
Если нужно больше места, вторую реплику Envoy можно выключить
(`envoyProxy.replicas: 1` в `charts/gateway/values.yaml`, ~40 МиБ).

Диск: сразу после деплоя занято ~9,7 ГБ (Ubuntu 2,3 ГБ, образы 6 ГБ). Дальше
растут только данные, и у каждого есть потолок:

| Что | Потолок |
|---|---|
| метрики Prometheus | 3 ГБ (`retentionSize`) + WAL ~0,5 ГБ |
| логи в VictoriaLogs | 2 ГБ (`retentionDiskSpaceUsage`), 7 дней |
| трейсы в VictoriaTraces (если включены) | 1 ГБ (потолок мягкий: старые дни удаляются после превышения), 3 дня |
| буфер Fluentd | 256 МБ |
| логи контейнеров на узле | ротация kubelet (10 МБ × 5 файлов на контейнер), на практике < 0,5 ГБ |

Итого пик ~16 ГБ без трейсинга и ~17 ГБ с ним. kubelet начинает удалять
образы при 85 % диска, поэтому 20 ГБ — минимум без трейсинга, 30 ГБ —
рекомендуемо; `TRACING=auto` включает трейсинг только от 22 ГиБ.

## CI/CD

Два workflow GitHub Actions на раннерах `ubuntu-24.04`:

- [`lint`](../.github/workflows/lint.yml) — на каждый push и pull request
  из форков: `make lint-deps && make lint`; падает, если какая-то проверка
  пропущена. Проверки отрендеренных манифестов (`helmfile template` без
  кластера, [`scripts/check-manifests.sh`](../scripts/check-manifests.sh)):
  **kubeconform** — каждый объект по схемам Kubernetes 1.36.5 и CRD (схемы
  CRD генерируются из тех самых CRD, что ставятся в кластер), строгий режим;
  **trivy config** — HIGH и CRITICAL во всех релизах, MEDIUM в своих
  чартах, принятые находки с обоснованием в
  [`.trivyignore.yaml`](../.trivyignore.yaml); **kube-linter** — все
  встроенные проверки по своим чартам, исключения в
  [`.kube-linter.yaml`](../.kube-linter.yaml) и аннотациями с причиной.
  Версии и sha256 инструментов — в `versions.env`, actions закреплены по
  SHA коммита (обновления предлагает Dependabot), у токена только чтение.
- [`e2e`](../.github/workflows/e2e.yml) — на push в `main` и вручную, на
  чистом раннере, как эксперт: очистка диска → `./deploy.sh` (кластер
  kubeadm на самом раннере) → `make verify` → проверка таймера одобрения
  сертификатов kubelet → повторный `./deploy.sh`, который ничего не должен
  изменить (Ansible `changed=0`, ни один релиз Helm не обновлён, ревизии те
  же — [`scripts/check-idempotency.sh`](../scripts/check-idempotency.sh)) →
  `make verify` ещё раз. При падении поды, события, логи и журналы kubelet
  и containerd собираются в артефакт
  ([`scripts/collect-diagnostics.sh`](../scripts/collect-diagnostics.sh)).
  Прогон на раннере 2 vCPU / 7 ГБ — ~12 мин (очистка диска ~3,5 мин,
  `./deploy.sh` ~6,5 мин, повторный ~1 мин; замер до трейсинга). Проверка
  `:9962` на раннере пропускается: `make verify` идёт на самом узле.

## Если что-то пошло не так

| Симптом | Что делать |
|---|---|
| Развёртывание прервалось на загрузке (чарты, образы, пакеты) | короткие сбои сети переживаются повторами; после долгого обрыва просто запустите `./deploy.sh` ещё раз |
| «kubeadm init когда-то прервался» (есть `admin.conf`, манифесты, данные etcd, но кластера нет) | автоматически не чинится: `make destroy FORCE=1`, затем `./deploy.sh` |
| `NODE_IP` отличается от адреса кластера / узел сменил IP | `make destroy FORCE=1` и `./deploy.sh` с нужным адресом; закрепите IP в DHCP |
| `make verify` сразу после деплоя или обновления: ✗ на шаге 7 | подождите несколько минут и повторите: цели Prometheus появляются через 1–2 интервала сбора, после обновления Prometheus может пересоздаваться |
| Горит `FluentdBufferErrors` после простоя VictoriaLogs или перезагрузки | ожидаемо до ~10 мин; логи дозагружаются из буфера |
| Панели логов в Grafana пустые | Grafana не скачала плагин VictoriaLogs с grafana.com (нет интернета или прокси) — логи доступны в vmui и через API |
| `kubectl` в сессии с `HTTPS_PROXY` получает 403/таймаут | добавьте IP узла в `NO_PROXY` |
| `vagrant up` — 404 при скачивании box | см. [«Нет Ubuntu 24.04?»](#нет-ubuntu-2404-vagrant-up) |
| Шаг 9: реплики на одном узле после `make add-worker` | повторите `make add-worker` — он перезапустит Deployment'ы со спредом |
| Под в `CrashLoopBackOff`, причина неясна | `kubectl -n <ns> describe pod <под>`, `kubectl -n <ns> logs <под> --previous`; полная выгрузка — `scripts/collect-diagnostics.sh /tmp/diag` |
