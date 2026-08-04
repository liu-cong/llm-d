# GLM-5.2-FP8 weka trace replay — cross-deployment comparison

Environments:

| Env | Stack | GPUs | Status |
|---|---|---|---|
| **D1** | vLLM v0.26.0 aggregated: TP8 ×5, fp8 KV, MTP-5, SimpleCPUOffload 2.8TiB/node, llm-d optimized-baseline router | 40 | ✅ 2026-07-31 |
| **D2** | vLLM PD + wide-EP: EP8/DEP16 (40 GPU) and **full DEP16 groups (112–128 GPU)** | 40 / 112 / 128 | ✅ complete |
| **D3** | D2 stack + improved EPP config (recalibrated per shape) | 40 / 112 / 128 | ✅ complete |

## Exact configurations

Common to every environment: model `zai-org/GLM-5.2-FP8` (756 GB checkpoint,
MLA-attention MoE), served as `glm-5.2-fp8`; engine `docker.io/vllm/vllm-openai:v0.26.0`;
`--kv-cache-dtype fp8` (D1: `fp8_e4m3`); MTP speculative decoding
`{"method":"mtp","num_speculative_tokens":5}`;
`--tool-call-parser glm47 --reasoning-parser glm45 --enable-auto-tool-choice`;
`--max-model-len 300000`. Nodes are a4-highgpu-8g (8× B200-180GB, 224 vCPU, ~3.8 TiB
RAM, ~11 TB local SSD); HF/JIT caches on hostPath
`/mnt/stateful_partition/kube-ephemeral-ssd/shared_disk/`.

Benchmark client (all runs): forked inference-perf (weka-datagen-parallel + bounded
teardown), running in-cluster; workload `weka_trace_replay` over
`semianalysisai/cc-traces-weka-with-subagents-060826-256k` (391 native sessions,
`default_block_size 64`; when sessions > 391 the corpus is duplicated with random
session-id injection); streaming chat, `ignore_eos`; finals = one 20-min stage
(`timeout 1200`), `num_sessions = 3×` concurrency.

| Config item | **D1 (us-west8)** | **D2/D3 @40 GPU (us-west8)** | **D2/D3 @112/128 GPU (a4-pr)** |
|---|---|---|---|
| Cluster | GKE `us-west8` (`conliu-gke-dev`), 5× a4-highgpu-8g spot | same, RDMA multi-networking pool | GKE `a4-pr` (europe-west4), RDMA pool `a4-highgpu-8g-a4-pool-1`, 14–16 nodes |
| Nodes / GPUs | 5 / **40** | 5 / **40** | 5P2D: 14 / **112** · 6P2D: 16 / **128** |
| Topology | **TP8 × 5 replicas** (1 per node, no EP) | prefill **EP8 × 3** single-node groups (TP1·DP8·EP8) + decode **DEP16 × 1** 2-node group | prefill **DEP16 × 5 or 6** + decode **DEP16 × 2**, every group a 2-node LWS (`size: 2`, TP1·DP16·EP16, `DP_SIZE_LOCAL 8`) |
| GPU mem util | 0.90 | prefill 0.85 / decode 0.90 | prefill 0.85 / decode 0.90 |
| Batching | vLLM defaults | prefill `max-num-batched-tokens 8192`, `long-prefill-token-threshold 2048`; decode `max-num-seqs 64` + `max-num-batched-tokens 512` per rank | same |
| EP all2all | n/a | `allgather_reducescatter` (NCCL over 8× RoCE NICs; DeepEP blocked: NVSHMEM IBGDA won't init on GKE default drivers; flashinfer NVLink backend lacks fp8_e4m3) | same |
| KV offload | `SimpleCPUOffloadConnector`, **350 GiB/rank × 8 = 2.8 TiB/node** | `MultiConnector` = NIXL (UCX/RoCE) + SimpleCPUOffload **300 GiB/rank = 2.4 TiB/node** | same |
| GPU KV per rank | 1,323,186 tok/replica | prefill 475k · decode 1.89M tok | prefill/decode **1,196,224 tok** |
| Router (D2 / baseline) | llm-d **optimized-baseline** EPP v0.9.0 + envoy (queue-, kv-cache-utilization-, prefix-cache-scorer) | wide-ep-lws PD config on EPP v0.9.0 (always-disagg, prefill/decode filters, gpu+cpu prefix scorers), disagg sidecar v0.9.0 on decode | same |
| Router (D3) | n/a | EPP `:main`; peak **7,400** tok/s/rank, LRU **111,000** blocks, ctx 300k, prefill wait 0 / running 4, decode wait 0 / active 56 | EPP `:main` + `--allow-experimental-plugins`; recalibrated peak **4,741** tok/s/rank, LRU **122,000** blocks, same caps (variant with prefill running cap 8: regression, rejected) |
| Raw manifests | `run-20260730-glm-fp8-vllm-baseline/manifests/` | `run-20260730-glm-fp8-vllm-pd-ep16*/manifests/` | `run-20260803-glm-fp8-vllm-pd-a4pr-16n/manifests/` |

## Finals (20-min windows, sessions = 3× concurrency)

| Env · conc (nodes · GPUs) | in tok/s | in/GPU | out tok/s | TTFT p50/p95/p99 (s) | TPOT p50 (ms) | req e2e p50/p90/p99 (s) |
|---|---:|---:|---:|---|---|---|
| D1 · c35 (5n · 40, TP8×5) | **132,872** | **3,322** | 1,291 | 2.68 / 12.6 / 28.5 | 3.8 | 4.1 / 19.2 / 58.0 |
| D1 · c58 (5n · 40, TP8×5) | 129,751 | 3,244 | 1,448 | 2.64 / 14.3 / 27.5 | 3.5 | 4.1 / 21.2 / 72.1 |
| D2 · c35 (5n · 40, 3×EP8 P + 1×DEP16 D) | 51,214 | 1,280 | 530 | 6.47 / 28.8 / 41.7 | 11.2 | 7.5 / 37.8 / 105.5 |
| D2 · c58 (5n · 40, 3×EP8 P + 1×DEP16 D) | 55,170 | 1,379 | 671 | 7.44 / 32.7 / 52.3 | 9.3 | 8.8 / 34.2 / 96.5 |
| D3 · c35 (5n · 40, same stack as D2) | 53,527 | 1,338 | 647 | 7.11 / 29.2 / 57.9 | 10.3 | 10.2 / 37.5 / 153.6 |
| D3 · c58 (5n · 40, same stack as D2) | **58,632** | 1,466 | 580 | **5.74 / 23.6 / 41.0** | 10.4 | 8.7 / 31.6 / 103.6 |
| D2 · c115 (14n · 112, 5P2D DEP16) | 156,726 | 1,399 | 1,759 | 7.11 / 28.1 / 49.9 | 11.6 | 10.3 / 41.0 / 115.0 |
| D2 · c160 (16n · 128, 6P2D DEP16) | 185,061 | 1,446 | 1,859 | 7.32 / 31.6 / 62.1 | 11.6 | 10.1 / 43.2 / 114.7 |
| D3 · c115 (16n · 128, 6P2D DEP16) | **198,381** | **1,550** | 2,055 | 7.06 / 32.4 / 52.9 | 11.0 | 10.8 / 40.5 / 123.9 |

Note: **D1 has only been benchmarked at 40 GPUs** — cross-scale comparisons of D1 vs the
112/128-GPU PD rows rely on per-GPU normalization. All rows above are warm-router runs
with 0 request failures.

## Conclusions

1. **D1 aggregated TP8 + optimized router dominates this ~98%-input workload**: ~2.3× the
   best PD variant's input throughput at equal GPUs, ~2.5× lower TTFT p50, ~3× lower TPOT.
   TP8 gives every request 8 GPUs of prefill compute; the DP/EP designs prefill each
   request on one rank.
2. **D3's router config beats D2 on the same stack**, biggest near saturation
   (40-GPU c58: +6.3% input throughput, −22…28% TTFT across percentiles; at 128 GPU it
   reaches a higher warm peak at lower concurrency: 198.4k@c115 vs 185.1k@c160).
3. **6P2D ≥ 5P2D at c115+**: +18–27% total throughput for +14% GPUs (slightly
   super-linear per GPU at the right operating point); below ~c100 the extra prefill
   capacity idles.
4. Caveats: EPP restarts cold the in-memory prefix index (first run after any config
   swap loses up to −40% — only warm runs are comparable); c160 runs show high
   replay-to-replay variance; decode was never the bottleneck (TPOT ≤ 12 ms p50
   everywhere, MTP-5 at 3.5 ms on TP8).
