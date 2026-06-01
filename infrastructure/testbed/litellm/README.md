# LiteLLM Testbed

Reproducible LiteLLM Proxy for developing and testing the Naira LiteLLM plugin against real in-cluster networking and the live Mistral API.

Deployed as a Kubernetes workload in namespace `naira-testbed-litellm`, reconciled by Flux, using the official LiteLLM Helm chart `oci://docker.litellm.ai/berriai/litellm-helm` at tag `1.82.3`.

## Purpose

The Naira LiteLLM plugin will discover LiteLLM routes and translate them into Naira inference endpoint concepts. This testbed provides a deterministic LiteLLM Proxy with preconfigured Mistral routes so plugin development and CI smoke tests can use real provider responses instead of mocks.

## Prerequisites

- `kubectl` configured against a Kubernetes cluster
- `helm`
- `make`
- `envsubst`
- Flux installed with source-controller and helm-controller
- External Secrets Operator installed
- A `ClusterSecretStore` named `openbao-platform`
- A Flux `GitRepository` in `flux-system` that points to this repo
  - By default, `make testbed-litellm-up` expects that source to be named `component-testbed`
  - If your source has a different name, pass it via `FLUX_SOURCE=<name>`
- A Mistral API key seeded by the OpenBao platform component from `LITELLM_MISTRAL_API_KEY`

## Quick Start

```bash
# Reconcile LiteLLM via Flux and run chat + embeddings smoke tests
make testbed-litellm-up

# Access the API locally
make testbed-litellm-port-forward
```

The local API is then available at:

```text
http://localhost:4000
```

Tear down:

```bash
make testbed-litellm-down
```

## Commands

| Command                             | Description                                                |
| ----------------------------------- | ---------------------------------------------------------- |
| `make testbed-litellm-up`           | Deploy LiteLLM through Flux and run the smoke test         |
| `make testbed-litellm-down`         | Delete the Flux Kustomization, Helm release, and namespace |
| `make testbed-litellm-reset`        | Tear down and recreate from scratch                        |
| `make testbed-litellm-status`       | Show pods, service, ExternalSecret, Helm, and Flux state   |
| `make testbed-litellm-port-forward` | Forward `localhost:4000` to the LiteLLM service            |
| `make testbed-litellm-smoke`        | Re-run the chat completion and embeddings smoke test       |
| `make testbed-litellm-secret-scan`  | Check manifests for plaintext LiteLLM `api_key` values     |

## Mistral Key Provisioning

Create a free account in Mistral La Plateforme, create an API key, and store it in the Platform Mesh backing secret store. The committed manifest only contains an `ExternalSecret`; the raw key must never be committed to Git.

Expected external secret location:

```text
OpenBao KV v2 path: secret/testbed/litellm/mistral
property:          api_key
```

The OpenBao seed job reads `LITELLM_MISTRAL_API_KEY` from `.env.testbed` and writes it to `secret/testbed/litellm/mistral` as `api_key`. The `ExternalSecret` creates a Kubernetes Secret named `litellm-mistral-api-key` with the environment variable `MISTRAL_API_KEY`. The LiteLLM Helm chart imports that Secret via `environmentSecrets`, and the LiteLLM `config.yaml` references it as `os.environ/MISTRAL_API_KEY`.

Run this check before opening a pull request:

```bash
make testbed-litellm-secret-scan
```

Verify that the key reached Kubernetes:

```bash
kubectl get secret litellm-mistral-api-key -n naira-testbed-litellm
kubectl get externalsecret litellm-mistral-api-key -n naira-testbed-litellm
```

## Seeded Routes

| Alias             | Upstream model                 | Type             | Provider |
| ----------------- | ------------------------------ | ---------------- | -------- |
| `chat-small`      | `mistral/mistral-small-latest` | Chat completions | Mistral  |
| `chat-large`      | `mistral/mistral-large-latest` | Chat completions | Mistral  |
| `chat-codestral`  | `mistral/codestral-latest`     | Chat completions | Mistral  |
| `text-embeddings` | `mistral/mistral-embed`        | Embeddings       | Mistral  |

List routes:

```bash
curl http://localhost:4000/v1/models
```

Minimal chat completion:

```bash
curl -sS http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"chat-small","messages":[{"role":"user","content":"ping"}]}'
```

Minimal embeddings request:

```bash
curl -sS http://localhost:4000/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"text-embeddings","input":"test"}'
```

## In-Cluster Access

Other pods can reach LiteLLM at:

```text
http://litellm.naira-testbed-litellm.svc.cluster.local:4000
```

No Ingress is configured. Use `make testbed-litellm-port-forward` for local access.

## Smoke Test

`make testbed-litellm-smoke` creates a short-lived Kubernetes Job that:

- waits for LiteLLM readiness
- checks that `/v1/models` includes `chat-small`
- sends one short `chat-small` chat completion request
- sends one short `text-embeddings` embeddings request

The smoke test intentionally sends minimal prompts to stay within Mistral free-tier limits.

## Free-Tier and Egress Notes

This testbed calls the live Mistral API at:

```text
https://api.mistral.ai/v1
```

Any namespace-level egress policy must allow outbound HTTPS traffic to `api.mistral.ai`. Mistral's free tier has request-per-minute and monthly token limits that can change over time; check the current La Plateforme limits before running repeated CI jobs or manual loops. This testbed is intended for smoke tests and plugin development, not load testing.

## Flux Reconciliation

Apply `flux-kustomization.yaml` through the Make target:

```bash
FLUX_SOURCE=component-testbed make testbed-litellm-up
```

The Flux Kustomization watches `./infrastructure/testbed/litellm` every minute. Updating the route list in `helm-release.yaml` and pushing the change causes Flux to reconcile the Helm release; the updated routes then appear in:

```bash
curl http://localhost:4000/v1/models
```

Check reconciliation state:

```bash
make testbed-litellm-status
kubectl get kustomization naira-testbed-litellm -n flux-system
```

## Complete Removal

```bash
make testbed-litellm-down
kubectl get all -n naira-testbed-litellm
```

After namespace deletion completes, Kubernetes should report that the namespace does not exist.

## Manifest Layout

```text
infrastructure/testbed/litellm/
├── README.md
├── kustomization.yaml        # Namespace + OCIRepository + ExternalSecret + HelmRelease
├── flux-kustomization.yaml   # Flux Kustomization CR pointing to litellm/
├── namespace.yaml
├── oci-repository.yaml       # OCI source for docker.litellm.ai/berriai/litellm-helm
├── external-secret.yaml      # Mistral key projection from openbao-platform
├── helm-release.yaml         # LiteLLM chart values and seeded routes
└── smoke-test-job.yaml       # On-demand smoke test run by make
```
