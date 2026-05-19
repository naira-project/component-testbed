# MLflow Testbed

Reproducible MLflow Tracking Server and Model Registry for developing and testing the Naira MLflow Sync Plugin.

Deployed as a Kubernetes workload in namespace `naira-testbed-mlflow`, managed via Kustomize (with Helm chart inflation) and optionally reconciled by Flux.

## Purpose

The Naira MLflow Sync Controller translates MLflow Registered Models and Model Versions into Naira's generic entity format. This testbed provides a real MLflow instance pre-seeded with sample data so the plugin team can develop and test locally without manually installing or configuring MLflow.

## Prerequisites

- `kubectl` configured against a Kubernetes cluster (Minikube is supported)
- `helm`
- `make`
- For Flux reconciliation: Flux installed (source-controller + helm-controller) and a `GitRepository` named `component-testbed` pointing to this repo

## Quick Start

```bash
# Provision MLflow and seed sample data (~2 min)
make testbed-mlflow-up

# Access the UI locally
make testbed-mlflow-port-forward
# → open http://localhost:5000 in your browser
```

Tear down:

```bash
make testbed-mlflow-down
```

## Commands

| Command                            | Description                                    |
| ---------------------------------- | ---------------------------------------------- |
| `make testbed-mlflow-up`           | Deploy MLflow and run the seed job             |
| `make testbed-mlflow-down`         | Delete the namespace and all resources         |
| `make testbed-mlflow-reset`        | Tear down and recreate from scratch            |
| `make testbed-mlflow-status`       | Show pods, services, PVCs, and Flux state      |
| `make testbed-mlflow-port-forward` | Forward `localhost:5000` to the MLflow service |
| `make testbed-mlflow-seed`         | Re-run the seed job (idempotent)               |

## Seeded Data

The seed job (`seed-job.yaml`) populates the Model Registry with:

| Model                 | Versions | Aliases                   |
| --------------------- | -------- | ------------------------- |
| `text-classifier-v1`  | 2        | staging, production       |
| `sentiment-analyzer`  | 3        | (none), staging, production |
| `summarization-model` | 2        | staging, production       |

Each version includes tags (`framework`, `task`, `validated_by`) and logged metrics (`accuracy`/`f1_score`/`latency_ms` or `rouge1`/`rouge2`/`latency_ms`).

One experiment (`testbed-experiments`) is created with 2 baseline runs.

The seed script is **idempotent**: re-running `make testbed-mlflow-seed` does not create duplicates.

MLflow 3 removes lifecycle stages (Staging/Production). The seed uses model version aliases instead (`staging`, `production`).

## Accessing MLflow from Within the Cluster

Other pods in the cluster can reach the MLflow API at:

```
http://mlflow.naira-testbed-mlflow.svc.cluster.local:5000
```

Example — list registered models from another pod:

```bash
curl http://mlflow.naira-testbed-mlflow.svc.cluster.local:5000/api/2.0/mlflow/registered-models/list
```

Set the tracking URI in your plugin code:

```python
import mlflow
mlflow.set_tracking_uri("http://mlflow.naira-testbed-mlflow.svc.cluster.local:5000")
```

## Flux Reconciliation (Optional)

If Flux is installed (source-controller + helm-controller), apply `flux-kustomization.yaml` to enable GitOps reconciliation:

```bash
# Substitute your GitRepository source name if different from 'component-testbed'
FLUX_SOURCE=component-testbed envsubst < mlflow/flux-kustomization.yaml | kubectl apply -f -

# Check reconciliation state
make testbed-mlflow-status
```

Flux applies the `mlflow/flux/` overlay, which creates a `HelmRepository` and `HelmRelease`. The helm-controller then installs the chart. Flux will re-apply automatically on every push.

## Architecture

```
naira-testbed-mlflow namespace
├── Deployment/mlflow          — MLflow Tracking Server (community-charts/mlflow v1.8.1)
│     image: burakince/mlflow:3.7.0
│     backend: SQLite at /mlflow/data/mlflow.db
│     artifacts: /mlflow/data/artifacts (proxied through server)
│     resources: 250m CPU, 2Gi–4Gi RAM
├── Service/mlflow             — ClusterIP :5000
├── PersistentVolumeClaim      — 1Gi (data survives pod restarts)
└── Job/mlflow-seed            — one-shot Python seed job (idempotent)
```

No Ingress is configured. Use `make testbed-mlflow-port-forward` for local browser access.

## Manifest Layout

```
mlflow/
├── kustomization.yaml        # Kustomize base: namespace + pvc only
├── values.yaml               # Helm chart values (community-charts/mlflow v1.8.1)
├── flux-kustomization.yaml   # Flux Kustomization CR pointing to mlflow/flux/
├── namespace.yaml
├── pvc.yaml
├── seed-job.yaml             # ConfigMap (seed.py) + Job
└── flux/
    ├── kustomization.yaml    # Flux overlay: namespace + pvc + HelmRepository + HelmRelease
    ├── helm-repository.yaml  # Flux HelmRepository (community-charts, flux-system ns)
    └── helm-release.yaml     # Flux HelmRelease for community-charts/mlflow
```
