# GLM-5.2-FP8 agentic trace-replay benchmarks (weka traces)

Benchmarks of three GLM-5.2-FP8 serving architectures on GKE B200 (a4-highgpu-8g)
nodes, driven by real agentic coding traces:

- **D1** — vLLM aggregated baseline: TP8 per node × N replicas + llm-d
  optimized-baseline router.
- **D2** — vLLM P/D-disaggregated + wide expert parallelism (llm-d `wide-ep-lws`
  guide): DEP16 LeaderWorkerSet groups + llm-d PD router.
- **D3** — same serving stack as D2, improved EPP (router) config with utilization
  filters and measured prefix-affinity calibration.
- **D4** — aggregate wide-EP (no PD): DEP16 groups serving prefill+decode in one pool.
  v2 = "D1 + wide EP" (D1-aligned engine + D1's token-load router) — the KV-capacity
  experiment: MLA KV can't be TP-sharded, so DEP16 yields ~10× KV tokens/GPU vs TP8.
  Folder: `run-20260804-glm-fp8-d4-agg-dep16/` (manifests 01/02 are the v2 state).

Headline results and exact configurations: **[COMPARISON.md](COMPARISON.md)**.
Per-campaign details, raw manifests, bench configs, and result metrics live in the
`run-*/` folders (each has its own `SUMMARY.md`).

## Upstream references this work is based on

| Reference | Role here |
|---|---|
| [llm-d/llm-d **PR #2122**](https://github.com/llm-d/llm-d/pull/2122) (`guides/wide-ep-lws`, GLM branch, commit `91e4d74`) | Reference recipe for the D2/D3 serving stack (wide-EP LeaderWorkerSets, disagg sidecar, PD router values). **This branch is based on that PR's branch state**, so `guides/wide-ep-lws/` in this tree matches what the manifests were derived from. Deviations (fp8 model, all2all backend, decode batching, offload) are documented in each manifest header and COMPARISON.md. |
| [llm-d/llm-d `guides/optimized-baseline`](https://github.com/llm-d/llm-d/tree/main/guides/optimized-baseline) | D1's router (EPP v0.9.0 + envoy, queue/kv-utilization/prefix-cache scorers); exact deployed snapshot in `run-20260730-glm-fp8-vllm-baseline/manifests/live-nvfp4-reference/`. |
| llm-d-router **PRs #2209 / #2218** (llm-d-router `main`) | Basis of the D3 improved EPP config — the `utilization-filter` plugin validated in those PRs; requires the `:main` EPP image + `--allow-experimental-plugins` (plugin absent in v0.9.0). |
| [llm-d-router **PR #2243**](https://github.com/llm-d/llm-d-router/pull/2243) | Why the D3 prefill utilization filter uses server-reported `running-requests` instead of EPP-tracked `active-requests`: until that fix lands, the EPP releases a prefill profile's request count only at end of stream. Switch the condition to `active-requests` once it ships. |
| [yangligt2/inference-perf `weka-datagen-parallel`](https://github.com/yangligt2/inference-perf/tree/weka-datagen-parallel) | Benchmark tool fork (parallel weka trace datagen + bounded stage teardown + server-side prompt-token accounting). |
| [vLLM GLM-5.2 recipe](https://recipes.vllm.ai/zai-org/GLM-5.2) (`kv_offload=simple`) | D1 engine flags (TP8, fp8 KV, MTP-5, SimpleCPUOffloadConnector). |

---

# Reproducing the numbers

## 0. Prerequisites

Cluster:
- GKE Standard cluster with an **a4-highgpu-8g** (8× B200) node pool.
  - D1 @40 GPU: 5 nodes. D2/D3 @128 GPU: 16 nodes (+ scheduling headroom if shared).
  - For D2/D3 the pool **must have GKE multi-networking / RDMA**: Network CRs
    `rdma-0..7` present and pods able to attach the 8 RoCE NICs
    (`kubectl get networks.networking.gke.io` should list them). Without RDMA,
    cross-node EP is unusable (measured: TTFT p50 50 s at concurrency 2).
- A CPU node pool for the bench client (≥16 vCPU / 64 GB per bench pod), nodes
  labeled `role=bench-client`.
- [LeaderWorkerSet](https://github.com/kubernetes-sigs/lws) controller installed
  (`lws-system`).
- HF token secret in the serving namespace (checkpoint downloads):
  `kubectl -n glm-bench create secret generic llm-d-hf-token --from-literal=HF_TOKEN=<token>`

Bench tool: forked **inference-perf** (`yangligt2/inference-perf@weka-datagen-parallel`
with bounded stage teardown). Image used by these runs:
`us-central1-docker.pkg.dev/supercomputer-testing/inference-perf/inference-perf:weka-fast-bounded-teardown-server-prompt-tokens-20260717`
(set `IMAGE=` env for `run_bench.sh` if you host a copy elsewhere).

Workload: HF dataset `semianalysisai/cc-traces-weka-with-subagents-060826-256k`
(391 agentic sessions, up to 256k ctx, ~98% input tokens; downloaded by the bench pod).

Model: `zai-org/GLM-5.2-FP8` (756 GB). Every serving pod downloads it once per node to
hostPath `/mnt/stateful_partition/kube-ephemeral-ssd/shared_disk/vllm-hf-cache/`
(~30–40 min on a fresh node; survives pod restarts).

## 1. D1 — aggregated baseline (40 GPUs)

```bash
kubectl create ns glm-bench   # if absent
# Router: llm-d optimized-baseline (EPP v0.9.0 + envoy). Either install via the
# llm-d optimized-baseline guide/helm chart, or apply the exact snapshot used here:
kubectl apply -f run-20260730-glm-fp8-vllm-baseline/manifests/live-nvfp4-reference/  # SA/RBAC, envoy CM, EPP deploy+svc, InferencePool
# Serving: TP8 × 5 replicas (Recreate strategy; 1 pod = 1 node)
kubectl apply -f run-20260730-glm-fp8-vllm-baseline/manifests/vllm-baseline-fp8.yaml
kubectl -n glm-bench rollout status deploy/vllm-baseline   # ready ≈ download + ~10 min
```

Gateway URL (used in all D1 bench configs):
`http://optimized-baseline-epp.glm-bench.svc.cluster.local:80`.

Benchmark sequence (each command blocks; results land in `results/<name>/`):

```bash
cd run-20260730-glm-fp8-vllm-baseline
./scripts/run_bench.sh smoke-c2  configs/config-smoke-c2.yaml    # sanity: expect 0 failures
./scripts/run_bench.sh sweep-low configs/config-sweep-low.yaml   # c16/32/48 × 7 min
./scripts/run_bench.sh sweep     configs/config-sweep.yaml       # c64/128/192/256 × 7 min
# Saturation on this trace is early (input tok/s flat from ~c16; TTFT knee ≈ c64).
./scripts/run_bench.sh final-c35 configs/config-final-c35.yaml   # ~55% of saturation, 20 min
./scripts/run_bench.sh final-c58 configs/config-final-c58.yaml   # ~90%, 20 min
```

Expected (40 GPUs): **in ≈ 130–133k tok/s (3.2–3.3k/GPU), TTFT p50 ≈ 2.6–2.7 s,
TPOT p50 ≈ 3.5–3.8 ms, 0 failures.**

## 2. D2 — PD + wide EP

Two validated shapes (pick per your node budget). All manifests set the model,
MTP-5, glm parsers, `allgather_reducescatter` all2all, and MultiConnector
(NIXL + SimpleCPUOffload 300 GiB/rank):

**(a) 40 GPU (5 nodes): prefill EP8 × 3 + decode DEP16 × 1** — `run-20260730-glm-fp8-vllm-pd-ep16/manifests/`
**(b) 112–128 GPU (14–16 nodes): prefill DEP16 × 5–6 + decode DEP16 × 2** — `run-20260803-glm-fp8-vllm-pd-a4pr-16n/manifests/`

```bash
cd run-20260803-glm-fp8-vllm-pd-a4pr-16n            # (or the 40-GPU folder)
kubectl apply -f manifests/00-common.yaml            # SA
kubectl apply -f manifests/05-epp-rbac.yaml          # EPP SA/RBAC (a4-pr folder)
kubectl apply -f manifests/04-envoy-configmap.yaml   # envoy config (a4-pr folder)
kubectl apply -f manifests/03-pd-router.yaml         # PD EPP (D2 config) + svc + InferencePool
kubectl apply -f manifests/01-prefill-lws.yaml       # bring-up: replicas:1 (1P1D sanity)
kubectl apply -f manifests/02-decode-lws.yaml
# after 1P1D smoke passes, scale to the full shape:
kubectl -n glm-bench patch lws wide-ep-llm-d-prefill --type merge -p '{"spec":{"replicas":6}}'
kubectl -n glm-bench patch lws wide-ep-llm-d-decode  --type merge -p '{"spec":{"replicas":2}}'
```

Gateway URL: `http://pd-epp.glm-bench.svc.cluster.local:80`.

```bash
./scripts/run_bench.sh smoke-c2 configs/config-smoke-c2.yaml
./scripts/run_bench.sh sweep    configs/config-sweep-a4pr.yaml       # c64–c384 (16-node shape)
./scripts/run_bench.sh d2-6p2d-final-c70  configs/config-final-c70.yaml
./scripts/run_bench.sh d2-6p2d-final-c115 configs/config-final-c115.yaml
./scripts/run_bench.sh d2-6p2d-final-c160 configs/config-final-c160.yaml
```

Expected (6P2D, 128 GPUs, warm router): **in ≈ 185k tok/s @ c160 (≈1.45k/GPU),
TTFT p50 ≈ 7.3 s, TPOT p50 ≈ 11.6 ms, 0 failures.**
(40-GPU shape: ≈ 51–55k @ c35/c58.)

## 3. D3 — improved router config (serving stack untouched)

1. **Calibrate** (once per shape) — see
   `run-20260730-glm-fp8-vllm-pd-ep16-router/README.md` for the full procedure:
   - `peakPrefillThroughput` = prompt_tokens / TTFT of one large cache-miss request
     sent directly to a prefill pod (measured: 7,400 tok/s/rank at EP8;
     4,741 at DEP16).
   - `lruCapacityPerServer` = (GPU KV tokens/rank from the vLLM startup log
     `GPU KV cache size` + CPU-offload tokens) ÷ 64.
   - Utilization caps: prefill `waiting-queue 0` / `running-requests 4`
     (**do not raise to 8** — measured regression), decode `waiting-queue 0` /
     `active-requests 56`.
2. **Apply** — the EPP image must support `utilization-filter`
   (`ghcr.io/llm-d/llm-d-router-endpoint-picker:main` + `--allow-experimental-plugins`;
   v0.9.0 lacks the plugin):

```bash
kubectl apply -f manifests/pd-epp-improved-configmap-a4pr.yaml     # calibrated CM
kubectl -n glm-bench set image deploy/pd-epp epp=ghcr.io/llm-d/llm-d-router-endpoint-picker:main
kubectl -n glm-bench rollout restart deploy/pd-epp
```

3. **Warm the router before measuring** (critical): the EPP prefix index is
   in-memory — every rollout starts cold and the first run after a swap reads up to
   −40% low. Run one throwaway 20-min run (e.g. `d3-warmup-c160`), discard it, then
   run the measured finals at the same levels as D2:

```bash
./scripts/run_bench.sh d3-6p2d-final-c115 configs/config-final-c115.yaml
./scripts/run_bench.sh d3-6p2d-final-c160 configs/config-final-c160.yaml
```

Expected (6P2D, 128 GPUs, warm): **in ≈ 198k tok/s @ c115 (≈1.55k/GPU)** — higher
peak at lower concurrency than D2, TTFT p50 ≤ D2's at matched points.

## 4. D4 — aggregate wide-EP (no PD), "D1 + wide EP"

```bash
cd run-20260804-glm-fp8-d4-agg-dep16
kubectl apply -f manifests/02-d4-epp-configmap.yaml   # D1's token-load/prefix-affinity router (peak 4741/rank)
kubectl -n glm-bench rollout restart deploy pd-epp
kubectl apply -f manifests/01-agg-lws.yaml            # aggregate DEP16 x2 (v2 state: MTP-5, 350GiB/rank offload, default batching)
# verify per instruction: EPP sees 8 endpoints/pod; same-prefix probes stick to one rank
./scripts/run_bench.sh smoke-c2 configs/config-smoke-c2.yaml
./scripts/run_bench.sh sweep    configs/config-sweep-v2.yaml   # c32/64/128/192
./scripts/run_bench.sh final-c35  configs/config-final-c35.yaml
./scripts/run_bench.sh final-c58  configs/config-final-c58.yaml
./scripts/run_bench.sh final-c160 configs/config-final-c160.yaml
```

Expected (32 GPUs, warm): c35 ≈ 46k in-tok/s (1,446/GPU), c160 ≈ **54.6k (1,705/GPU —
best wide-EP number)**; TTFT p50 ~9 s. Key mechanism: MLA KV cannot be TP-sharded, so
DEP16 holds ~10× the KV tokens per GPU vs TP8 (1.63M/GPU vs 165k/GPU) — but D1 still
leads ~1.8× on throughput in the tested range (8-GPU-per-request prefill).

## 5. Analysis

Each run's report directory contains `stage_*_lifecycle_metrics.json` (throughput +
TTFT/TPOT/e2e percentiles) and `summary_session_lifecycle_metrics.json` (session
completions + session e2e). The tables in `COMPARISON.md` and each run's `SUMMARY.md`
are generated from exactly these files (see `analyze_results.py` for the extraction).

## Known pitfalls (all hit during these campaigns)

| Pitfall | Symptom | Mitigation |
|---|---|---|
| EPP prefix index is in-memory | first run after any EPP rollout up to −40% | warm-up run after every config swap; compare warm-vs-warm only |
| NVSHMEM IBGDA won't init on GKE default drivers | DeepEP backends crash-loop (`init failed for transport: IBGDA`) | use `allgather_reducescatter` (NCCL over RoCE) |
| `flashinfer_nvlink_one_sided` | `NotImplementedError` for fp8_e4m3 | same — it's an NVFP4/mxfp8/bf16 backend |
| No RDMA networks on the pool | cross-node EP catastrophically slow (TTFT p50 50 s @ c2) | multi-networking pool with `rdma-0..7` Network CRs is mandatory for DEP16 |
| GPU-saturated cluster + Deployment rolling update | new pods unschedulable, rollout deadlock | `strategy: Recreate` (D1 manifest already sets it) |
| PR's decode `max-num-seqs/batched = 32/32` | starves MTP-5 (each seq needs 6 token slots/step) | 64 seqs / 512 tokens per rank (already in manifests) |
| >~1900-session duplicated sweep corpora | inference-perf workers die ("did not survive the stage") | keep finals ≤500-session corpora; treat sweep stages as directional |
| Session cursor overrun | datagen error | total `num_sessions` across stages ≤ `duplicate_sessions_target` |
| Spot preemption / node loss mid-run | partial replica set during window | monitor serving pods during runs; discard and rerun any disrupted window |
| Bench pod Pending | CPU contention with EPP pods on client nodes | keep bench pod CPU request ≤12 or separate the pools |
