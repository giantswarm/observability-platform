##@ Local

LOCAL := hack/local
KUBECTL := kubectl --context kind-kind
HELM := helm --kube-context kind-kind
# app-test-suite image `make local-ats` runs. Keep in step with .circleci/custom.yml.
ATS_VERSION := 1.1.0

.PHONY: local-up local-ats local-token local-down

local-up: ## Create a kind cluster running the chart and the external API.
	kind create cluster --config .ats/kind-config.yaml
	$(HELM) dependency update helm/observability-platform
	KUBE_CONTEXT=kind-kind $(LOCAL)/install.sh helm/observability-platform

local-ats: ## Run the app-test-suite smoke test on a new kind cluster `ats`, as CI does. Needs port 8443 free.
	rm -rf build
	helm dependency update helm/observability-platform
	helm package helm/observability-platform --destination build
	kind create cluster --name ats --config .ats/kind-config.yaml --kubeconfig build/kube.config
	docker run --rm -e USE_UID=$$(id -u) -e USE_GID=$$(id -g) -v $$(pwd):/ats/workdir --network host \
	  gsoci.azurecr.io/giantswarm/app-test-suite:$(ATS_VERSION) \
	  --chart-file $$(ls build/observability-platform-*.tgz) --cluster-kubeconfig build/kube.config \
	  --cluster-type kind; \
	  status=$$?; kind delete cluster --name ats; exit $$status

local-token: ## Print a JWT for the external API, valid for one hour.
	@$(KUBECTL) exec -n jwt-issuer deploy/jwks -c signer -- /scripts/jwt.sh token

local-down: ## Delete the kind cluster and the local certificate.
	kind delete cluster
	rm -rf $(LOCAL)/.keys
