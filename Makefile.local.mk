##@ Local

LOCAL := hack/local
KUBECTL := kubectl --context kind-kind
HELM := helm --kube-context kind-kind

.PHONY: local-up local-test local-token local-down

local-up: ## Create a kind cluster running the chart and the external API.
	kind create cluster --config .ats/kind-config.yaml
	$(HELM) dependency update helm/observability-platform
	KUBE_CONTEXT=kind-kind $(LOCAL)/install.sh helm/observability-platform

local-test: ## Verify the local install: workloads ready, Grafana up, one round trip per signal.
	$(LOCAL)/test.sh

local-token: ## Print a JWT for the external API, valid for one hour.
	@$(KUBECTL) exec -n jwt-issuer deploy/jwks -c signer -- /scripts/jwt.sh token

local-down: ## Delete the kind cluster and the local certificate.
	kind delete cluster
	rm -rf $(LOCAL)/.keys
