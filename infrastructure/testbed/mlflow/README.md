# MLflow Testbed

Reproducible MLflow Tracking Server and Model Registry for developing and testing the Naira MLflow Sync Plugin.

Deployed as a Kubernetes workload in namespace `naira-testbed-mlflow` by default, reconciled by Flux.

## Purpose

The Naira MLflow Sync Controller translates MLflow Registered Models and Model Versions into Naira's generic entity format. This testbed provides a real MLflow instance pre-seeded with sample data so the plugin team can develop and test locally without manually installing or configuring MLflow.

## Prerequisites

- `kubectl` configured against a Kubernetes cluster (Minikube is supported)
- `helm`
- `make`
- `envsubst`
- Flux installed (source-controller + helm-controller)
- A Flux `GitRepository` in `flux-system` that points to this repo
  - By default, `make testbed-mlflow-up` expects that source to be named `component-testbed`
  - If your source has a different name, pass it via `FLUX_SOURCE=<name>`

## Quick Start

```bash
# Reconcile MLflow via Flux and seed sample data (~2 min)
make testbed-mlflow-up

# Optional: use a developer-owned namespace
NS=my-mlflow make testbed-mlflow-up

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

| Model                 | Versions | Aliases                     |
| --------------------- | -------- | --------------------------- |
| `text-classifier-v1`  | 2        | staging, production         |
| `sentiment-analyzer`  | 3        | (none), staging, production |
| `summarization-model` | 2        | staging, production         |

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

## Flux Reconciliation

If Flux is installed (source-controller + helm-controller), apply `flux-kustomization.yaml` to enable GitOps reconciliation:

```bash
# Substitute your GitRepository source name if different from 'component-testbed'
FLUX_SOURCE=component-testbed envsubst < infrastructure/testbed/mlflow/flux-kustomization.yaml | kubectl apply -f -

# Check reconciliation state
make testbed-mlflow-status
```

Flux applies `infrastructure/testbed/mlflow/kustomization.yaml`, which creates a `GitRepository` for `mlflow/mlflow` and a `HelmRelease`. The helm-controller then installs the official chart from the pinned Git commit. Flux will re-apply automatically on every push.

### Common Error: `GitRepository.source.toolkit.fluxcd.io "component-testbed" not found`

This happens when Flux is installed, but there is no `GitRepository` source in `flux-system` for this repository. `make testbed-mlflow-up` only creates the MLflow `Kustomization`; it does not bootstrap Flux against this repo or create that source for you.

Check which sources already exist:

```bash
kubectl get gitrepositories -n flux-system
```

Then fix it in one of these ways:

```bash
# Option 1: Reuse an existing source name
FLUX_SOURCE=<existing-gitrepository> make testbed-mlflow-up
```

```bash
# Option 2: Create a source for this repo and keep the default name
flux create source git component-testbed \
  --url=<repo-url> \
  --branch=<branch> \
  --namespace=flux-system

make testbed-mlflow-up
```

If you bootstrap Flux from this repository, Flux will usually create the matching source automatically. The important part is that the `spec.sourceRef.name` in `infrastructure/testbed/mlflow/flux-kustomization.yaml` must match a real `GitRepository` in `flux-system`.

## Architecture

```
naira-testbed-mlflow namespace
├── Deployment/mlflow          — MLflow Tracking Server (official mlflow/mlflow chart)
│     image: ghcr.io/mlflow/mlflow:v3.12.0-full
│     backend: SQLite at /mlflow/mlflow.db
│     artifacts: /mlflow/artifacts (proxied through server)
│     workers: 1; BLAS/math libraries capped to one thread per process
│     resources: 500m–2 CPU, 512Mi–2Gi RAM
├── Service/mlflow             — ClusterIP :5000
├── PersistentVolumeClaim/mlflow — 1Gi (data survives pod restarts)
└── Job/mlflow-seed            — one-shot Python seed job (idempotent)
```

No Ingress is configured. Use `make testbed-mlflow-port-forward` for local browser access.

## Manifest Layout

```
infrastructure/testbed/mlflow/
├── kustomization.yaml        # Namespace + GitRepository + HelmRelease
├── flux-kustomization.yaml   # Flux Kustomization CR pointing to infrastructure/testbed/mlflow/
├── git-repository.yaml       # Flux GitRepository (mlflow/mlflow, pinned commit)
├── helm-release.yaml         # Flux HelmRelease for official chart path ./charts
├── namespace.yaml
└── seed-job.yaml             # ConfigMap (seed.py) + Job
```
