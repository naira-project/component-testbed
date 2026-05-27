# Flux GitRepository source name pointing to this repo.
# Override if your GitRepository has a different name:
#   FLUX_SOURCE=my-repo make testbed-mlflow-up
FLUX_SOURCE ?= component-testbed

# =============================================================================
# MLflow testbed
# =============================================================================

MLFLOW_NS        := naira-testbed-mlflow
MLFLOW_DIR       := mlflow
MLFLOW_SVC       := mlflow
MLFLOW_PORT      := 5000

.PHONY: testbed-mlflow-up testbed-mlflow-down testbed-mlflow-reset \
        testbed-mlflow-status testbed-mlflow-port-forward testbed-mlflow-seed \
        _mlflow-run-seed _mlflow-check-flux-source

## Provision MLflow testbed: deploy + seed sample data.
testbed-mlflow-up:
	@$(MAKE) _mlflow-check-flux-source
	@echo ">>> Applying Flux Kustomization..."
	FLUX_SOURCE=$(FLUX_SOURCE) envsubst < $(MLFLOW_DIR)/flux-kustomization.yaml | kubectl apply -f -
	@echo ">>> Waiting for Flux reconciliation..."
	kubectl wait --for=condition=ready kustomization/$(MLFLOW_NS) -n flux-system --timeout=180s
	@echo ">>> Running seed job..."
	$(MAKE) _mlflow-run-seed
	@echo ""
	@echo "MLflow testbed is up."
	@echo "  UI:  make testbed-mlflow-port-forward  →  http://127.0.0.1:$(MLFLOW_PORT)"
	@echo "  API: http://$(MLFLOW_SVC).$(MLFLOW_NS).svc.cluster.local:$(MLFLOW_PORT)"

## Tear down MLflow testbed: delete namespace and all resources.
testbed-mlflow-down:
	@echo ">>> Removing Flux Kustomization..."
	kubectl delete kustomization $(MLFLOW_NS) -n flux-system --ignore-not-found
	@echo ">>> Uninstalling MLflow Helm release..."
	helm uninstall $(MLFLOW_SVC) -n $(MLFLOW_NS) 2>/dev/null || true
	@echo ">>> Deleting namespace $(MLFLOW_NS)..."
	kubectl delete namespace $(MLFLOW_NS) --ignore-not-found --wait=true
	@echo "MLflow testbed removed."

## Full teardown + recreate from scratch.
testbed-mlflow-reset: testbed-mlflow-down testbed-mlflow-up

## Show pod status, service, and Flux reconciliation state.
testbed-mlflow-status:
	@echo "=== Pods ==="
	kubectl get pods -n $(MLFLOW_NS) 2>/dev/null || echo "(namespace not found)"
	@echo ""
	@echo "=== Services ==="
	kubectl get svc -n $(MLFLOW_NS) 2>/dev/null || true
	@echo ""
	@echo "=== PVCs ==="
	kubectl get pvc -n $(MLFLOW_NS) 2>/dev/null || true
	@echo ""
	@echo "=== Helm release ==="
	helm status $(MLFLOW_SVC) -n $(MLFLOW_NS) 2>/dev/null || echo "(Helm release not found)"
	@echo ""
	@echo "=== Flux Kustomization ==="
	kubectl get kustomization naira-testbed-mlflow -n flux-system 2>/dev/null || echo "(Flux Kustomization not found — apply mlflow/flux-kustomization.yaml to enable Flux reconciliation)"

## Open kubectl port-forward to http://127.0.0.1:5000.
testbed-mlflow-port-forward:
	@echo ">>> Forwarding http://127.0.0.1:$(MLFLOW_PORT) → svc/$(MLFLOW_SVC):$(MLFLOW_PORT)"
	@echo "    Press Ctrl+C to stop."
	kubectl port-forward svc/$(MLFLOW_SVC) $(MLFLOW_PORT):$(MLFLOW_PORT) -n $(MLFLOW_NS)

## Re-run the seed job without redeploying MLflow (idempotent).
testbed-mlflow-seed:
	$(MAKE) _mlflow-run-seed

# --- internal targets ---

_mlflow-check-flux-source:
	@kubectl get gitrepository $(FLUX_SOURCE) -n flux-system >/dev/null 2>&1 || { \
		echo "ERROR: Flux GitRepository '$(FLUX_SOURCE)' was not found in namespace 'flux-system'."; \
		echo ""; \
		echo "make testbed-mlflow-up applies a Flux Kustomization that expects an existing"; \
		echo "GitRepository source pointing at this repository."; \
		echo ""; \
		echo "Fix one of these first:"; \
		echo "  1. Reuse an existing Flux source:"; \
		echo "     FLUX_SOURCE=<existing-gitrepository> make testbed-mlflow-up"; \
		echo "  2. Create a Flux source for this repo in flux-system, for example:"; \
		echo "     flux create source git $(FLUX_SOURCE) --url=<repo-url> --branch=<branch> --namespace=flux-system"; \
		echo ""; \
		echo "You can inspect available sources with:"; \
		echo "  kubectl get gitrepositories -n flux-system"; \
		exit 1; \
	}

_mlflow-run-seed:
	@echo ">>> Deleting previous seed job (if any)..."
	kubectl delete job mlflow-seed -n $(MLFLOW_NS) --ignore-not-found
	@echo ">>> Applying seed job..."
	kubectl apply -f $(MLFLOW_DIR)/seed-job.yaml -n $(MLFLOW_NS)
	@echo ">>> Waiting for seed job to complete..."
	kubectl wait --for=condition=complete job/mlflow-seed -n $(MLFLOW_NS) --timeout=120s
	@echo ">>> Seed job finished."

# =============================================================================
# OpenBao platform component
# =============================================================================
#
# Command surfaces:
#   platform-openbao-*   — Platform Engineering operations (init, seed, reset)
#   testbed-openbao-*    — Developer read-only inspection
#
# Typical first-time setup:
#   make platform-openbao-up
#   make platform-openbao-init       # once per cluster lifetime
#   # encrypt unseal-keys-sealed.yaml, commit, kubectl apply -k
#   make platform-openbao-seed
#
# Subsequent re-seeds (e.g. after adding new API keys to .env.testbed):
#   make platform-openbao-seed

OPENBAO_NS       := naira-platform-openbao
OPENBAO_DIR      := infrastructure/platform/openbao
OPENBAO_SVC      := openbao-active
OPENBAO_API_PORT := 8200
# Pass FORCE=true to overwrite existing secrets: make platform-openbao-seed FORCE=true
FORCE            ?= false

.PHONY: platform-openbao-up platform-openbao-init platform-openbao-seed \
        platform-openbao-reset platform-openbao-upgrade \
        testbed-openbao-status testbed-openbao-port-forward \
        testbed-openbao-seed-status testbed-openbao-inspect \
        _openbao-wait-ready _openbao-run-init _openbao-run-seed \
        _openbao-require-token

## [PLATFORM] Deploy the OpenBao platform component and ESO via Flux/Kustomize.
platform-openbao-up:
	@echo ">>> Applying OpenBao platform manifests (namespaces, HelmReleases, RBAC)..."
	kubectl apply -k $(OPENBAO_DIR)/
	@echo ">>> Applying Flux Kustomization CR (optional — requires Flux in cluster)..."
	kubectl apply -f $(OPENBAO_DIR)/flux-kustomization.yaml 2>/dev/null || \
	  echo "    (Flux not available — manifests applied directly above)"
	@echo ">>> Waiting for ESO CRDs to be installed by Flux Helm controller..."
	@until kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; do \
	  echo "    ... waiting for clustersecretstores CRD"; sleep 5; \
	done
	@echo ">>> Applying ClusterSecretStore (requires ESO CRDs)..."
	kubectl apply -f $(OPENBAO_DIR)/eso/clustersecretstore.yaml
	@echo ""
	@echo "OpenBao platform component applied."
	@echo "  OpenBao will start but remain sealed until you run:"
	@echo "    make platform-openbao-init"

## [PLATFORM] Initialize OpenBao (one-time per cluster). Creates openbao-unseal-keys Secret.
platform-openbao-init: _openbao-run-init

## [PLATFORM] Seed OpenBao with engines, auth, policies, and secrets from .env.testbed.
platform-openbao-seed:
	@if [ ! -f .env.testbed ]; then \
	  echo "ERROR: .env.testbed not found."; \
	  echo "  cp .env.testbed.example .env.testbed  # then fill in values"; \
	  exit 1; \
	fi
	$(MAKE) _openbao-run-seed

## [PLATFORM] Full teardown + redeploy from scratch. Destroys all secrets in OpenBao.
platform-openbao-reset:
	@echo ">>> Deleting namespace $(OPENBAO_NS)..."
	kubectl delete namespace $(OPENBAO_NS) --ignore-not-found --wait=true
	kubectl delete namespace external-secrets --ignore-not-found --wait=true
	@echo ">>> Redeploying..."
	$(MAKE) platform-openbao-up

## [PLATFORM] Update OpenBao chart version. Edit helmrelease-openbao.yaml first, then run this.
platform-openbao-upgrade:
	@echo ">>> Applying updated HelmRelease..."
	kubectl apply -f $(OPENBAO_DIR)/helmrelease-openbao.yaml
	@echo ">>> Triggering Flux reconciliation (if Flux is running)..."
	kubectl annotate helmrelease openbao -n $(OPENBAO_NS) \
	  reconcile.fluxcd.io/requestedAt="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
	@echo "OpenBao upgrade triggered."

## [DEVELOPER] Show OpenBao platform component status.
testbed-openbao-status:
	@echo "=== Pods ==="
	kubectl get pods -n $(OPENBAO_NS) 2>/dev/null || echo "(namespace not found)"
	@echo ""
	@echo "=== Services ==="
	kubectl get svc -n $(OPENBAO_NS) 2>/dev/null || true
	@echo ""
	@echo "=== PVCs ==="
	kubectl get pvc -n $(OPENBAO_NS) 2>/dev/null || true
	@echo ""
	@echo "=== Seal Status ==="
	kubectl exec -n $(OPENBAO_NS) statefulset/openbao -c openbao -- \
	  bao status 2>/dev/null || echo "(pod not ready)"
	@echo ""
	@echo "=== ClusterSecretStore ==="
	kubectl get clustersecretstore openbao-platform 2>/dev/null || \
	  echo "(ClusterSecretStore not found — ESO may still be deploying)"
	@echo ""
	@echo "=== Flux Kustomization ==="
	kubectl get kustomization naira-platform-openbao -n flux-system 2>/dev/null || \
	  echo "(Flux Kustomization not found — apply $(OPENBAO_DIR)/flux-kustomization.yaml)"

## [DEVELOPER] Port-forward OpenBao API and UI to http://127.0.0.1:8200.
testbed-openbao-port-forward:
	@echo ">>> Forwarding http://127.0.0.1:$(OPENBAO_API_PORT) → svc/$(OPENBAO_SVC):$(OPENBAO_API_PORT)"
	@echo "    UI: http://127.0.0.1:$(OPENBAO_API_PORT)/ui"
	@echo "    Press Ctrl+C to stop."
	kubectl port-forward svc/$(OPENBAO_SVC) $(OPENBAO_API_PORT):$(OPENBAO_API_PORT) -n $(OPENBAO_NS)

## [DEVELOPER] Show which secret paths are currently seeded in OpenBao.
testbed-openbao-seed-status: _openbao-require-token
	@echo "=== Seeded Paths ==="
	@echo ""
	@echo "--- secret/demo/ ---"
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao kv list secret/demo/ 2>/dev/null || echo "(empty or not seeded)"
	@echo ""
	@echo "--- secret/testbed/ ---"
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao kv list secret/testbed/ 2>/dev/null || echo "(empty or not seeded)"
	@echo ""
	@echo "Tip: run 'make testbed-openbao-port-forward' in a separate terminal first."

## [DEVELOPER] Show enabled secret engines and auth methods.
testbed-openbao-inspect: _openbao-require-token
	@echo "=== Enabled Secret Engines ==="
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao secrets list 2>/dev/null || echo "(OpenBao not reachable — run port-forward first)"
	@echo ""
	@echo "=== Enabled Auth Methods ==="
	BAO_ADDR=http://127.0.0.1:$(OPENBAO_API_PORT) \
	BAO_TOKEN=$$(kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) \
	  -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) \
	bao auth list 2>/dev/null || true

# --- internal targets ---

_openbao-require-token:
	@kubectl get secret openbao-unseal-keys -n $(OPENBAO_NS) >/dev/null 2>&1 || \
	  { echo "ERROR: openbao-unseal-keys Secret not found — run platform-openbao-init first."; exit 1; }

_openbao-wait-ready:
	@echo ">>> Waiting for OpenBao pod to be ready (may take 60–90s on first deploy)..."
	kubectl wait pod/openbao-0 -n $(OPENBAO_NS) --for=condition=Ready --timeout=180s

_openbao-run-init:
	@echo ">>> Deleting previous init job (if any)..."
	kubectl delete job openbao-init -n $(OPENBAO_NS) --ignore-not-found
	@echo ">>> Applying init job..."
	kubectl apply -f $(OPENBAO_DIR)/init-job.yaml
	@echo ">>> Waiting for init job to complete..."
	kubectl wait --for=condition=complete job/openbao-init -n $(OPENBAO_NS) --timeout=120s
	@echo ">>> Init job finished."
	@echo ""
	@echo ">>> Restarting OpenBao pod so unsealer sidecar picks up the unseal key..."
	@echo "    (StatefulSet uses OnDelete — pod must be deleted manually)"
	kubectl delete pod openbao-0 -n $(OPENBAO_NS)
	@echo ">>> Waiting for OpenBao pod to be ready and unsealed..."
	kubectl wait pod/openbao-0 -n $(OPENBAO_NS) --for=condition=Ready --timeout=120s
	@echo ""
	@echo "OpenBao initialized and unsealed."
	@echo "  Next steps printed above by the init job."

_openbao-run-seed:
	@echo ">>> Creating openbao-seed-input Secret from .env.testbed..."
	kubectl create secret generic openbao-seed-input \
	  -n $(OPENBAO_NS) \
	  --from-env-file=.env.testbed \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo ">>> Deleting previous seed job (if any)..."
	kubectl delete job openbao-seed -n $(OPENBAO_NS) --ignore-not-found
	kubectl delete configmap openbao-seed-script -n $(OPENBAO_NS) --ignore-not-found
	@echo ">>> Applying seed job..."
	@if [ "$(FORCE)" = "true" ]; then \
	  sed 's/value: "false"/value: "true"/' $(OPENBAO_DIR)/seed-job.yaml \
	    | kubectl apply -f -; \
	else \
	  kubectl apply -f $(OPENBAO_DIR)/seed-job.yaml; \
	fi
	@echo ">>> Waiting for seed job to complete..."
	kubectl wait --for=condition=complete job/openbao-seed -n $(OPENBAO_NS) --timeout=180s
	@echo ">>> Cleaning up openbao-seed-input Secret..."
	kubectl delete secret openbao-seed-input -n $(OPENBAO_NS) --ignore-not-found
	@echo ">>> Seed job finished."
