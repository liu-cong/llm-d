# D3: PD wide-EP + improved router config

Same serving stack as D2 (`../run-20260730-glm-fp8-vllm-pd-ep16/manifests/`,
prefill+decode wide-EP LWS). Only the EPP plugins config changes:
`manifests/pd-epp-improved-configmap.template.yaml` → rendered to
`manifests/pd-epp-improved-configmap.yaml` once placeholders are measured.

## Placeholder calibration (on the D2 deployment)

- `__PEAK_PREFILL_TPUT__` — peak prefill throughput per prefill endpoint
  (DP rank). Measured by sending cache-miss long prompts at low concurrency
  through the gateway and computing `prompt_tokens / TTFT` median (from the
  D2 smoke/sweep `per_request_lifecycle_metrics.json`, first-request-in-session
  entries only, low-concurrency stage). Reference point from instruction:
  aggregated GLM-5.2-NVFP4 TP8 B200 measured 24027 under
  max_prefill_tokens=16384.
- `__LRU_BLOCKS__` — per prefill rank: GPU KV cache size in tokens (vllm
  startup log "GPU KV cache size: N tokens") × (1 + cpu_offload_tokens /
  gpu_tokens), ÷ blockSizeTokens (64). cpu_offload_tokens = 300GiB /
  bytes-per-token (derivable from the same log: KV cache GiB / tokens).
- `__CTX_WINDOW__` — 300000 (served max-model-len; prefixes longer than the
  serving window can't recur).
- Utilization caps: prefill turns over fast → `waiting-queue maxValue 0`,
  `running-requests maxValue 4` (a rank prefills ~1 long request at a time
  under max_num_batched_tokens 8192 / long-prefill-threshold 2048; 4 allows
  short-request pipelining). Decode holds long streams → `waiting-queue 0`,
  `active-requests 56` (~90% of the 64 max-num-seqs per rank).

## Risk noted upfront

`utilization-filter` was validated on llm-d-router main (PRs #2209/#2218);
the deployed EPP image is v0.9.0. If the plugin type is unknown at EPP start,
switch the pd-epp deployment image to a newer llm-d-router-endpoint-picker tag
for D3 (record the exact tag here).

## Calibrated values (measured on the final D2 deployment, 2026-07-31)

- peakPrefillThroughput = 7400 tok/s per prefill DP rank (139,712-token fresh
  prompt prefilled in 18.9 s, warm, direct to a prefill pod)
- Prefill per-rank KV: 475,021 GPU tokens (21.42 GiB, 48.4 KB/token) +
  300 GiB CPU offload (~6.65M tokens) → lruCapacityPerServer = 111000 blocks (÷64)
- maxPrefixTokensToMatch = 300000 (served max-model-len)
- prefill-utilization-filter: waiting-queue 0, running-requests 4
- decode-utilization-filter: waiting-queue 0, active-requests 56 (~90% of 64
  max-num-seqs/rank)
- D2 topology note: prefill = EP8 × 3 groups, decode = EP16 × 1 (see the D2 run
  folder for the topology decision trail; DeepEP/IBGDA unavailable on this cluster).

## D3 deployment record (2026-07-31 ~17:35 PT)

- v0.9.0 EPP rejected the config: `plugin type 'utilization-filter' is not registered`
  (as anticipated). Switched the pd-epp `epp` container image to
  `ghcr.io/llm-d/llm-d-router-endpoint-picker:main` (config is based on llm-d-router
  main + PRs #2209/#2218). envoy sidecar unchanged. Live state snapshot:
  `manifests/pd-epp-deployment-live-main-image.yaml`.
- Serving stack untouched from D2 (same LWS pods, same engines).
