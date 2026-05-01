# Offloading Prefix Cache to Shared Storage

## Overview

This guide explains how to offload the vLLM prefix cache (KV cache) to shared storage using the native llm-d FS connector or the LMCache connector. This allows prefix cache reuse across multiple vLLM instances and across nodes that mount the same shared path.

## Default Configuration

| Parameter                 | Value                                                   |
| ------------------------- | ------------------------------------------------------- |
| Model                     | [meta-llama/Llama-3.3-70B-Instruct](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct) |
| GPUs per replica (TP)     | 4                                                       |
| GPU Accelerator           | NVIDIA H100                                             |

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
    export GUIDE_NAME="llm-d-pfc-storage"
    export NAMESPACE=llm-d-storage
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
kubectl apply -f guides/tiered-prefix-cache/storage/manifests/pvc.yaml -n ${NAMESPACE}
```

### 2. Deploy the llm-d Router

#### Standalone Mode

This deploys the inference scheduler with an Envoy sidecar side-by-side:

```bash
helm install ${GUIDE_NAME} \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
    -f guides/recipes/scheduler/base.values.yaml \
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

#### llm-d FS Connector (Default)

```bash
kubectl apply -n ${NAMESPACE} -k guides/tiered-prefix-cache/storage/modelserver/gpu/vllm/llm-d-fs-connector
```

<details>
<summary><h4>LMCache Connector</h4></summary>

```bash
kubectl apply -n ${NAMESPACE} -k guides/tiered-prefix-cache/storage/modelserver/gpu/vllm/lmcache-connector
```

</details>

---

### 4. Enable monitoring (optional)

- Install the [Monitoring stack](../../../docs/monitoring/README.md).
- Deploy the monitoring resources for this guide:

```bash
kubectl apply -n ${NAMESPACE} -k guides/recipes/modelserver/components/monitoring
```

---

## Verification

### 1. Get the IP of the Proxy

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

### 2. Send Test Requests

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --env="IP=$IP" \
    --env="NAMESPACE=$NAMESPACE" \
    -- /bin/bash
```

**Send a completion request:**

```bash
<<<<<<< HEAD
NAME            HOSTNAMES   AGE
llm-d-infpool               17m
```

### Check the PVC

```bash
kubectl get pvc -n ${NAMESPACE}
```

Output should show the PVC as `Bound`:

```
NAME         STATUS   VOLUME                  CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
<pvc-name>   Bound    pvc-3c793698-XXXXXXX    18000Gi    RWX            <storage-class>   <unset>              6d
```

### Check the InferencePool

```bash
kubectl get inferencepool -n ${NAMESPACE}
```

```bash
NAME            AGE
llm-d-infpool   16m
```

### Check the Pods

```bash
kubectl get pods -n ${NAMESPACE}
```

You should see the InferencePool's endpoint pod and the model server pods in a `Running` state.

```bash
NAME                                READY   STATUS    RESTARTS   AGE
llm-d-infpool-epp-xxxxxxxx-xxxxx    1/1     Running   0          16m
llm-d-decode-xxxxxxxx-xxxxx         1/1     Running   0          11m
llm-d-decode-xxxxxxxx-xxxxx         1/1     Running   0          11m
```

### Test inference through the Gateway

The Gateway is a `ClusterIP` Service, so port-forward to call it from outside the cluster:

```bash
kubectl port-forward -n ${NAMESPACE} svc/llm-d-inference-gateway-istio 8000:80 &
curl -s http://localhost:8000/v1/models
curl -s http://localhost:8000/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-32B","prompt":"The capital of France is","max_tokens":15,"temperature":0}'
```

A successful response looks like:

```json
{"id":"cmpl-...","object":"text_completion","model":"Qwen/Qwen3-32B","choices":[{"index":0,"text":" Paris. ...","finish_reason":"length"}],"usage":{"prompt_tokens":5,"completion_tokens":15,"total_tokens":20}}
```

### Verify KV cache is offloaded to storage

<!-- TABS:START -->

<!-- TAB:llm-d FS Connector -->
#### llm-d FS Connector

Send a long prompt (one that crosses several `block_size` boundaries) to trigger offload, then inspect the PVC:

```bash
# Long prompt (~3K tokens)
PROMPT=$(printf 'Story: '; for i in $(seq 1 800); do printf 'alice met bob and they walked together. '; done)
curl -s http://localhost:8000/v1/completions \
  -H 'Content-Type: application/json' \
  -d "$(printf '{"model":"Qwen/Qwen3-32B","prompt":%s,"max_tokens":3,"temperature":0}' \
        "$(printf '%s' "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')")"

# Check the shared PVC for written blocks
POD=$(kubectl get pod -n ${NAMESPACE} -l llm-d.ai/role=decode -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${NAMESPACE} ${POD} -- du -sh /mnt/files-storage/kv-cache
kubectl exec -n ${NAMESPACE} ${POD} -- find /mnt/files-storage/kv-cache -maxdepth 5 -type d
```

Expected output: `du -sh` shows hundreds of MB to several GB, and `find` lists a path like
`/mnt/files-storage/kv-cache/<model>/<block-config>/<tp-config>/...`.

You can also confirm via vLLM's offload metrics (exposed at `/metrics` on each pod):

```bash
kubectl exec -n ${NAMESPACE} ${POD} -- curl -s http://localhost:8000/metrics | grep '^vllm:kv_offload_total_bytes'
```

A successful offload increments `vllm:kv_offload_total_bytes{transfer_type="GPU_to_SHARED_STORAGE"}`.

<!-- TAB:LMCache Connector -->
#### LMCache Connector

```bash
export IP=localhost
export PORT=8000
export POD_NAME=llm-d-decode-xxxx-xxxx
kubectl exec -it $POD_NAME -- curl -i http://${IP}:${PORT}/metrics | grep lmcache:local_storage_usage
```

Verify the folder size where the shared storage is mounted:

```bash
kubectl exec -it $POD_NAME -n ${NAMESPACE} -- du -sh /mnt/files-storage
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
kubectl delete -n ${NAMESPACE} -k guides/tiered-prefix-cache/storage/modelserver/gpu/vllm/llm-d-fs-connector
# or delete the lmcache-connector
# kubectl delete -n ${NAMESPACE} -k guides/tiered-prefix-cache/storage/modelserver/gpu/vllm/lmcache-connector
kubectl delete namespace ${NAMESPACE}
```
