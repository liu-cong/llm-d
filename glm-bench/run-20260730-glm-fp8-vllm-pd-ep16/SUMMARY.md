# D2: vLLM PD-disaggregated + wide EP — GLM-5.2-FP8 (40× B200, RDMA)

## Run metadata
- Date: 2026-07-31 (RDMA runs 13:24 → 17:30 PT)
- Cluster: GKE `us-west8`, nodepool `a4-rdma-spot` (5× a4-highgpu-8g spot, GKE
  multi-networking, Network CRs rdma-0..7 → 8× 400G RoCE NICs per pod)
- Topology: **prefill EP8 × 3 single-node LWS groups + decode EP16 × 1 two-node LWS
  group = 40 GPUs** (mirrors llm-d PR #2122's `3p2d-dep8-dep16` pattern).
  Manifests: `manifests/01-prefill-lws.yaml`, `02-decode-lws.yaml`, router
  `03-pd-router.yaml` (EPP v0.9.0 + envoy, wide-ep-lws PD plugins config,
  gateway `pd-epp.glm-bench.svc:80`)
- Engines: vLLM v0.26.0, DP8(×3)/DP16 TP1, expert parallel,
  `--all2all-backend allgather_reducescatter` (NCCL over RoCE), fp8 KV, MTP-5,
  MultiConnector = NixlConnector (UCX/RoCE) + SimpleCPUOffload 300 GiB/rank,
  decode max-num-seqs 64 / max-num-batched-tokens 512 per rank (documented deviation
  from PR's 32/32, which starves MTP-5).
  Per-rank GPU KV: prefill 475k tokens, decode 1.89M tokens.
- Backend decision trail: `flashinfer_nvlink_one_sided` → no fp8_e4m3 support;
  DeepEP (HT/LL) → NVSHMEM IBGDA cannot init on these nodes (GKE driver regkeys) and
  internode DeepEP effectively requires it; EP16 *prefill* with NCCL-allgather →
  deadlocked in cross-node DP16 init + crashed on first traffic; decode EP16 stable.
- Calibration (for D3): peak prefill ≈ 7,400 tok/s per DP rank (139,712-token fresh
  prompt in 18.9 s warm, direct); repeat prompt 0.3 s (prefix cache hit).

## Results (finals = 20-min windows, native corpus, sessions = 3× concurrency)

| Run | conc | reqs ok/fail | in tok/s | in/GPU | out tok/s | TTFT p50/p95/p99 (s) | TPOT p50/p95/p99 (ms) | req e2e p50/p90/p99 (s) | sessions done / e2e p50 (s) |
|-----|-----:|----|---------:|-------:|----------:|---------------------|----------------------|------------------------|------|
| final-c35 | 35 | 955/0 | 51,214 | 1,280 | 530 | 6.47 / 28.75 / 41.70 | 11.2 / 20.4 / 24.0 | 7.5 / 37.8 / 105.5 | 5 / 1000 |
| final-c58 | 58 | 1176/0 | 55,170 | 1,379 | 671 | 7.44 / 32.70 / 52.28 | 9.3 / 21.6 / 25.0 | 8.8 / 34.2 / 96.5 | 11 / 648 |

Sweep (`results/sweep`): flat ~39–52k in-tok/s c16→c64 (saturated immediately);
saturation taken as c64 (max measured point), finals at c35/c58 (matching D1 levels).

## Errors
- 0 request failures in every kept run.
- > ❗ **DISCARDED (user instruction): all pre-RDMA results** — EP16-over-TCP smoke
  (TTFT p50 50.6 s) in `results/DISCARDED-no-rdma-smoke-c2/`, manifests in
  `manifests/no-rdma-attempts-DISCARDED/`.
- final-c58: one transient ≤60 s readiness flap at stage start (coincident with a
  local DNS outage that killed the laptop-side monitor); 0 pod restarts, 0 request
  failures → kept, caveat noted.

## Reproducibility
- Serving pods ran 0-restart through all kept runs (verified by monitors + pod ages).
