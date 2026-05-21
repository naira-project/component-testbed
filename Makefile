# Flux GitRepository source name pointing to this repo.
# Override if your GitRepository has a different name:
#   FLUX_SOURCE=my-repo make testbed-mlflow-up
FLUX_SOURCE ?= component-testbed

MLFLOW_NS        := naira-testbed-mlflow
MLFLOW_DIR       := mlflow
MLFLOW_SVC       := mlflow
MLFLOW_PORT      := 5000

.PHONY: testbed-mlflow-up testbed-mlflow-down testbed-mlflow-reset \
        testbed-mlflow-status testbed-mlflow-port-forward testbed-mlflow-seed \
        _mlflow-run-seed

## Provision MLflow testbed: deploy + seed sample data.
testbed-mlflow-up:
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

_mlflow-run-seed:
	@echo ">>> Deleting previous seed job (if any)..."
	kubectl delete job mlflow-seed -n $(MLFLOW_NS) --ignore-not-found
	@echo ">>> Applying seed job..."
	kubectl apply -f $(MLFLOW_DIR)/seed-job.yaml -n $(MLFLOW_NS)
	@echo ">>> Waiting for seed job to complete..."
	kubectl wait --for=condition=complete job/mlflow-seed -n $(MLFLOW_NS) --timeout=120s
	@echo ">>> Seed job finished."
