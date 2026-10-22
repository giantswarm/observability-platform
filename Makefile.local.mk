##@ Local

LOCAL := hack/local
KUBECTL := kubectl --context kind-kind
HELM := helm --kube-context kind-kind
# observability-operator release installed before the chart. Keep in step with the
# version the platform is tested against.
OPERATOR_VERSION := 0.86.0

.PHONY: local-up local-test local-token local-down

local-up: ## Create a kind cluster running the chart and the external API.
	kind create cluster --config $(LOCAL)/kind.yaml
	$(HELM) upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version 1.9.1 \
	  --namespace envoy-gateway-system --create-namespace --wait --timeout 10m
	$(LOCAL)/tls.sh
	$(KUBECTL) create secret tls local-https-tls -n envoy-gateway-system \
	  --cert=$(LOCAL)/.keys/tls.crt --key=$(LOCAL)/.keys/tls.key \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -k $(LOCAL)/envoy-gateway/kind
	$(LOCAL)/jwt.sh jwks
	$(KUBECTL) create namespace jwt-issuer --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) create configmap jwks -n jwt-issuer --from-file=$(LOCAL)/.keys/jwks.json \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f $(LOCAL)/jwks.yaml
	$(HELM) upgrade --install observability-operator observability-operator \
	  --repo https://giantswarm.github.io/control-plane-catalog/ --version $(OPERATOR_VERSION) \
	  --namespace monitoring --create-namespace \
	  --values values/observability-operator.yaml --wait --timeout 5m
	$(HELM) dependency update helm/observability-platform
	$(HELM) upgrade --install observability-platform helm/observability-platform \
	  --namespace monitoring --create-namespace \
	  --values helm/observability-platform/values-local.yaml \
	  --values $(LOCAL)/values.yaml

local-test: ## Verify the local install: workloads ready, Grafana up, one round trip per signal.
	$(LOCAL)/test.sh

local-token: ## Print a JWT for the external API, valid for one hour.
	@$(LOCAL)/jwt.sh token

local-down: ## Delete the kind cluster, the signing key and the local certificate.
	kind delete cluster
	rm -rf $(LOCAL)/.keys
