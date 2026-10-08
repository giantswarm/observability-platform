##@ Local

LOCAL := hack/local
KUBECTL := kubectl --context kind-kind
HELM := helm --kube-context kind-kind

.PHONY: local-up local-token local-down test-render

local-up: ## Create a kind cluster running the chart and the external API.
	kind create cluster --config $(LOCAL)/kind.yaml
	$(HELM) upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version 1.9.1 \
	  --namespace envoy-gateway-system --create-namespace --wait --timeout 10m
	$(KUBECTL) apply -f $(LOCAL)/envoy-gateway.yaml
	$(LOCAL)/jwt.sh jwks
	$(KUBECTL) create namespace jwt-issuer --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) create configmap jwks -n jwt-issuer --from-file=$(LOCAL)/.keys/jwks.json \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f $(LOCAL)/jwks.yaml
	$(HELM) dependency update helm/observability-platform
	$(HELM) upgrade --install observability-platform helm/observability-platform \
	  --namespace monitoring --create-namespace \
	  --values helm/observability-platform/values-local.yaml \
	  --values $(LOCAL)/values.yaml

local-token: ## Print a JWT for the external API, valid for one hour.
	@$(LOCAL)/jwt.sh token

local-down: ## Delete the kind cluster and the signing key.
	kind delete cluster
	rm -rf $(LOCAL)/.keys

##@ Test

test-render: ## Run the chart render checks (operator guards and Standalone profile).
	helm dependency build helm/observability-platform
	hack/test-render.sh
