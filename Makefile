# Entry point for deployment and day-2 operations.
# Run `make` (or `make help`) to list the targets.

SHELL := /usr/bin/env bash
# No -u here: bash may source /etc/bash.bashrc (non-interactive ssh), which
# is not nounset-safe on Ubuntu.
.SHELLFLAGS := -e -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

THIS_MAKEFILE := $(firstword $(MAKEFILE_LIST))

# Pinned versions and settings (K8S_VERSION, CILIUM_VERSION, ...).
include versions.env

VENV ?= .venv
LOCAL_INVENTORY := ansible/inventory/local.yml
INVENTORY ?= $(LOCAL_INVENTORY)
ANSIBLE_ARGS ?=
HELMFILE_ARGS ?=
# Parallel helm processes (diff and upgrade). Unlimited parallelism (the
# helmfile default) overloads the API server of a 2 vCPU node on re-deploy
# (14 diffs at once -> "TLS handshake timeout"); one per CPU is safe.
HELMFILE_CONCURRENCY ?= $(shell nproc 2>/dev/null || echo 2)

ANSIBLE_PLAYBOOK := $(VENV)/bin/ansible-playbook
HELMFILE := helmfile --file helmfile.yaml.gotmpl

export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

SHELL_SCRIPTS := deploy.sh $(wildcard scripts/*.sh)
# Own charts (the vendored local-path-provisioner chart is not linted).
LOCAL_CHARTS := charts/namespaces charts/network-policies charts/pki \
	charts/gateway charts/ui-routes charts/demo-app charts/etcd-metrics-proxy \
	charts/logging charts/observability-extras
# Required values of the charts above, for `helm lint` only.
LINT_VALUES := --set image.tag=lint --set nodeIP=192.0.2.10 \
	--set victoriaLogs.url=http://victoria-logs:9428 \
	--set scraper.serviceAccount=prometheus --set scraper.namespace=monitoring

# Grafana of kube-prometheus-stack: restarted by `make platform` only if its
# admin password Secret had to be created anew.
GRAFANA_DEPLOYMENT := kube-prometheus-stack-grafana

# Root CA of the demo PKI (cert-manager), for `curl --cacert`.
CA_FILE ?= ca.crt
CA_NAMESPACE := cert-manager
CA_SECRET := demo-ca-keypair

.PHONY: help deploy cluster platform verify status ui ca destroy lint lint-deps versions

help: ## Show this help
	@printf 'Kubernetes %s (kubeadm) + Cilium %s + Envoy Gateway %s on Ubuntu 24.04\n\n' \
		'$(K8S_VERSION)' '$(CILIUM_VERSION)' '$(ENVOY_GATEWAY_VERSION)'
	@printf 'Usage: make <target> [VAR=value]\n\nTargets:\n'
	@grep -E '^[a-z-]+:.*## ' $(THIS_MAKEFILE) | sort | \
		awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@printf '\nVariables:\n'
	@printf '  NODE_IP=<ip>      API server / Gateway address (default: IP of the default route)\n'
	@printf '  INVENTORY=<file>  Ansible inventory (default: %s)\n' '$(INVENTORY)'
	@printf '  CA_FILE=<file>    where `make ca` writes the CA certificate (default: %s)\n' '$(CA_FILE)'
	@printf '  GATEWAY_IP, UI_PASSWORD, CA_FILE  `make verify` from a machine without kubectl (see README)\n'
	@printf '  FORCE=1           confirm `make destroy`\n'

deploy: ## Node + cluster (Ansible), then platform (helmfile); idempotent
	@$(MAKE) cluster
	@$(MAKE) platform

# On this machine without passwordless sudo, Ansible asks for the sudo
# password once (BECOME password) instead of failing.
cluster: $(ANSIBLE_PLAYBOOK) ## Prepare the node and bootstrap kubeadm (Ansible only)
	@if [[ $${EUID} -ne 0 && '$(INVENTORY)' == '$(LOCAL_INVENTORY)' && -z "$${ANSIBLE_BECOME_ASK_PASS:-}" ]] \
		&& ! sudo -n true 2>/dev/null; then \
		echo '==> sudo requires a password; Ansible will ask for it (BECOME password)'; \
		export ANSIBLE_BECOME_ASK_PASS=true; \
	fi; \
	echo '$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/site.yml $(ANSIBLE_ARGS)'; \
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/site.yml $(ANSIBLE_ARGS)

# ensure-*.sh run after every apply: helmfile hooks fire only for changed
# releases, so this is what restores a deleted Secret (and restarts Grafana
# if its admin password had to be generated anew).
# --skip-diff-on-install: a first install prints no diff (it would be the
# whole cluster, ~100k lines); upgrades still show what changes.
# A short network hiccup (chart repository, OCI registry, image CDN) must not
# fail the whole deployment, so both steps are retried. Chart repositories
# are fetched first; apply then skips that step. A retry runs `sync` rather
# than `apply`: apply skips a release whose diff is empty, and that is also
# the case for a release left "failed" by the previous attempt.
platform: ## Install or update cluster add-ons (helmfile only)
	@command -v helmfile >/dev/null || { echo "helmfile not found: run 'make cluster' first" >&2; exit 1; }
	@for attempt in 1 2 3 4 5; do \
		$(HELMFILE) repos && break; \
		[[ $$attempt -lt 5 ]] || exit 1; \
		echo "==> chart repositories not reachable, retrying in 15 s ($$attempt/5)" >&2; sleep 15; \
	done
	@args='--skip-deps --concurrency $(HELMFILE_CONCURRENCY) --suppress-secrets'; \
	echo "$(HELMFILE) apply $$args --skip-diff-on-install $(HELMFILE_ARGS)"; \
	$(HELMFILE) apply $$args --skip-diff-on-install $(HELMFILE_ARGS) && exit 0; \
	for attempt in 2 3; do \
		echo "==> helmfile failed; retrying in 30 s with helmfile sync (attempt $$attempt/3)" >&2; sleep 30; \
		$(HELMFILE) sync $$args $(HELMFILE_ARGS) && exit 0; \
	done; \
	exit 1
	./scripts/ensure-basic-auth.sh '$(GATEWAY_NAMESPACE)' '$(BASIC_AUTH_SECRET)' '$(BASIC_AUTH_USER)'
	./scripts/ensure-grafana-admin.sh '$(MONITORING_NAMESPACE)' '$(GRAFANA_ADMIN_SECRET)' '$(GRAFANA_ADMIN_USER)' '$(GRAFANA_DEPLOYMENT)'

verify: ## End-to-end check: table of ✓/✗, non-zero exit code on failure
	@./scripts/verify.sh

status: ## Short overview: node, versions, Gateway address, UI links, releases, health
	@./scripts/status.sh

# Passwords are read from the cluster on request only; deploy never prints them.
ui: ## Show observability UI addresses and their credentials
	@ip="$$(kubectl -n $(GATEWAY_NAMESPACE) get gateway public -o jsonpath='{.status.addresses[0].value}')"; \
	secret() { kubectl -n "$$1" get secret "$$2" -o jsonpath="{.data.$$3}" | base64 -d; }; \
	printf 'Observability UIs (add "%s grafana.demo.local prometheus.demo.local alertmanager.demo.local logs.demo.local"\n' "$$ip"; \
	printf 'to /etc/hosts, or use curl --resolve; the certificate is issued by the demo CA, see `make ca`):\n\n'; \
	printf '  Grafana       https://grafana.demo.local       user %s, password %s\n' \
		"$$(secret $(MONITORING_NAMESPACE) $(GRAFANA_ADMIN_SECRET) admin-user)" \
		"$$(secret $(MONITORING_NAMESPACE) $(GRAFANA_ADMIN_SECRET) admin-password)"; \
	ba_user="$$(secret $(GATEWAY_NAMESPACE) $(BASIC_AUTH_SECRET) username)"; \
	ba_pass="$$(secret $(GATEWAY_NAMESPACE) $(BASIC_AUTH_SECRET) password)"; \
	printf '  Prometheus    https://prometheus.demo.local    basic auth %s / %s\n' "$$ba_user" "$$ba_pass"; \
	printf '  Alertmanager  https://alertmanager.demo.local  basic auth %s / %s\n' "$$ba_user" "$$ba_pass"; \
	printf '  Logs (vmui)   https://logs.demo.local/select/vmui/  basic auth %s / %s\n' "$$ba_user" "$$ba_pass"

ca: ## Export the demo root CA certificate to $(CA_FILE) (for curl --cacert)
	@kubectl -n $(CA_NAMESPACE) get secret $(CA_SECRET) -o jsonpath='{.data.ca\.crt}' | base64 -d >'$(CA_FILE).tmp'
	@openssl x509 -in '$(CA_FILE).tmp' -noout -subject >/dev/null || { rm -f '$(CA_FILE).tmp'; echo 'CA secret is not ready yet' >&2; exit 1; }
	@mv '$(CA_FILE).tmp' '$(CA_FILE)'
	@printf 'CA certificate written to %s (%s)\n' '$(CA_FILE)' "$$(openssl x509 -in '$(CA_FILE)' -noout -subject)"

destroy: ## Tear the cluster down with kubeadm reset (requires FORCE=1)
	@if [[ "$(FORCE)" != "1" ]]; then \
		echo "This wipes the Kubernetes cluster on this host. Re-run with: make destroy FORCE=1" >&2; \
		exit 1; \
	fi
	./scripts/destroy.sh

lint: ## Run shellcheck, yamllint, ansible-lint, helm lint, promtool (whatever is installed)
	@rc=0; \
	if command -v shellcheck >/dev/null; then \
		echo '--> shellcheck'; shellcheck $(SHELL_SCRIPTS) || rc=1; \
	else echo 'skip: shellcheck not installed (make lint-deps)'; fi; \
	if command -v yamllint >/dev/null; then \
		echo '--> yamllint'; yamllint --strict . || rc=1; \
	else echo 'skip: yamllint not installed (make lint-deps)'; fi; \
	if command -v ansible-lint >/dev/null; then \
		echo '--> ansible-lint'; ansible-lint ansible/ || rc=1; \
	else echo 'skip: ansible-lint not installed (make lint-deps)'; fi; \
	if command -v helm >/dev/null; then \
		echo '--> helm lint'; \
		helm lint --strict --quiet $(LOCAL_CHARTS) $(LINT_VALUES) || rc=1; \
	else echo 'skip: helm not installed (make cluster)'; fi; \
	if command -v promtool >/dev/null && command -v helm >/dev/null; then \
		echo '--> promtool check rules'; ./scripts/check-rules.sh $(VENV)/bin/python || rc=1; \
	else echo 'skip: promtool or helm not installed'; fi; \
	exit $$rc

lint-deps: $(ANSIBLE_PLAYBOOK) ## Install lint tools into .venv
	$(VENV)/bin/pip install --quiet --disable-pip-version-check -r requirements-dev.txt -c requirements.txt
	./scripts/install-promtool.sh '$(PROMTOOL_VERSION)' '$(PROMTOOL_SHA256)' '$(VENV)/bin'

versions: ## Print pinned versions
	@grep -E '^[A-Z0-9_]+=' versions.env | grep -v '_SHA256='

$(ANSIBLE_PLAYBOOK): requirements.txt
	./deploy.sh --bootstrap-only
	@touch $@
