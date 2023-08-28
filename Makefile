SHELL := bash
PLATFORM := $(shell uname)
platform := $(shell echo $(PLATFORM) | tr A-Z a-z)
ifeq ($(platform),Darwin)
	platform_alt = macOS
else
	platform_alt = $(platform)
endif

ARCHITECTURE := $(shell uname -m)
ifeq ($(ARCHITECTURE),x86_64)
	arch_alt = amd64
else
	arch_alt = arm64
endif
ifeq ($(ARCHITECTURE),x86_64)
	ARCHITECTURE=amd64
endif
ARCH := $(shell uname -m)

ifeq ($(platform),Darwin)
	jq_platform = osx-amd
else
	jq_platform = $(platform)
endif
ifeq ($(ARCHITECTURE),amd64)
	jq_arch = 64
else
	jq_arch = 32
endif

.DEFAULT_GOAL = help
.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

### Helper functions
### https://stackoverflow.com/questions/10858261/how-to-abort-makefile-if-variable-not-set
check_defined = \
    $(strip $(foreach 1,$1, \
        $(call __check_defined,$1,$(strip $(value 2)))))
__check_defined = \
    $(if $(value $1),, \
        $(error Undefined $1$(if $2, ($2))$(if $(value @), \
                required by target '$@')))
###

# The latest 1.25 available for envtest
ENVTEST_K8S_VERSION ?= 1.25.0
LOCAL_TESTBIN = $(CURDIR)/testbin
$(LOCAL_TESTBIN):
	mkdir -p $@

LOCAL_TMP := $(CURDIR)/tmp
$(LOCAL_TMP):
	mkdir -p $@

K8S_OPERATOR_NAMESPACE ?= rabbitmq-system
SYSTEM_TEST_NAMESPACE ?= rabbitmq-system

# "Control plane binaries (etcd and kube-apiserver) are loaded by default from /usr/local/kubebuilder/bin.
# This can be overridden by setting the KUBEBUILDER_ASSETS environment variable"
# https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/envtest
export KUBEBUILDER_ASSETS = $(LOCAL_TESTBIN)/k8s/$(ENVTEST_K8S_VERSION)-$(platform)-$(ARCHITECTURE)

$(KUBEBUILDER_ASSETS):
	setup-envtest -v info --os $(platform) --arch $(ARCHITECTURE) --bin-dir $(LOCAL_TESTBIN) use $(ENVTEST_K8S_VERSION)

.PHONY: kubebuilder-assets
kubebuilder-assets: $(KUBEBUILDER_ASSETS)

.PHONY: kubebuilder-assets-rm
kubebuilder-assets-rm:
	setup-envtest -v debug --os $(platform) --arch $(ARCHITECTURE) --bin-dir $(LOCAL_TESTBIN) cleanup

.PHONY: unit-tests
unit-tests: install-tools $(KUBEBUILDER_ASSETS) generate fmt vet vuln manifests ## Run unit tests
	ginkgo -r --randomize-all api/ internal/ pkg/

.PHONY: integration-tests
integration-tests: install-tools $(KUBEBUILDER_ASSETS) generate fmt vet vuln manifests ## Run integration tests
	ginkgo -r controllers/

manifests: install-tools controller-gen ## Generate manifests e.g. CRD, RBAC etc.
	controller-gen crd rbac:roleName=operator-role paths="./api/...;./controllers/..." output:crd:artifacts:config=config/crd/bases
	./hack/remove-override-descriptions.sh
	./hack/add-notice-to-yaml.sh config/rbac/role.yaml
	./hack/add-notice-to-yaml.sh config/crd/bases/rabbitmq.com_rabbitmqclusters.yaml

api-reference: install-tools crd-ref-docs # Generate API reference documentation
	crd-ref-docs \
		--source-path ./api/v1beta1 \
		--config ./docs/api/autogen/config.yaml \
		--templates-dir ./docs/api/autogen/templates \
		--output-path ./docs/api/rabbitmq.com.ref.asciidoc \
		--max-depth 30

.PHONY: checks
checks::fmt ## Runs fmt + vet +govulncheck against the current code
checks::vet
checks::vuln

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Run govulncheck against code
vuln: govulncheck
	govulncheck ./...

# Generate code & docs
generate: install-tools api-reference controller-gen
	controller-gen object:headerFile=./hack/NOTICE.go.txt paths=./api/...
	controller-gen object:headerFile=./hack/NOTICE.go.txt paths=./internal/status/...

# Build manager binary
manager: generate checks
	go mod download
	go build -o bin/manager main.go

deploy-manager: kustomize ## Deploy manager
	kustomize build config/crd | kubectl apply -f -
	kustomize build config/default/base | kubectl apply -f -

deploy-manager-dev: kustomize 
	@$(call check_defined, OPERATOR_IMAGE, path to the Operator image within the registry e.g. rabbitmq/cluster-operator)
	@$(call check_defined, DOCKER_REGISTRY_SERVER, URL of docker registry containing the Operator image e.g. registry.my-company.com)
	kustomize build config/crd | kubectl apply -f -
	kustomize build config/default/overlays/dev | sed 's@((operator_docker_image))@"$(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):$(GIT_COMMIT)"@' | kubectl apply -f -

deploy-sample: kustomize  ## Deploy RabbitmqCluster defined in config/sample/base
	kustomize build config/samples/base | kubectl apply -f -

destroy: kustomize  ## Cleanup all controller artefacts
	kustomize build config/crd/ | kubectl delete --ignore-not-found=true -f -
	kustomize build config/default/base/ | kubectl delete --ignore-not-found=true -f -
	kustomize build config/rbac/ | kubectl delete --ignore-not-found=true -f -
	kustomize build config/namespace/base/ | kubectl delete --ignore-not-found=true -f -

.PHONY: run
run::generate ## Run operator binary locally against the configured Kubernetes cluster in ~/.kube/config
run::manifests
run::checks
run::install
run::deploy-namespace-rbac
run::just-run

just-run: ## Just runs 'go run main.go' without regenerating any manifests or deploying RBACs
	go run ./main.go -metrics-bind-address 127.0.0.1:9782 --zap-devel $(OPERATOR_ARGS)

.PHONY: delve
delve::generate ## Deploys CRD, Namespace, RBACs and starts Delve debugger
delve::install
delve::deploy-namespace-rbac
delve::just-delve

just-delve: install-tools ## Just starts Delve debugger
	KUBECONFIG=${HOME}/.kube/config OPERATOR_NAMESPACE=$(K8S_OPERATOR_NAMESPACE) dlv debug

install: manifests ## Install CRDs into a cluster
	kubectl apply -f config/crd/bases

deploy-namespace-rbac: kustomize 
	kustomize build config/namespace/base | kubectl apply -f -
	kustomize build config/rbac | kubectl apply -f -

.PHONY: deploy
deploy::manifests ## Deploy operator in the configured Kubernetes cluster in ~/.kube/config
deploy::deploy-namespace-rbac
deploy::deploy-manager

.PHONY: deploy-dev
deploy-dev::docker-build-dev ## Deploy operator in the configured Kubernetes cluster in ~/.kube/config, with local changes
deploy-dev::manifests
deploy-dev::deploy-namespace-rbac
deploy-dev::docker-registry-secret
deploy-dev::deploy-manager-dev

GIT_COMMIT := $(shell git rev-parse --short HEAD)
deploy-kind: manifests deploy-namespace-rbac  kustomize ## Load operator image and deploy operator into current KinD cluster
	@$(call check_defined, OPERATOR_IMAGE, path to the Operator image within the registry e.g. rabbitmq/cluster-operator)
	@$(call check_defined, DOCKER_REGISTRY_SERVER, URL of docker registry containing the Operator image e.g. registry.my-company.com)
	docker buildx build --build-arg=GIT_COMMIT=$(GIT_COMMIT) -t $(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):$(GIT_COMMIT) .
	kind load docker-image $(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):$(GIT_COMMIT)
	kustomize build config/crd | kubectl apply -f -
	kustomize build config/default/overlays/kind | sed 's@((operator_docker_image))@"$(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):$(GIT_COMMIT)"@' | kubectl apply -f -

YTT_VERSION ?= v0.45.3
YTT = $(LOCAL_TESTBIN)/ytt
$(YTT): | $(LOCAL_TESTBIN)
	mkdir -p $(LOCAL_TESTBIN)
	curl -sSL -o $(YTT) https://github.com/vmware-tanzu/carvel-ytt/releases/download/$(YTT_VERSION)/ytt-$(platform)-$(shell go env GOARCH)
	chmod +x $(YTT)

QUAY_IO_OPERATOR_IMAGE ?= quay.io/rabbitmqoperator/cluster-operator:latest
# Builds a single-file installation manifest to deploy the Operator
generate-installation-manifest: | $(YTT) kustomize 
	mkdir -p releases
	kustomize build config/installation/ > releases/cluster-operator.yml
	$(YTT) -f releases/cluster-operator.yml -f config/ytt/overlay-manager-image.yaml --data-value operator_image=$(QUAY_IO_OPERATOR_IMAGE) > releases/cluster-operator-quay-io.yml

docker-build: ## Build the docker image with tag `latest`
	@$(call check_defined, OPERATOR_IMAGE, path to the Operator image within the registry e.g. rabbitmq/cluster-operator)
	@$(call check_defined, DOCKER_REGISTRY_SERVER, URL of docker registry containing the Operator image e.g. registry.my-company.com)
	docker buildx build --build-arg=GIT_COMMIT=$(GIT_COMMIT) -t $(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):latest .

docker-push: ## Push the docker image with tag `latest`
	@$(call check_defined, OPERATOR_IMAGE, path to the Operator image within the registry e.g. rabbitmq/cluster-operator)
	@$(call check_defined, DOCKER_REGISTRY_SERVER, URL of docker registry containing the Operator image e.g. registry.my-company.com)
	docker push $(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):latest

docker-build-dev:
	@$(call check_defined, OPERATOR_IMAGE, path to the Operator image within the registry e.g. rabbitmq/cluster-operator)
	@$(call check_defined, DOCKER_REGISTRY_SERVER, URL of docker registry containing the Operator image e.g. registry.my-company.com)
	docker buildx build --build-arg=GIT_COMMIT=$(GIT_COMMIT) -t $(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):$(GIT_COMMIT) .
	docker push $(DOCKER_REGISTRY_SERVER)/$(OPERATOR_IMAGE):$(GIT_COMMIT)

CMCTL = $(LOCAL_TESTBIN)/cmctl
$(CMCTL): | $(LOCAL_TMP) $(LOCAL_TESTBIN)
	curl -sSL -o $(LOCAL_TMP)/cmctl.tar.gz https://github.com/cert-manager/cert-manager/releases/download/v$(CERT_MANAGER_VERSION)/cmctl-$(platform)-$(shell go env GOARCH).tar.gz
	tar -C $(LOCAL_TMP) -xzf $(LOCAL_TMP)/cmctl.tar.gz
	mv $(LOCAL_TMP)/cmctl $(CMCTL)

CERT_MANAGER_VERSION ?= 1.9.2
.PHONY: cert-manager
cert-manager: | $(CMCTL) ## Setup cert-manager. Use CERT_MANAGER_VERSION to customise the version e.g. CERT_MANAGER_VERSION="1.9.2"
	@echo "Installing Cert Manager"
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v$(CERT_MANAGER_VERSION)/cert-manager.yaml
	$(CMCTL) check api --wait=5m

.PHONY: cert-manager-rm
cert-manager-rm:
	@echo "Deleting Cert Manager"
	kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v$(CERT_MANAGER_VERSION)/cert-manager.yaml --ignore-not-found

system-tests: install-tools ## Run end-to-end tests against Kubernetes cluster defined in ~/.kube/config
	NAMESPACE="$(SYSTEM_TEST_NAMESPACE)" K8S_OPERATOR_NAMESPACE="$(K8S_OPERATOR_NAMESPACE)" ginkgo -nodes=3 --randomize-all -r system_tests/

kubectl-plugin-tests: ## Run kubectl-rabbitmq tests
	@echo "running kubectl plugin tests"
	PATH=$(PWD)/bin:$$PATH ./bin/kubectl-rabbitmq.bats

.PHONY: tests
tests::unit-tests ## Runs all test suites: unit, integration, system and kubectl-plugin
tests::integration-tests
tests::system-tests
tests::kubectl-plugin-tests

docker-registry-secret:
	@$(call check_defined, DOCKER_REGISTRY_SERVER, URL of docker registry containing the Operator image e.g. registry.my-company.com)
	@$(call check_defined, DOCKER_REGISTRY_USERNAME, Username for accessing the docker registry e.g. robot-123)
	@$(call check_defined, DOCKER_REGISTRY_PASSWORD, Password for accessing the docker registry e.g. password)
	@$(call check_defined, DOCKER_REGISTRY_SECRET, Name of Kubernetes secret in which to store the Docker registry username and password)
	@printf "creating registry secret and patching default service account"
	@kubectl -n $(K8S_OPERATOR_NAMESPACE) create secret docker-registry $(DOCKER_REGISTRY_SECRET) --docker-server='$(DOCKER_REGISTRY_SERVER)' --docker-username="$$DOCKER_REGISTRY_USERNAME" --docker-password="$$DOCKER_REGISTRY_PASSWORD" || true
	@kubectl -n $(K8S_OPERATOR_NAMESPACE) patch serviceaccount rabbitmq-cluster-operator -p '{"imagePullSecrets": [{"name": "$(DOCKER_REGISTRY_SECRET)"}]}'

.PHONY: install-tools
install-tools: yj jq controller-gen kustomize govulncheck
	grep _ tools/tools.go | awk -F '"' '{print $$2}' | xargs -t go install -mod=mod

### Env Helpers: kind, dotenv, k9s, etc

### curl

CURL ?= /usr/bin/curl
$(CURL):
	@which $(CURL) \
	|| ( printf "$(RED)$(BOLD)$(CURL)$(NORMAL)$(RED) is missing, install $(BOLD)curl$(NORMAL)\n" ; exit 1)
.PHONY: curl
curl: $(CURL)

### envrc

XDG_CONFIG_HOME ?= $(CURDIR)/.config
envrc::
	@echo 'export XDG_CONFIG_HOME="$(XDG_CONFIG_HOME)"'
KUBECONFIG_DIR = $(XDG_CONFIG_HOME)/kubectl
KUBECONFIG ?= $(KUBECONFIG_DIR)/config
$(KUBECONFIG_DIR):
	mkdir -p $(@)
envrc::
	@echo 'export KUBECONFIG="$(KUBECONFIG)"'

LOCAL_BIN := $(CURDIR)/.bin
PATH := $(LOCAL_BIN):$(PATH)
export PATH

$(LOCAL_BIN):
	mkdir -p $@
envrc::
	@echo 'export PATH="$(PATH)"'

.PHONY: envrc
envrc:: ## Configure shell envrc - eval "$(make envrc)" OR rm .envrc && make .envrc && source .envrc
	@echo 'unalias m 2>/dev/null || true ; alias m=make'
.envrc:
	$(MAKE) --file $(lastword $(MAKEFILE_LIST)) --no-print-directory envrc SILENT="1>/dev/null 2>&1" > .envrc

.PHONY: bash-autocomplete
bash-autocomplete:
	@echo "$(BASH_AUTOCOMPLETE)"
envrc:: bash-autocomplete

KIND_CLUSTER_NAME ?= rabbitmq-operator-test
export KIND_CLUSTER_NAME
envrc::
	@echo 'export KIND_CLUSTER_NAME="$(KIND_CLUSTER_NAME)"'
KO_DOCKER_REPO := kind.local

### crd-ref-docs

CRD_REF_DOCS_RELEASES := https://github.com/elastic/crd-ref-docs/releases
CRD_REF_DOCS_VERSION := 0.0.9
CRD_REF_DOCS_URL := $(CRD_REF_DOCS_RELEASES)/download/v$(CRD_REF_DOCS_VERSION)/crd-ref-docs
CRD_REF_DOCS := $(LOCAL_BIN)/crd-ref-docs-$(CRD_REF_DOCS_VERSION)
$(CRD_REF_DOCS): | $(CURL) $(LOCAL_BIN)
	$(CURL) --progress-bar --fail --location --output $(CRD_REF_DOCS) "$(CRD_REF_DOCS_URL)"
	touch $(CRD_REF_DOCS)
	chmod +x $(CRD_REF_DOCS)
	ln -sf $(CRD_REF_DOCS) $(LOCAL_BIN)/crd-ref-docs
.PHONY: crd-ref-docs
crd-ref-docs: $(CRD_REF_DOCS)

### controller-gen

CONTROLLER_GEN_RELEASES := sigs.k8s.io/controller-tools/cmd/controller-gen
CONTROLLER_GEN_VERSION := 0.12.1
CONTROLLER_GEN_URL := $(CONTROLLER_GEN_RELEASES)@v$(CONTROLLER_GEN_VERSION)
CONTROLLER_GEN_GOPATH := $(LOCAL_BIN)/go
CONTROLLER_GEN := $(CONTROLLER_GEN_GOPATH)/bin/controller-gen
$(CONTROLLER_GEN): | $(CURL) $(LOCAL_BIN)
	GOPATH=$(CONTROLLER_GEN_GOPATH) go install $(CONTROLLER_GEN_URL)
	touch $(CONTROLLER_GEN)
	chmod +x $(CONTROLLER_GEN)
	ln -sf $(CONTROLLER_GEN) $(LOCAL_BIN)/controller-gen
.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN)

### govulncheck

GOVULNCHECK_RELEASES := golang.org/x/vuln/cmd/govulncheck
GOVULNCHECK_VERSION := 1.0.1
GOVULNCHECK_URL := $(GOVULNCHECK_RELEASES)@v$(GOVULNCHECK_VERSION)
GOVULNCHECK_GOPATH := $(LOCAL_BIN)/go
GOVULNCHECK := $(GOVULNCHECK_GOPATH)/bin/govulncheck
$(GOVULNCHECK): | $(CURL) $(LOCAL_BIN)
	GOPATH=$(GOVULNCHECK_GOPATH) go install $(GOVULNCHECK_URL)
	touch $(GOVULNCHECK)
	chmod +x $(GOVULNCHECK)
	ln -sf $(GOVULNCHECK) $(LOCAL_BIN)/govulncheck
.PHONY: govulncheck
govulncheck: $(GOVULNCHECK)

### kustomize

KUSTOMIZE_RELEASES := sigs.k8s.io/kustomize/kustomize/v4
KUSTOMIZE_VERSION := 4.5.7
KUSTOMIZE_URL := $(KUSTOMIZE_RELEASES)@v$(KUSTOMIZE_VERSION)
KUSTOMIZE_GOPATH := $(LOCAL_BIN)/go
KUSTOMIZE := $(KUSTOMIZE_GOPATH)/bin/kustomize
$(KUSTOMIZE): | $(CURL) $(LOCAL_BIN)
	GOPATH=$(KUSTOMIZE_GOPATH) GO111MODULE=on go install $(KUSTOMIZE_URL)
	touch $(KUSTOMIZE)
	chmod +x $(KUSTOMIZE)
	ln -sf $(KUSTOMIZE) $(LOCAL_BIN)/kustomize
.PHONY: kustomize
kustomize: $(KUSTOMIZE)

### yj

YJ_CARGO_NAME := yj
YJ_VERSION := 1.2.3
YJ_PACKAGE := $(YJ_CARGO_NAME)@$(YJ_VERSION)
YJ_CARGO_PATH := $(LOCAL_BIN)/cargo
YJ := $(YJ_CARGO_PATH)/bin/yj
$(YJ): | $(LOCAL_BIN)
	cargo install --root $(YJ_CARGO_PATH) $(YJ_PACKAGE)
	touch $(YJ)
	chmod +x $(YJ)
	ln -sf $(YJ) $(LOCAL_BIN)/yj
.PHONY: yj
yj: $(YJ)

### jq

JQ_RELEASES := https://github.com/jqlang/jq/releases
JQ_VERSION := 1.6
https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64
JQ_URL := $(JQ_RELEASES)/download/jq-$(JQ_VERSION)/jq-$(jq_platform)$(jq_arch)
JQ := $(LOCAL_BIN)/jq-$(JQ_VERSION)-$(jq_platform)$(jq_arch)
# We want to fail if variables are not set or empty.
JQ_SAFE := $(JQ) -no-unset -no-empty
$(JQ): | $(CURL) $(LOCAL_BIN)
	$(CURL) --progress-bar --fail --location --output $(JQ) "$(JQ_URL)"
	touch $(JQ)
	chmod +x $(JQ)
	ln -sf $(JQ) $(LOCAL_BIN)/jq
.PHONY: jq
jq: $(JQ)

### envsubst

# The envsubst that comes with gettext does not support this,
# using this Go version instead: https://github.com/a8m/envsubst#docs
ENVSUBST_RELEASES := https://github.com/a8m/envsubst/releases
ENVSUBST_VERSION := 1.4.2
ENVSUBST_URL := $(ENVSUBST_RELEASES)/download/v$(ENVSUBST_VERSION)/envsubst-$(PLATFORM)-$(ARCH)
ENVSUBST := $(LOCAL_BIN)/envsubst-$(ENVSUBST_VERSION)-$(PLATFORM)-$(ARCH)
# We want to fail if variables are not set or empty.
ENVSUBST_SAFE := $(ENVSUBST) -no-unset -no-empty
$(ENVSUBST): | $(CURL) $(LOCAL_BIN)
	$(CURL) --progress-bar --fail --location --output $(ENVSUBST) "$(ENVSUBST_URL)"
	touch $(ENVSUBST)
	chmod +x $(ENVSUBST)
	ln -sf $(ENVSUBST) $(LOCAL_BIN)/envsubst
.PHONY: envsubst
envsubst: $(ENVSUBST)

### kind

KIND_RELEASES := https://github.com/kubernetes-sigs/kind/releases
KIND_VERSION := 0.20.0
KIND_URL := $(KIND_RELEASES)/download/v$(KIND_VERSION)/kind-$(platform)-$(arch_alt)
KIND := $(LOCAL_BIN)/kind_$(KIND_VERSION)_$(platform)_$(arch_alt)
$(KIND): | $(CURL) $(LOCAL_BIN)
	$(CURL) --progress-bar --fail --location --output $(KIND) "$(KIND_URL)"
	touch $(KIND)
	chmod +x $(KIND)
	$(KIND) version | grep $(KIND_VERSION)
	ln -sf $(KIND) $(LOCAL_BIN)/kind
.PHONY: kind
kind: $(KIND)
.PHONY: releases-kind
releases-kind:
	$(OPEN) $(KIND_RELEASES)

### kubectl

KUBECTL_RELEASES := https://github.com/kubernetes/kubernetes/tags
# Keep this in sync with KIND_K8S_VERSION
KUBECTL_VERSION := 1.25.9
KUBECTL_BIN := kubectl-$(KUBECTL_VERSION)-$(platform)-$(arch_alt)
KUBECTL_URL := https://storage.googleapis.com/kubernetes-release/release/v$(KUBECTL_VERSION)/bin/$(platform)/amd64/kubectl
KUBECTL := $(LOCAL_BIN)/$(KUBECTL_BIN)
$(KUBECTL): | $(CURL) $(LOCAL_BIN)
	$(CURL) --progress-bar --fail --location --output $(KUBECTL) "$(KUBECTL_URL)"
	touch $(KUBECTL)
	chmod +x $(KUBECTL)
	$(KUBECTL) version | grep $(KUBECTL_VERSION)
	ln -sf $(KUBECTL) $(LOCAL_BIN)/kubectl
.PHONY: kubectl
kubectl: $(KUBECTL)
.PHONY: releases-kubectl
releases-kubectl:
	$(OPEN) $(KUBECTL_RELEASES)
K_CMD ?= apply
# Dump all objects (do not apply) if DEBUG variable is set
ifneq (,$(DEBUG))
K_CMD = create --dry-run=client --output=yaml
endif

### K9s

K9S_RELEASES := https://github.com/derailed/k9s/releases
K9S_VERSION := 0.25.18
K9S_BIN_DIR := $(LOCAL_BIN)/k9s-$(K9S_VERSION)-$(platform)-$(ARCH)
K9S_URL := $(K9S_RELEASES)/download/v$(K9S_VERSION)/k9s_$(platform)_$(ARCH).tar.gz
K9S := $(K9S_BIN_DIR)/k9s
$(K9S): | $(CURL) $(LOCAL_BIN) $(KUBECTL)
	$(CURL) --progress-bar --fail --location --output $(K9S_BIN_DIR).tar.gz "$(K9S_URL)"
	mkdir -p $(K9S_BIN_DIR) && tar zxf $(K9S_BIN_DIR).tar.gz -C $(K9S_BIN_DIR)
	touch $(K9S)
	chmod +x $(K9S)
	$(K9S) version | grep $(K9S_VERSION)
	ln -sf $(K9S) $(LOCAL_BIN)/k9s
.PHONY: releases-k9s
releases-k9s:
	$(OPEN) $(K9S_RELEASES)
.PHONY: k9s
K9S_ARGS ?= --all-namespaces
k9s: | $(KUBECONFIG) $(K9S) ## Terminal ncurses UI for K8S
	$(K9S) $(K9S_ARGS)

### kind-cluster

MIN_SUPPORTED_K8S_VERSION := 1.25.0
KIND_K8S_VERSION ?= $(MIN_SUPPORTED_K8S_VERSION)
export KIND_K8S_VERSION
# Find the corresponding version digest in https://github.com/kubernetes-sigs/kind/releases
KIND_K8S_DIGEST ?= sha256:227fa11ce74ea76a0474eeefb84cb75d8dad1b08638371ecf0e86259b35be0c8
export KIND_K8S_DIGEST

.PHONY: kind-cluster
kind-cluster: | $(KIND) $(ENVSUBST)
	( $(KIND) get clusters | grep $(KIND_CLUSTER_NAME) ) \
	|| ( cat $(CURDIR)/config/kind.yaml \
	     | $(ENVSUBST_SAFE) \
	     | $(KIND) -v1  create cluster --name $(KIND_CLUSTER_NAME) --config  - )

### kubeconfig

$(KUBECONFIG): | $(KUBECONFIG_DIR)
	$(MAKE) --no-print-directory kind-cluster
	$(KIND) get kubeconfig --name $(KIND_CLUSTER_NAME) > $(KUBECONFIG)

.PHONY: kubeconfig
kubeconfig: $(KUBECONFIG)
