# D1: vLLM aggregated baseline — GLM-5.2-FP8 (40× B200)

## Run metadata
- Date: 2026-07-30 22:38 → 2026-07-31 03:29 PT
- Cluster: GKE `us-west8` (us-west8-c), project `conliu-gke-dev`; 5× a4-highgpu-8g
  spot nodes (accelerator-pool-b200-spot; pool later replaced by `a4-rdma-spot` —
  reruns land there, results equivalent for this single-node-TP8 config)
- Serving: vLLM v0.26.0, `zai-org/GLM-5.2-FP8` (756 GB), TP8 per node × 5 replicas,
  `--kv-cache-dtype fp8_e4m3`, MTP-5, SimpleCPUOffloadConnector 350 GiB/rank
  (2.8 TiB/node), max-model-len 300k, glm47/glm45 parsers.
  Manifest: `manifests/vllm-baseline-fp8.yaml`
- Router: llm-d optimized-baseline (EPP v0.9.0 + envoy; helm release snapshot in
  `manifests/live-nvfp4-reference/`), gateway `optimized-baseline-epp.glm-bench.svc:80`
- Engine: GPU KV 1,323,186 tokens/replica (59.66 GiB/GPU free after weights)
- Bench: forked inference-perf in-cluster (`bench-client-pool`), weka trace replay
  `semianalysisai/cc-traces-weka-with-subagents-060826-256k` (391 sessions)

## Results (finals = 20-min windows, native corpus, sessions = 3× concurrency)

| Run | conc | reqs ok/fail | in tok/s | in/GPU | out tok/s | TTFT p50/p95/p99 (s) | TPOT p50/p95/p99 (ms) | req e2e p50/p90/p99 (s) | sessions done / e2e p50 (s) |
|-----|-----:|----|---------:|-------:|----------:|---------------------|----------------------|------------------------|------|
| final-c35 | 35 | 1609/0 | 132,872 | 3,322 | 1,291 | 2.68 / 12.64 / 28.54 | 3.8 / 8.6 / 14.7 | 4.1 / 19.2 / 58.0 | 12 / 617 |
| final-c58 | 58 | 1587/0 | 129,751 | 3,244 | 1,448 | 2.64 / 14.27 / 27.50 | 3.5 / 8.2 / 12.2 | 4.1 / 21.2 / 72.1 | 8 / 588 |

Sweeps (`results/sweep-low`, `results/sweep`): input throughput flat at ~125–145k tok/s
from c16 through c256 → prefill-bound almost immediately; TTFT knee at ~c64 → saturation
taken as c64, finals at c35 (~55%) and c58 (~90%).

## Errors
- None: 0 request failures in every run.
- > ❗ final-c58 first attempt DISCARDED: spot node preempted 16 min into the window
  (02:30 PT). Node replaced, 5/5 replicas verified ready, run repeated cleanly.

## Reproducibility
- Both finals ran with 5/5 replicas ready, 0 restarts, verified by 60 s pod monitors.
- Local gcloud reauth blip at 03:24 PT affected only laptop-side log streaming for the
  c58 rerun; results were collected from the in-cluster pod afterwards.
