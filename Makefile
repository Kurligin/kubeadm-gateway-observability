# Entry point for deployment and day-2 operations.
# Run `make` (or `make help`) to list the targets.

SHELL := /usr/bin/env bash
# No -u here: bash may source /etc/bash.bashrc (non-interactive ssh), which
# is not nounset-safe on Ubuntu.
.SHELLFLAGS := -e -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

THIS_MAKEFILE := $(firstword $(MAKEFILE_LIST))

# Pinned versions (K8S_VERSION, CILIUM_VERSION, ...).
include versions.env

VENV ?= .venv
INVENTORY ?= ansible/inventory/local.yml
ANSIBLE_ARGS ?=
HELMFILE_ARGS ?=

ANSIBLE_PLAYBOOK := $(VENV)/bin/ansible-playbook
HELMFILE := helmfile --file helmfile.yaml.gotmpl

export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

SHELL_SCRIPTS := deploy.sh $(wildcard scripts/*.sh)
# Own charts (the vendored local-path-provisioner chart is not linted).
LOCAL_CHARTS := charts/namespaces charts/pki charts/gateway charts/demo-app

# Root CA of the demo PKI (cert-manager), for `curl --cacert`.
CA_FILE ?= ca.crt
CA_NAMESPACE := cert-manager
CA_SECRET := demo-ca-keypair

.PHONY: help deploy cluster platform status ca destroy lint lint-deps versions

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
	@printf '  FORCE=1           confirm `make destroy`\n'

deploy: ## Node + cluster (Ansible), then platform (helmfile); idempotent
	@$(MAKE) cluster
	@$(MAKE) platform

cluster: $(ANSIBLE_PLAYBOOK) ## Prepare the node and bootstrap kubeadm (Ansible only)
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) ansible/site.yml $(ANSIBLE_ARGS)

platform: ## Install or update cluster add-ons (helmfile only)
	@command -v helmfile >/dev/null || { echo "helmfile not found: run 'make cluster' first" >&2; exit 1; }
	$(HELMFILE) apply --suppress-secrets $(HELMFILE_ARGS)

status: ## Show nodes, pods, Helm releases, Gateway and certificates (preview)
	@kubectl get nodes -o wide
	@echo
	@kubectl get pods --all-namespaces
	@echo
	@helm list --all-namespaces
	@echo
	@kubectl get gateway,httproute --all-namespaces
	@echo
	@kubectl get certificate --all-namespaces

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

lint: ## Run shellcheck, yamllint, ansible-lint and helm lint (whatever is installed)
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
		helm lint --strict --quiet $(LOCAL_CHARTS) --set image.tag=$(ANGIE_VERSION)-minimal || rc=1; \
	else echo 'skip: helm not installed (make cluster)'; fi; \
	exit $$rc

lint-deps: $(ANSIBLE_PLAYBOOK) ## Install lint tools into .venv
	$(VENV)/bin/pip install --quiet --disable-pip-version-check -r requirements-dev.txt -c requirements.txt

versions: ## Print pinned versions
	@grep -E '^[A-Z0-9_]+=' versions.env | grep -v '_SHA256='

$(ANSIBLE_PLAYBOOK): requirements.txt
	./deploy.sh --bootstrap-only
	@touch $@
