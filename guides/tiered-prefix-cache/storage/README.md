# Offloading Prefix Cache to Shared Storage

## Overview

This guide explains how to offload the vLLM prefix cache (KV cache) to shared storage using the native llm-d FS connector or the LMCache connector. This allows prefix cache reuse across multiple vLLM instances and across nodes that mount the same shared path.

## Default Configuration

| Parameter                 | Value                                                   |
| ------------------------- | ------------------------------------------------------- |
| Model                     | [Qwen/Qwen3-32B](https://huggingface.co/Qwen/Qwen3-32B) |
| GPUs per replica (TP)     | 4                                                       |
| GPU Accelerator           | NVIDIA H100                                             |
| CPU Cache Offload Size    | 100 GB                                                  |

### Supported Connectors

| Connector             | Directory                                                              |
| --------------------- | ---------------------------------------------------------------------- |
| llm-d FS Connector    | `modelserver/gpu/vllm/llm-d-fs-connector/`                              |
| LMCache Connector     | `modelserver/gpu/vllm/lmcache-connector/`                              |

---

## Prerequisites

- Have the [proper client tools installed on your local system](../../../helpers/client-setup/README.md) to use this guide.
- Checkout llm-d repo:

  ```bash
    export branch="main" # branch, tag, or commit hash
    git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout ${branch}
  ```

- Set the following environment variables:
  ```bash
    export GAIE_VERSION=v1.4.0
    export GUIDE_NAME="tiered-prefix-cache-storage"
    export NAMESPACE=llm-d-${GUIDE_NAME}
  ```
- Install the Gateway API Inference Extension CRDs:

  ```bash
    kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GAIE_VERSION}"
  ```

- Create a target namespace for the installation:
  ```bash
    kubectl create namespace ${NAMESPACE}
  ```

---

## Installation Instructions

### 1. Prepare a PVC (ReadWriteMany)

Set your storage class depending on your environment:

```bash
export STORAGE_CLASS=default # options: default, lustre, efs-sc
```

Create a PVC using the selected storage class:

```bash
envsubst < guides/tiered-prefix-cache/storage/manifests/pvc.yaml | kubectl apply -n ${NAMESPACE} -f -
```

### 2. Deploy the llm-d Router

#### Standalone Mode

This deploys the inference scheduler with an Envoy sidecar side-by-side:

```bash
helm install ${GUIDE_NAME} \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
    -f guides/recipes/scheduler/base.values.yaml \
    -f guides/tiered-prefix-cache/storage/scheduler/${GUIDE_NAME}.values.yaml \
    -n ${NAMESPACE} --version ${GAIE_VERSION}
```

<details>
<summary><h4>Gateway Mode</h4></summary>

To use a Kubernetes Gateway managed proxy instead of standalone:

1. _Deploy a Kubernetes Gateway_ by following one of [the gateway guides](../../prereq/gateways).
2. _Deploy HTTPRoute and the inference scheduler_:

```bash
export PROVIDER_NAME=gke # options: none, gke, agentgateway, istio
helm install llm-d-infpool \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool  \
    -f guides/recipes/scheduler/base.values.yaml \
    --set provider.name=${PROVIDER_NAME} \
    --set experimentalHttpRoute.enabled=true \
    --set experimentalHttpRoute.inferenceGatewayName=llm-d-inference-gateway \
    -n ${NAMESPACE} --version ${GAIE_VERSION}
```

</details>

---

### 3. Deploy the Model Server

Apply the Kustomize overlay corresponding to your desired connector backend. 

<details>
<summary><h4>Click here for GCP Lustre</h4></summary>
For GCP lustre, please apply `llm-d-fs-connector-lustre` or `llm-d-fs-connector-lustre` which contains a patch to allow vLLM to write to Lustre.
</details>

```bash
export CONNECTOR=llm-d-fs-connector # llm-d-fs-connector | lmcache-connector | llm-d-fs-connector-lustre | lmcache-connector-lustre
kubectl apply -n ${NAMESPACE} -k guides/tiered-prefix-cache/storage/modelserver/gpu/vllm/${CONNECTOR}
```

---

### 4. (Optional) Enable monitoring

- Install the [Monitoring stack](../../../docs/monitoring/README.md).
- Deploy the monitoring resources for this guide:

```bash
kubectl apply -n ${NAMESPACE} -k guides/recipes/modelserver/components/monitoring
```

---

## Verification

### 1. Check the PVC

```bash
kubectl get pvc -n ${NAMESPACE}
```

Output should show the PVC as `Bound`:

```
NAME         STATUS   VOLUME                  CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
<pvc-name>   Bound    pvc-3c793698-XXXXXXX    18000Gi    RWX            <storage-class>   <unset>              6d
```

### 2. Get the IP of the Proxy

**Standalone Mode**

```bash
export IP=$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
```

<details>
<summary> <b>Gateway Mode</b> </summary>

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')
```

</details>

### 3. Send Test Requests

**Open a temporary interactive shell inside the cluster:**

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --env="IP=$IP" \
    --env="NAMESPACE=$NAMESPACE" \
    -- /bin/bash
```

**Send a completion request:**

```bash
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{
        "model": "Qwen/Qwen3-32B",
        "prompt": "How are you today?"
    }' | jq
```
### 4. Verify KV cache is offloaded to storage 

**Send a long prompt (one that crosses several `block_size` boundaries) to trigger offload**

```bash
# Run this inside the interactive shell created in step 3.
# Long prompt (~3K tokens)
PROMPT=$(printf 'Story: '; for i in $(seq 1 800); do printf 'alice met bob and they walked together. '; done)
jq -n --arg prompt "$PROMPT" '{"model":"Qwen/Qwen3-32B", "prompt":$prompt, "max_tokens":3, "temperature":0}' | \
curl -s http://${IP}/v1/completions \
  -H 'Content-Type: application/json' \
  -d @- | jq
```

```bash
# Check the shared PVC for written blocks
POD=$(kubectl get pod -n ${NAMESPACE} -l llm-d.ai/role=decode -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${NAMESPACE} ${POD} -- du -sh /mnt/files-storage/kv-cache
kubectl exec -n ${NAMESPACE} ${POD} -- find /mnt/files-storage/kv-cache -maxdepth 5 -type d
```

Expected output: `du -sh` shows hundreds of MB to several GB, and `find` lists a path like
`/mnt/files-storage/kv-cache/<model>/<block-config>/<tp-config>/...`.

You can also confirm via vLLM's offload metrics (exposed at `/metrics` on each pod):

```bash
export METRIC_NAME="vllm:kv_offload_total_bytes" # vllm:kv_offload_total_bytes for fs connector OR lmcache:local_storage_usage for lmcache connector
kubectl exec -n ${NAMESPACE} ${POD} -- curl -s http://localhost:8000/metrics | grep '^$METRIC_NAME'
```

---

## Benchmarking

Refer to the [standard benchmark instructions](../../../helpers/benchmark.md) for launching synthetic profile tests. Detailed offloaded benchmarks have demonstrated up to **+25%** throughput improvements for heavily preloaded system prompts (50k+ tokens).

---

## Cleanup

To clean and remove applied deployments:

```bash
helm uninstall ${GUIDE_NAME} -n ${NAMESPACE}
kubectl delete -f guides/tiered-prefix-cache/storage/manifests/pvc.yaml -n ${NAMESPACE}
kubectl delete -n ${NAMESPACE} -k guides/tiered-prefix-cache/storage/modelserver/gpu/vllm/${CONNECTOR}
kubectl delete namespace ${NAMESPACE}
```
