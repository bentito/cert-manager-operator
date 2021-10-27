GO_REQUIRED_MIN_VERSION = 1.16

RUNTIME?=docker

APP_NAME?=cert-manager-operator
IMAGE_REGISTRY?=registry.svc.ci.openshift.org

CONTROLLER_GEN_VERSION=v0.6.0
VERSION?=4.9.0

BUNDLE_IMAGE_NAME=cert-manager-operator-bundle
BUNDLE_IMAGE_PATH=$(IMAGE_REGISTRY)/$(BUNDLE_IMAGE_NAME)
BUNDLE_IMAGE_TAG?=latest

TEST_OPERATOR_NAMESPACE?=openshift-cert-manager-operator

MANIFEST_SOURCE = https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml

OPERATOR_SDK_VERSION?=v1.12.0
OPERATOR_SDK?=$(PERMANENT_TMP_GOPATH)/bin/operator-sdk-$(OPERATOR_SDK_VERSION)
OPERATOR_SDK_DIR=$(dir $(OPERATOR_SDK))

# Image URL to use all building/pushing image targets
IMG ?= controller:latest

KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

# Include the library makefiles
include $(addprefix ./vendor/github.com/openshift/build-machinery-go/make/, \
	golang.mk \
	targets/openshift/bindata.mk \
	targets/openshift/images.mk \
	targets/openshift/imagebuilder.mk \
	targets/openshift/deps.mk \
	targets/openshift/operator/telepresence.mk \
	targets/openshift/operator/profile-manifests.mk \
	targets/openshift/crd-schema-gen.mk \
)


# $1 - target name
# $2 - apis
# $3 - manifests
# $4 - output
$(call add-crd-gen,operator-alpha,./apis/operator/v1alpha1,./bundle/manifests,./bundle/manifests)
$(call add-crd-gen,config-alpha,./apis/config/v1alpha1,./bundle/manifests,./bundle/manifests)

# generate bindata targets
$(call add-bindata,assets,./bindata/...,bindata,assets,pkg/operator/assets/bindata.go)

# generate image targets
$(call build-image,cert-manager-operator,$(IMAGE_REGISTRY)/ocp/4.9:cert-manager-operator,./images/ci/Dockerfile,.)

# exclude e2e test from unit tests
GO_TEST_PACKAGES :=./pkg/... ./cmd/...

# re-use test-unit target for e2e tests
.PHONY: test-e2e
test-e2e: GO_TEST_PACKAGES :=./test/e2e/...
test-e2e: test-unit

update-manifests:
	hack/update-cert-manager-manifests.sh $(MANIFEST_SOURCE)
.PHONY: update-manifests

update-scripts:
	hack/update-deepcopy.sh
	hack/update-clientgen.sh
.PHONY: update-scripts
update: update-scripts update-codegen-crds update-manifests

verify-scripts:
	hack/verify-deepcopy.sh
	hack/verify-clientgen.sh
.PHONY: verify-scripts
verify: verify-scripts verify-codegen-crds

local-deploy-manifests:
	kubectl apply -f ./manifests
	kubectl apply -f ./bundle/manifests
.PHONY: local-deploy-manifests

local-run:
	./cert-manager-operator start --config=./hack/local-run-config.yaml --kubeconfig=$${KUBECONFIG:-$$HOME/.kube/config} --namespace=openshift-cert-manager-operator
.PHONY: local-run

local-clean:
	- oc delete namespace cert-manager
	- oc delete -f ./bindata/cert-manager-crds
.PHONY: local-clean

operator-build-bundle:
	$(RUNTIME) build -t $(BUNDLE_IMAGE_PATH):$(BUNDLE_IMAGE_TAG) -f ./bundle.Dockerfile .
.PHONY: operator-build-bundle

.PHONY: bundle
bundle: manifests kustomize ## Generate bundle manifests and metadata, then validate generated files.
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

operator-push-bundle: operator-build-bundle
	$(RUNTIME) push $(BUNDLE_IMAGE_PATH):$(BUNDLE_IMAGE_TAG)
.PHONY: operator-push-bundle

ensure-operator-sdk:
ifeq "" "$(wildcard $(OPERATOR_SDK))"
	$(info Installing Operator SDK into '$(OPERATOR_SDK)')
	mkdir -p '$(OPERATOR_SDK_DIR)'
	curl -L https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$(shell go env GOOS)_$(shell go env GOHOSTARCH) -o $(OPERATOR_SDK)
	chmod +x $(OPERATOR_SDK)
else
	$(info Using existing Operator SDK from "$(OPERATOR_SDK)")
endif
.PHONY: ensure-operator-sdk

operator-run-bundle: ensure-operator-sdk
	- kubectl create namespace $(TEST_OPERATOR_NAMESPACE)
	$(OPERATOR_SDK) run bundle $(BUNDLE_IMAGE_PATH):$(BUNDLE_IMAGE_TAG) --namespace $(TEST_OPERATOR_NAMESPACE)
.PHONY: operator-run-bundle

operator-clean:
	- kubectl delete namespace $(TEST_OPERATOR_NAMESPACE)
.PHONY: operator-clean