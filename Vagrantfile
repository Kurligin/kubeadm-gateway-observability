# -*- mode: ruby -*-
# Ubuntu 24.04 VM with the whole solution, for a machine without Ubuntu 24.04:
#
#   vagrant up                          # VirtualBox (default provider)
#   vagrant up --provider=libvirt       # libvirt/KVM (plugin vagrant-libvirt)
#
# The repository is copied into the VM (rsync) and deployed there with
# ./deploy.sh, as the user vagrant; the Gateway listens on the VM's address
# in a private network that the host can reach. Settings (environment):
#
#   VM_CPUS    vCPUs (default 4; 2 is the minimum)
#   VM_MEMORY  RAM in MiB (default 8192; 4096 is the minimum)
#   VM_IP      address in the private network (default 192.168.56.10)
#   HTTP_PROXY, HTTPS_PROXY, NO_PROXY  passed to ./deploy.sh if set
#
# `vagrant provision` deploys again (idempotent); after changing files on
# the host, `vagrant rsync` copies them into the VM first.

Vagrant.require_version ">= 2.4.0"

# bento/ubuntu-24.04 of this version is published for both providers (amd64).
BOX = "bento/ubuntu-24.04"
BOX_VERSION = "202508.03.0"

VM_CPUS = Integer(ENV.fetch("VM_CPUS", "4"))
VM_MEMORY = Integer(ENV.fetch("VM_MEMORY", "8192"))
VM_IP = ENV.fetch("VM_IP", "192.168.56.10")
# The bento box has a 64 GB disk (thin-provisioned); the solution needs 20-30.
REPO_DIR = "/home/vagrant/kubeadm-gateway-observability"
PROXY_VARS = %w[HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy].freeze

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  config.vm.box_version = BOX_VERSION
  config.vm.box_architecture = "amd64"
  config.vm.hostname = "kubeadm-gateway"
  config.vm.boot_timeout = 600

  config.vm.network "private_network", ip: VM_IP

  config.vm.synced_folder ".", "/vagrant", disabled: true
  # One-way copy into the VM: the deployment writes .venv and caches into
  # the repository directory, which must not end up on the host.
  config.vm.synced_folder ".", REPO_DIR, type: "rsync",
    rsync__exclude: [".vagrant/", ".venv/", ".cache/", "ansible/collections/", "ca.crt"]

  config.vm.provider "virtualbox" do |vb|
    vb.cpus = VM_CPUS
    vb.memory = VM_MEMORY
  end

  config.vm.provider "libvirt" do |lv|
    lv.cpus = VM_CPUS
    lv.memory = VM_MEMORY
    lv.cpu_mode = "host-passthrough"
  end

  proxy_env = PROXY_VARS.to_h { |name| [name, ENV[name]] }.compact
  # The API server and the Gateway use the private network address: the
  # default route of the VM goes through the provider's NAT, which the host
  # cannot reach.
  config.vm.provision "deploy", type: "shell", privileged: false,
    env: proxy_env.merge("NODE_IP" => VM_IP), inline: <<~SHELL
      set -euo pipefail
      cd #{REPO_DIR}
      ./deploy.sh
    SHELL

  config.vm.post_up_message = <<~MESSAGE
    Ubuntu 24.04 VM #{VM_IP}, #{VM_CPUS} vCPU / #{VM_MEMORY} MiB (repository in #{REPO_DIR}).

    Check inside the VM:
      vagrant ssh -c 'cd kubeadm-gateway-observability && make verify'

    Check from this machine (needs curl and jq):
      vagrant ssh --no-tty -c 'cd kubeadm-gateway-observability && make ca >/dev/null && cat ca.crt' > ca.crt
      curl --cacert ca.crt --resolve app.demo.local:443:#{VM_IP} https://app.demo.local/
      GATEWAY_IP=#{VM_IP} CA_FILE=ca.crt \\
        UI_PASSWORD="$(vagrant ssh --no-tty -c 'kubectl -n gateway get secret ui-basic-auth -o jsonpath={.data.password} | base64 -d')" \\
        ./scripts/verify.sh

    Passwords and UI addresses: vagrant ssh -c 'cd kubeadm-gateway-observability && make ui'
  MESSAGE
end
