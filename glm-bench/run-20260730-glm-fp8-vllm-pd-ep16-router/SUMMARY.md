# D3: vLLM PD + wide EP + improved router config — GLM-5.2-FP8 (40× B200, RDMA)

## Run metadata
- Date: 2026-07-31 17:35 → ~19:55 PT
- Serving stack: **identical to D2, untouched** (prefill EP8 × 3 + decode EP16 × 1
  = 40 GPUs; see `../run-20260730-glm-fp8-vllm-pd-ep16/SUMMARY.md`)
- Change vs D2: EPP plugins config only — instruction.md's recommended P/D config
  with measured calibration (`manifests/pd-epp-improved-configmap.yaml`):
  - approx-prefix-cache-producer: blockSizeTokens 64, lruCapacityPerServer 111,000
    blocks/rank (GPU 475k + CPU-offload ~6.65M tokens), maxPrefixTokensToMatch 300,000
  - prefill-utilization-filter: waiting-queue ≤0, running-requests ≤4 (fail-open)
  - decode-utilization-filter: waiting-queue ≤0, active-requests ≤56 (fail-open)
  - prefix-cache-affinity-filter: peakPrefillThroughput 7,400 tok/s (measured)
  - token-load-scorer (prefill profile), active-request-scorer (decode profile)
- EPP image: `ghcr.io/llm-d/llm-d-router-endpoint-picker:main` (v0.9.0 lacks
  `utilization-filter`; config's stated basis is llm-d-router main + PRs #2209/#2218).
  Live snapshot: `manifests/pd-epp-deployment-live-main-image.yaml`

## Results (finals = 20-min windows, native corpus, sessions = 3× concurrency)

| Run | conc | reqs ok/fail | in tok/s | in/GPU | out tok/s | TTFT p50/p95/p99 (s) | TPOT p50/p95/p99 (ms) | req e2e p50/p90/p99 (s) | sessions done / e2e p50 (s) |
|-----|-----:|----|---------:|-------:|----------:|---------------------|----------------------|------------------------|------|
| final-c35 | 35 | 958/0 | 53,527 | 1,338 | 647 | 7.11 / 29.24 / 57.91 | 10.3 / 20.7 / 31.3 | 10.2 / 37.5 / 153.6 | 6 / 512 |
| final-c58 | 58 | 1140/0 | 58,632 | 1,466 | 580 | 5.74 / 23.64 / 41.03 | 10.4 / 18.8 / 22.8 | 8.7 / 31.6 / 103.6 | 12 / 624 |

vs D2 at the same concurrency:
- c35: +4.5% input throughput; latency ~par (slightly worse p99 tail this run).
- c58: **+6.3% input throughput, TTFT p50 −23% (5.74 vs 7.44 s), p95 −28%, p99 −22%** —
  the utilization filters + measured prefix-affinity threshold help most near
  saturation, exactly where the config is designed to matter.

Sweep (`results/sweep`): same envelope as D2 (peak ~52k at c64), 0 failures.

## Errors
- None: 0 request failures in every run; 0 serving-pod restarts (monitors clean).
- First EPP start on v0.9.0 failed with `plugin type 'utilization-filter' is not
  registered` — resolved by the image switch above (pre-flagged risk in README.md).

## Reproducibility
- Runs completed without interruption; serving engines carried over from D2 with no
  restarts, so engine-side state (weights, compiled graphs) is identical between
  D2 and D3 — the only variable is the EPP config/image.
