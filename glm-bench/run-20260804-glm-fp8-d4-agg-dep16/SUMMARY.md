# D4: vLLM AGGREGATE wide-EP (no PD) — GLM-5.2-FP8, DEP16 × 2 (32 GPUs)

## Run metadata
- Date: 2026-08-04 evening PT (deploy 19:30 → finals done ~22:45)
- Cluster: `us-west8` (conliu-gke-dev, us-west8-c), pool `a4-rdma-spot`
  (5× a4-highgpu-8g spot, RDMA rdma-0..7). **4 of 5 nodes used** (user instruction).
- Topology: **aggregate DEP16 × 2 instances** (each a 2-node LWS, `size: 2`,
  TP1·DP16·EP16, `DP_SIZE_LOCAL 8`) = 4 nodes / **32 GPUs**; one pool serves both
  prefill and decode (no P/D split, no routing-proxy, no NIXL).
  Manifest: `manifests/01-agg-lws.yaml`
- D4-specific engine config (per instruction.md "D4"):
  - KV offload connector alone: `SimpleCPUOffloadConnector`, 300 GiB/rank
    (no MultiConnector/NIXL); prefix caching ON
  - chunked prefill: `--max-num-batched-tokens 4096` +
    `--long-prefill-token-threshold 2048` (kept after sweep: TPOT p95 21–30 ms,
    not blown up)
  - **MTP-3** (instruction; D2 used MTP-5), verified compatible with chunked
    prefill via smoke
  - `--gpu-memory-utilization 0.90` → GPU KV **1,632,529 tokens/rank**
  - `allgather_reducescatter` all2all (DeepEP/IBGDA unavailable on GKE drivers)
- Router: pd-epp ConfigMap swapped to a **single default profile**
  (queue-scorer + kv-cache-utilization-scorer + prefix-cache-scorer, vLLM data
  layer, no port override) — `manifests/02-d4-epp-configmap.yaml`; EPP image
  `:main` (carried over). InferencePool `wide-ep` unchanged (targetPorts
  8000–8007 → DP-aware rank endpoints).
- **DP-endpoint verification passed** (instruction requirement): EPP tracks all
  4 pods; 3 same-prefix gateway probes stuck to a single rank endpoint
  (agg-0/DP5: 12.1 s cold, then 0.19 s / 0.21 s prefix-cache hits).

## Results (finals = 20-min windows, native corpus, sessions = 3× concurrency)

| Run | conc | ok/fail | in tok/s | in/GPU | out tok/s | TTFT p50/p95/p99 (s) | TPOT p50/p95/p99 (ms) | req e2e p50/p90/p99 (s) | sessions / e2e p50 s |
|---|---:|---|---:|---:|---:|---|---|---|---|
| final-c35 | 35 | 869/0 | 38,708 | 1,210 | 547 | 6.58 / 36.73 / 76.70 | 11.3 / 31.6 / 47.5 | 9.5 / 48.2 / 141.1 | — |
| final-c58 | 58 | 860/0 | 41,861 | 1,308 | 530 | 8.02 / 42.13 / 60.55 | 12.5 / 35.9 / 48.1 | 13.7 / 54.6 / 145.3 | 9 / 843 |

Sweep (7-min stages, dup corpus): flat 22–34k in-tok/s from c16 through c96
(saturated immediately); TTFT p95 27–42 s across all stages.

## D2 vs D4 (the headline comparison, both us-west8, per-GPU)

| Metric @c58 | D2 (PD, 40 GPU) | D4 (agg, 32 GPU) | Δ |
|---|---|---|---|
| in tok/s per GPU | 1,379 | 1,308 | D4 −5% |
| TTFT p50 | 7.44 s | 8.02 s | ≈ par |
| TTFT p95 / p99 | 32.7 / 52.3 s | 42.1 / 60.6 s | **D4 +29% / +16% worse** |
| TPOT p50 | 9.3 ms | 12.5 ms | D4 worse |
| TPOT p95 / p99 | 21.6 / 25.0 ms | 35.9 / 48.1 ms | **D4 +66% / +92% worse** |

**Read:** no crossover in D4's favor was found anywhere in c16–c96. Throughput
per GPU is par-to-slightly-worse, medians are par, but D4's TTFT and
especially ITL/TPOT **tails are consistently much worse** — the predicted
DP-lockstep prefill interference (a prefill chunk on any rank stalls decode on
all 16 ranks) shows up at every tested concurrency, not just high ones. On this
workload, PD's KV-transfer tax is cheaper than aggregate wide-EP's
prefill/decode interference. (And both remain ~2.4–2.7× below D1 aggregated
TP8's 3,244–3,322 tok/s/GPU.)

Caveats: D4 ran MTP-3 (instruction) vs D2's MTP-5 — contributes to the TPOT p50
gap but not plausibly to 2× tail differences; D4 = 32 GPUs vs D2 = 40 (per-GPU
normalization used); chunk budget fixed at 4096 (not knob-swept).

## Errors / reproducibility
- 0 request failures in every run; 0 serving-pod restarts (monitors clean).
- First smoke attempt: bench pod unschedulable (bench-client CPU held by a
  leftover `debug-epp` deployment) — scaled it to 0, relaunched.

---

# D4-v2 (2026-08-05): "D1 + wide EP" — KV-capacity hypothesis test

User hypothesis: the workload is KV-cache-capacity bound; wide EP frees KV space
(smaller expert footprint), output lengths are short so PD's gain doesn't cover
its overhead → tolerate prefill/decode interference, make D4 exactly "D1 with
wide EP as the only difference".

## Changes vs v1 (everything aligned to D1)
- Engine: MTP 3→**5**, offload 300→**350 GiB/rank**, chunked-prefill overrides
  **dropped** (vLLM defaults, like D1), `fp8_e4m3`. Only remaining difference
  from D1: TP8 → TP1·DP16·EP16 (2-node DEP16 groups × 2 = 32 GPUs).
- Router: **D1's ACTIVE optimized-baseline config** — prefix-cache-affinity-filter
  + token-load-scorer (approx-prefix-cache + inflight-load producers, EPP-side
  only). Correction recorded: D1's active file was `optimized-baseline-plugins.yaml`
  (token-load-aware), not the default queue/kv-util profile earlier docs cited.
  `peakPrefillThroughput` recalibrated 16800 (TP8 server) → **4741** (DEP16 rank).
- Affinity re-verified: same-prefix probes sticky to one rank; cold 4.16 s /
  cached 0.25 s for a 15.4k-token prompt.

## KV capacity (the measured heart of the hypothesis)
- D1 TP8: 1,323,186 KV tokens **per 8-GPU replica** (~165k/GPU) — MLA latent KV
  cannot be TP-sharded, so TP8 replicates every token's KV 8×.
- D4 DEP16: 1,632,529 KV tokens **per GPU** (13.1M per 8 GPUs) → **~10× D1 per GPU**,
  from DP eliminating MLA replication + EP16 halving expert weights (94→47 GB/GPU).

## v2 results (20-min finals, 0 failures, 0 pod restarts)

| Run | conc | ok/fail | in tok/s | in/GPU | TTFT p50/p95/p99 (s) | TPOT p50/p95/p99 (ms) | req e2e p50/p90/p99 (s) |
|---|---:|---|---:|---:|---|---|---|
| v2-final-c35 | 35 | 924/0 | 46,287 | 1,446 | 8.59 / 41.64 / 81.68 | 14.8 / 40.0 / 49.3 | 14.4 / 58.2 / 167.5 |
| v2-final-c58 | 58 | 856/0 | 44,085 | 1,378 | 8.91 / 26.40 / 35.56 | 16.3 / 33.5 / 48.5 | 11.2 / 48.4 / 134.1 |
| v2-final-c160 | 160 | 980/0 | 54,565 | **1,705** | 9.04 / 40.19 / 56.58 | 13.8 / 33.4 / 48.8 | 12.0 / 57.6 / 145.0 |

Sweep (7-min stages): c32 887 / c64 795 / **c128 1,306** / c192 1,018 per GPU.

## Read
1. **v2 > v1 across the board**: +20% throughput at c35 (1,446 vs 1,210/GPU); at
   c58 the D1-style router fixed v1's tail problem (TTFT p95/p99 26.4/35.6 s vs
   42.1/60.6) at par throughput.
2. **KV-capacity signal is real**: v2 is the only variant whose per-GPU throughput
   RISES with concurrency (1,446@c35 → 1,705@c160 — best wide-EP/PD number in the
   project, beats D3-6P2D's 1,550 and all D2 shapes). At c128 it clears D1's dip
   stage (1,306–1,705 vs D1's 1,631 sweep point).
3. **But no clean crossover vs D1**: D1's c192/c256 sweep stages sit at 2,886–3,045
   per GPU — still ~1.8× above v2's best. Per-request prefill compute (TP8 = 8
   GPUs/request vs DP = 1) plus D1's own 2.8 TiB/node offload buffer keep D1 ahead
   at every operating point tested. The hypothesis would need concurrency high
   enough to defeat D1's offload too (>c256, untested) — or a workload with less
   prefix reuse.
4. Costs of v2 vs v1: TTFT/TPOT p50 slightly worse (MTP-5 draft tokens ride every
   lockstep decode step; no chunked-prefill cap), traded for throughput + tails.

## Incidents
- Two local DNS outages killed laptop-side launchers mid-chain (c35 at 10:04,
  c160 at 10:59); both pods completed in-cluster, results collected manually via
  chunked kubectl cp. Serving pods: 0 restarts across the entire v2 window.

---

# DeepEP probe on llm-d CUDA images (2026-08-05, user suggestion)

Question: prior DeepEP failures were with the NVSHMEM bundled in
vllm-openai:v0.26.0 — do the llm-d CUDA images (RoCE fixes) unblock DeepEP?
Probe: 1× DEP16 group (2 nodes), `deepep_high_throughput`, IBGDA env per the
llm-d GKE overlay. Manifest: `manifests/03-deepep-probe-lws.yaml`.

| Image | NVSHMEM/IBGDA transport | Serving GLM-5.2-FP8 |
|---|---|---|
| `vllm/vllm-openai:v0.26.0` (all campaign runs) | ❌ `init failed for transport: IBGDA` → transport map failed (GKE driver regkeys); IBRC insufficient for DeepEP internode | ✅ (with allgather) |
| `ghcr.io/llm-d/llm-d-cuda:v0.8.1` | ✅ **IBGDA/DeepEP init SUCCEEDED, engine READY** — the RoCE fixes are real | ❌ dies on first forward: GLM-5.2 sparse-attn indexer needs `fp8_fp4_mqa_logits` → `RuntimeError: DeepGEMM backend is not available or outdated` |
| `ghcr.io/llm-d/llm-d-cuda-dev:main` | (not reached) | ❌ instant argparse failure: build lacks `--data-parallel-multi-port-external-lb`, `--data-parallel-supervisor-port`, `--all2all-backend`, `--disable-access-log-for-endpoints` (different vLLM lineage / launch scheme) |

**Conclusion:** DeepEP-on-RoCE is unblocked by llm-d's NVSHMEM build, but no
currently published image combines all three requirements for GLM-5.2-FP8
wide-EP on GKE: (a) llm-d's NVSHMEM/DeepEP RoCE build, (b) DeepGEMM new enough
for `fp8_fp4_mqa_logits` (GLM-5.2 sparse indexer), (c) the DP-supervisor
launch patches our manifests use. Paths: rebuild llm-d-cuda v0.8.x with
updated deep_gemm; or pip-install/build newer DeepGEMM into v0.8.1 at pod
start (untested; JIT build risk); or wait for the flags/deep_gemm to converge
on dev:main. Expected payoff once solved: replace allgather (EP-fold activation
broadcast per MoE layer) with sparse GPU-initiated all2all — the biggest known
lever on wide-EP prefill throughput here.
