# Pd Disaggregation — Kustomize v2 Guide

This guide installs the `pd-disaggregation` well-lit path using a hybrid Helm + Kustomize architecture.

## Prerequisites

- [Client tools installed](../../prereq/client-setup/README.md)
- [Gateway provider deployed](../../prereq/gateway-provider/README.md)
- Kubernetes namespace created:

  ```bash
  export NAMESPACE=llm-d-pd
  kubectl create namespace ${NAMESPACE}
  ```

## Installation

### 1. Deploy the Gateway and HTTPRoute

Choose your provider and apply the gateway recipe:

```bash
# For Istio
kubectl apply -k ../../recipes/gateway/istio -n ${NAMESPACE}

# For kgateway
kubectl apply -k ../../recipes/gateway/kgateway -n ${NAMESPACE}
```

### 2. Deploy the InferencePool (EPP Scheduler)

Use Helm to install the InferencePool with the provided values file:

```bash
helm install llm-d-infpool -n ${NAMESPACE} \
  -f ./manifests/inferencepool.values.yaml \
  --set "provider.name=gke" \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.3.1
```

Change `--set "provider.name=istio"` for Istio, or omit for kgateway.

### 3. Deploy the Model Server (vLLM)

```bash
# Default (GPU / Nvidia)
kubectl apply -k manifests/vllm/base -n ${NAMESPACE}
```

Hardware variants are available as overlays:

```bash
kubectl apply -k manifests/vllm/<variant> -n ${NAMESPACE}
```

## Cleanup

```bash
kubectl delete -k manifests/vllm/base -n ${NAMESPACE}
helm uninstall llm-d-infpool -n ${NAMESPACE}
kubectl delete -k ../../recipes/gateway/istio -n ${NAMESPACE}
```
