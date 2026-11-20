# Mender Server testing kit. Run "make help".
SHELL := /bin/bash
unexport CDPATH
VAGRANT := VAGRANT_CWD=vagrant vagrant
EDITION ?=
# k3s-* never use the shell's KUBECONFIG, current context or NAMESPACE
KIT_NAMESPACE := $(or $(KIT_NAMESPACE),mender)
KIT_KUBECONFIG := $(or $(KIT_KUBECONFIG),$(HOME)/.kube/k3s.yaml)
export EDITION VERSION KIT_NAMESPACE KIT_KUBECONFIG
K3S_KUBECTL := KUBECONFIG='$(KIT_KUBECONFIG)' kubectl -n '$(KIT_NAMESPACE)'
CA_OUT ?= .state/ca.crt

.PHONY: help check-edition check-version vm-up vm-upload vm-install vm-version vm-pr-build vm-user vm-status vm-cert vm-ssh vm-uninstall vm-destroy \
	k3s-setup k3s-install k3s-user k3s-status k3s-ca k3s-uninstall k3s-remove

help:
	@echo "Vagrant VM (nt-iac Flux manifests, SeaweedFS):"
	@echo "  vm-up                    create the VM (VM_MEMORY, VM_CPUS, VM_IP)"
	@echo "  vm-install               install Mender (prompts: opensource/enterprise, tokens)"
	@echo "  vm-version VERSION=x     pin the Mender Server image tag"
	@echo "  vm-pr-build VERSION=x    run a GitLab PR build (build-<sha>)"
	@echo "  vm-user                  create the first user or organization"
	@echo "  vm-status | vm-ssh       pods, shell"
	@echo "  vm-cert                  copy server.crt to .state/server.crt"
	@echo "  vm-uninstall             remove Mender, SeaweedFS and Flux, keep the VM"
	@echo "  vm-destroy               delete the VM and .state/server.crt"
	@echo "Local K3s (Helm chart with built-in MongoDB, RustFS, self-signed CA):"
	@echo "  k3s-setup                install K3s and Helm on this host (sudo)"
	@echo "  k3s-install              install or upgrade Mender (prompts: URL, type, chart, image tag)"
	@echo "  k3s-user                 create the first user or organization"
	@echo "  k3s-status               pods and ingress"
	@echo "  k3s-ca [CA_OUT=path]     export the CA (default .state/ca.crt) for browsers and devices"
	@echo "  k3s-uninstall            remove the release, its namespace and its .state files"
	@echo "  k3s-remove               uninstall K3s with ALL its data and .state (sudo, asks to type remove)"

vm-up:
	$(VAGRANT) up --provider=libvirt
	@grep -q 'mender.local' /etc/hosts || echo "Add to /etc/hosts: $${VM_IP:-192.168.56.10} mender.local"

check-edition:
	@case $${EDITION:-} in ''|opensource|enterprise) ;; *) echo "EDITION must be opensource or enterprise"; exit 1 ;; esac

check-version:
	@[[ $${VERSION:-} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$$ ]] \
		|| { echo "usage: make vm-version VERSION=v4.1.0-saas.16 or make vm-pr-build VERSION=build-<sha>"; exit 1; }

vm-upload:
	@$(VAGRANT) ssh -c 'rm -rf kit && mkdir -p kit' >/dev/null 2>&1
	@$(VAGRANT) upload scripts kit/scripts | grep -v '^Upload'

vm-install: check-edition vm-upload
	@scripts/vm-env.sh MENDER_REGISTRY_USERNAME MENDER_REGISTRY_PASSWORD MENDER_REGISTRY_EMAIL GITHUB_TOKEN \
		| $(VAGRANT) ssh -c 'umask 077; cat > kit/.vm-env' 2>/dev/null
	$(VAGRANT) ssh -- -t "EDITION=$$EDITION bash kit/scripts/vm-install.sh"

vm-version: check-version vm-upload
	$(VAGRANT) ssh -- -t "bash kit/scripts/vm-override.sh $$VERSION"

vm-pr-build: check-version vm-upload
	@scripts/vm-env.sh GITLAB_REGISTRY_USERNAME GITLAB_REGISTRY_TOKEN GITLAB_REGISTRY_EMAIL \
		| $(VAGRANT) ssh -c 'umask 077; cat > kit/.vm-env' 2>/dev/null
	$(VAGRANT) ssh -- -t "bash kit/scripts/vm-override.sh $$VERSION pr"

vm-user: check-edition vm-upload
	@scripts/vm-env.sh USER_EMAIL USER_PASSWORD ORG_NAME | $(VAGRANT) ssh -c 'umask 077; cat > kit/.vm-env' 2>/dev/null
	$(VAGRANT) ssh -- -t "EDITION=$$EDITION KIT_VM=1 bash kit/scripts/create-user.sh"

vm-status:
	$(VAGRANT) ssh -c 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods,ingress'

vm-cert:
	@mkdir -p .state
	$(VAGRANT) ssh -c 'cat mender-certs/server.crt' > .state/server.crt
	@echo "written .state/server.crt"

vm-ssh:
	$(VAGRANT) ssh

vm-uninstall: vm-upload
	$(VAGRANT) ssh -c 'bash kit/scripts/vm-uninstall.sh'

vm-destroy:
	$(VAGRANT) destroy -f
	rm -f .state/server.crt

k3s-setup:
	scripts/k3s-setup.sh

k3s-install:
	scripts/k3s-install.sh

k3s-user:
	scripts/create-user.sh

k3s-status:
	$(K3S_KUBECTL) get pods,ingress

k3s-ca:
	@mkdir -p $(dir $(CA_OUT))
	@set -o pipefail; $(K3S_KUBECTL) get secret mender-ingress-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
		| base64 -d > $(CA_OUT).tmp && openssl x509 -noout -in $(CA_OUT).tmp 2>/dev/null \
		|| { rm -f $(CA_OUT).tmp; echo "ERROR: no CA in $(KIT_NAMESPACE)/mender-ingress-tls, run make k3s-install first"; exit 1; }
	@mv $(CA_OUT).tmp $(CA_OUT)
	@openssl x509 -noout -subject -enddate -fingerprint -sha256 -in $(CA_OUT)
	@echo "written $(CA_OUT)"

k3s-uninstall:
	scripts/k3s-uninstall.sh

k3s-remove:
	scripts/k3s-remove.sh
