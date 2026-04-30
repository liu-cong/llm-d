# Offloading Prefix Cache to Shared Storage

## Overview

This guide explains how to offload the vLLM prefix cache (KV cache) to shared storage using the native llm-d FS connector or the LMCache connector. This allows prefix cache reuse across multiple vLLM instances and across nodes that mount the same shared path.

## Default Configuration

| Parameter          | Value                                                   |
| ------------------ | ------------------------------------------------------- |
| Model              | [meta-llama/Llama-3.3-70B-Instruct](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct) |
| Data Parallelism   | 4                                                       |
| Total GPUs         | 16                                                      |

### Supported Connectors

| Connector             | Overlay Directory                             | Notes                                      |
| --------------------- | -------------------------------------------- | ------------------------------------------ |
| llm-d FS Connector    | `manifests/vllm/llm-d-fs-connector/`          | vLLM native file system offload             |
| LMCache Connector     | `manifests/vllm/lmcache-connector/`          | Integrated LMCache shared storage backend   |

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
- [Create the `llm-d-hf-token` secret in your target namespace with the key `HF_TOKEN` matching a valid HuggingFace token](../../../helpers/hf-token.md) to pull models.

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

### 2. Deploy the Inference Scheduler

#### Standalone Mode

This deploys the inference scheduler with an Envoy sidecar, it doesn't set up a Kubernetes Gateway.

```bash
helm install ${GUIDE_NAME} \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
    -f guides/recipes/scheduler/base.values.yaml \
    -n ${NAMESPACE} --version ${GAIE_VERSION}
```

<details>
<summary><h4>Gateway Mode (Deprecated)</h4></summary>

```bash
export PROVIDER_NAME=gke # options: none, gke, agentgateway, istio
helm install llm-d-infpool \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool  \
    -f guides/recipes/scheduler/base.values.yaml \
    --set provider.name=${PROVIDER_NAME} \
    -n ${NAMESPACE} --version ${GAIE_VERSION}
```

</details>

### 3. Deploy the Model Server

Apply the connector overlay of your choice:

<!-- TABS:START -->

<!-- TAB:llm-d FS Connector:default -->
#### llm-d FS Connector

```bash
kubectl apply -k guides/tiered-prefix-cache/storage/manifests/vllm/llm-d-fs-connector -n ${NAMESPACE}
```

<!-- TAB:LMCache Connector -->
#### LMCache Connector

```bash
kubectl apply -k guides/tiered-prefix-cache/storage/manifests/vllm/lmcache-connector -n ${NAMESPACE}
```

<!-- TABS:END -->

### 4. Enable monitoring (optional)

- Install the [Monitoring stack](../../../docs/monitoring/README.md).
- Deploy the monitoring resources for this guide.

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

### 2. Send Test Requests

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

You can verify if the KV cache is being offloaded to local storage by checking the metric `lmcache:local_storage_usage` through the following command.

```bash
export IP=localhost
export PORT=8000
export POD_NAME=llm-d-decode-xxxx-xxxx
kubectl exec -it $POD_NAME -- curl -i http://${IP}:${PORT}/metrics | grep lmcache:local_storage_usage
```

Verify the folder size where the shared storage is mounted. It should be in GBs after KV cache offloading completes, though the actual size will differ based on the requests served.

```bash
kubectl exec -it $POD_NAME -n ${NAMESPACE} -- du -sh /mnt/files-storage
```

<!-- TABS:END -->

## Benchmarking

The following benchmark results demonstrate the performance improvements of offloading the KV cache to Lustre using the LMCache connector. Two scenarios with varying context lengths are provided to illustrate how the performance gains from Lustre scale up as the computational load and KV cache size increase, particularly when exceeding the capacity of local HBM and CPU RAM.

### LMCache connector

#### Benchmark Setup

* **Hardware:**
  * A total of 16 H100 GPUs, each with 80GB of HBM, were used.
  * The GPUs were distributed across 4 `a3-highgpu-4g` instances, with 4 GPUs per instance.
  * Lustre PVC with storage capacity of 18000GiB

* **vLLM Configuration:**
  * `gpu_memory_utilization` was set to `0.65` to reduce the pressure on the benchmark tool. In production configuration this is typically set to a higher value such as 0.9.
  * Baseline has CPU offloading enabled.
  * Lustre offloading was enabled using Lustre PVC as local backend disk.

* **LMCache Configuration:**
  * For LMCache setup, `LMCACHE_MAX_LOCAL_CPU_SIZE` set to `20GB`, which provides approximately 20*16(number of GPUs)=320GB of CPU RAM cache.
  * Lustre storage capacity available for KV cache offloading was set through `LMCACHE_MAX_LOCAL_DISK_SIZE:"1120Gi"`. As we have 16 GPUs sharing the Lustre disk, 1120*16= 17920Gi <= 18000Gi (i.e. available Lustre capacity) This value can be less than or equal to the available disk size.

The benchmark was conducted using the [inference-perf](https://github.com/kubernetes-sigs/inference-perf) tool with the following hardware, memory, and workload configurations:

* **Workload:**
  * The two different workloads were tested with a constant concurrency of 20 requests with different system_prompt_lengths of 50K and 70K.
  * **Inference Perf configuration**
    * `type`: concurrent
    * `num_requests`: 2700
    * `concurrency_level`: 20
  * **System prompt length: 50K**
    * `num_groups`: 50
    * `system_prompt_len`: 50000
    * `question_len`: 256
    * `output_len`: 1024
    * `num_prompts_per_group`: 50
  * **System prompt length: 70K**
    * `num_groups`: 50
    * `system_prompt_len`: 70000
    * `question_len`: 256
    * `output_len`: 1024
    * `num_prompts_per_group`: 50

* **Memory Calculation:**
  * The KVCache size for the `meta-llama/Llama-3.3-70B-Instruct` model is approximately 320KB per token.
  * With `gpu_memory_utilization` at 0.65, there are 10768 GPU blocks available per engine.
  * The available HBM for KVCache per engine is approximately 55 GB (10768 blocks * 5.12 MB/block).
  * The total available HBM for the KVCache across the entire system was 220 GB (4 engines * 55 GB/engine).
  * Total CPU RAM cache available across the system was 320 GB.
  * Lustre capacity available for KV cache offloading: `LMCACHE_MAX_LOCAL_DISK_SIZE="1120Gi"` for each GPU.

#### Key Findings

In both scenarios, the total KV cache size significantly exceeds the combined capacity of local HBM and CPU RAM. The results demonstrate that as context length and memory demands increase, the performance benefits of offloading to Lustre become even more pronounced.

* **50K system prompt length (KVCache size 994 GiB):** While CPU RAM provides 320GB for KV cache offloading, adding Lustre significantly enhances performance compared to relying on CPU offloading alone.
* **70K system prompt length (KVCache size 1.3 TiB):** As the KV cache footprint grows to 1.3 TiB, the memory pressure intensifies. In this heavier scenario, Lustre delivers even greater performance gains, demonstrating its ability to seamlessly scale with demanding long-context use cases.


#### 50K system prompt length (KVCache size 994 GiB) — KV Cache > (HBM + CPU RAM)

| KVCache > HBM + CPU RAM | Mean TTFT (second) | P90 TTFT (second) | Mean E2E Latency (second) | P90 E2E Latency (second) | Input Throughput (token per second) | Output Throughput (token per second) | Overall Throughput (token per second) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Baseline vLLM + CPU offloading** | 25.38 | 37.74 | 56.21 | 69.69 | 18607 | 354 | 18962 |
| **vLLM + CPU offloading + Lustre** | 20.12 (-21%) | 34.02 (-9.9%) | 45.83 (-18%) | 58.73 (-16%) | 22827 (+23%) | 435 (+23%) | 23262 (+23%) |

#### 70K system prompt length (KVCache size 1.3TiB GiB) — KV Cache >> (HBM + CPU RAM)

| KVCache >> HBM + CPU RAM | Mean TTFT (second) | P90 TTFT (second) | Mean E2E Latency (second) | P90 E2E Latency (second) | Input Throughput (token per second) | Output Throughput (token per second) | Overall Throughput (token per second) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Baseline vLLM + CPU offloading** | 58.02 | 74.75 | 87.99 | 105.46 | 16598 | 226.65 | 16825 |
| **vLLM + CPU offloading + Lustre** | 45 (-22%) | 64.79 (-13%) | 68.28 (-22%) | 87.47 (-17%) | 21364 (+28.71%) | 291 (+28.39%) | 21656 (+28.71%) |

---

## Cleanup

To remove the deployed components:

```bash
helm uninstall ${GUIDE_NAME} -n ${NAMESPACE}
kubectl delete -f guides/tiered-prefix-cache/storage/manifests/pvc.yaml -n ${NAMESPACE}
kubectl delete -n ${NAMESPACE} -k guides/tiered-prefix-cache/storage/manifests/vllm/<llm-d-fs-connector|lmcache-connector>
kubectl delete namespace ${NAMESPACE}
```

---

## Appendix: Performance Benchmarks

Detailed offloading performance results for Lustre and parallel file systems are reported in the original guide. Offloading heavily populated system prompts (50k+ tokens) yields upwards of **25%+** throughput improvements.
