##@ Local

LOCAL := hack/local
KUBECTL := kubectl --context kind-kind
HELM := helm --kube-context kind-kind
# app-test-suite image `make local-ats` runs. Keep in step with .circleci/custom.yml.
ATS_VERSION := 1.1.0
# Object storage backend of the local setup: `s3` runs Garage, `azure` runs Azurite.
LOCAL_BACKEND ?= s3
# Toggles of hack/local/config.env that `make local-up` turns on: the whole local setup.
LOCAL_TOGGLES := INSTALL_ENVOY_GATEWAY=true CREATE_GATEWAY=true INSTALL_CERT_MANAGER=true \
  DEPLOY_JWT_ISSUER=true CREATE_TLS_SECRET=true INSTALL_CNPG=true CREATE_GRAFANA_SECRET_KEY=true \
  INSTALL_PLUGIN_BARMAN_CLOUD=true GATEWAY_OVERLAY=kind
# Markers `make verify` selects.
VERIFY_MARKERS ?= smoke or verify

.PHONY: local-up local-ats local-token local-down verify verify-health

local-up: ## Create a kind cluster running the chart and the external API. LOCAL_BACKEND=azure runs Azurite.
	kind create cluster --config .ats/kind-config.yaml
	$(HELM) dependency update helm/observability-platform
	$(LOCAL_TOGGLES) KUBE_CONTEXT=kind-kind LOCAL_BACKEND=$(LOCAL_BACKEND) $(LOCAL)/install.sh helm/observability-platform
	# One AgentCredential per backend, for the agent write routes. install.sh leaves them out.
	$(KUBECTL) apply -f $(LOCAL)/agentcredentials.yaml

local-ats: ## Run the app-test-suite smoke test on a new kind cluster `ats`, as CI does. Needs ports 8080 and 8443 free.
	rm -rf build
	helm dependency update helm/observability-platform
	helm package helm/observability-platform --destination build
	kind create cluster --name ats --config .ats/kind-config.yaml --kubeconfig build/kube.config
	# The run writes its target file to build/.env.verify. The target file of `make local-up` stays.
	touch build/.env.verify
	docker run --rm -e USE_UID=$$(id -u) -e USE_GID=$$(id -g) -v $$(pwd):/ats/workdir --network host \
	  -v $$(pwd)/build/.env.verify:/ats/workdir/.env.verify \
	  gsoci.azurecr.io/giantswarm/app-test-suite:$(ATS_VERSION) \
	  --chart-file $$(ls build/observability-platform-*.tgz) --cluster-kubeconfig build/kube.config \
	  --cluster-type kind; \
	  status=$$?; kind delete cluster --name ats; exit $$status

local-token: ## Print a JWT for the external API, valid for one hour.
	@$(KUBECTL) exec -n jwt-issuer deploy/jwks -c signer -- /scripts/jwt.sh token

local-down: ## Delete the kind cluster, the local certificate and the target file.
	kind delete cluster
	rm -rf $(LOCAL)/.keys .env.verify

##@ Verification

verify: ## Verify the platform the inputs or .env.verify name. VERIFY_MARKERS selects the checks.
	cd tests/ats && uv run pytest -m "$(VERIFY_MARKERS)" -v -rs --tb=short

verify-health: ## Run the read-only health checks against the platform the inputs or .env.verify name. Needs no external API.
	cd tests/ats && uv run pytest -m health -v -rs --tb=short
