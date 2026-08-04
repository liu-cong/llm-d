# D2/D3 at scale on a4-pr — weka trace replay (GLM-5.2-FP8, vLLM PD + wide-EP DEP16)

**Status: COMPLETE** (2026-08-04). Serving stack left running (6P2D, canonical D3 EPP config).
Cluster: `a4-pr` (supercomputer-testing, europe-west4), pool-1 RDMA nodes.
Stack: vLLM v0.26.0, PD-disaggregated, prefill/decode = 2-node **DEP16** LWS groups
(TP1·DP16·EP16), NIXL over RoCE, SimpleCPUOffload 300 GiB/rank, MTP-5,
`allgather_reducescatter`, max-model-len 300k. Bench: forked inference-perf, in-cluster,
20-min finals, sessions = 3× concurrency. Manifests in `manifests/`, raw results in `results/`.

## Topology validation
- **Cross-node DEP16 prefill works on a4-pr** (deadlocked on us-west8) — full 2-node
  groups for both roles, GPU KV/rank 1,196,224 tokens (~2× the EP8 shape).
- Shapes: **5P2D** = 14 nodes/112 GPUs; **6P2D** = 16 nodes/128 GPUs (2 nodes were
  blocked for hours by a broken pool-3 holding reservation slots; user cleared it).

## ⚠ Methodology note (affects which numbers to trust)
`pd-epp` keeps its prefix index **in memory**: every config swap/rollout wipes it, and
the **first run after a swap is a cold-router artifact** (up to −40%). Only "warm" runs
(second-or-later after a swap) are comparable. The table marks cold runs.

## Finals (20-min windows; per-GPU = total ÷ shape GPUs)

| Run | conc | ok/fail | in tok/s | in/GPU | out tok/s | TTFT p50/p95/p99 (s) | TPOT p50 | req e2e p50/p90/p99 (s) |
|---|---:|---|---:|---:|---:|---|---|---|
| D2 5P2D | c70 | 2317/0 | 136,987 | 1,223 | 1,567 | 7.19/31.2/54.7 | 12.2ms | 10.5/46.1/126.5 |
| D2 5P2D | c115 | 2819/0 | 156,726 | 1,399 | 1,759 | 7.11/28.1/49.9 | 11.6ms | 10.3/41.0/115.0 |
| D3 5P2D | c70 ⚠cold | 2459/0 | 139,126 | 1,242 | 1,433 | 6.60/29.6/47.7 | 10.5ms | 8.5/39.1/105.4 |
| D3 5P2D | c115 | 2735/0 | 153,554 | 1,371 | 1,944 | 7.52/32.4/45.4 | 11.7ms | 11.8/47.0/145.1 |
| D2 6P2D | c70 ⚠cold | 2118/0 | 111,121 | 868 | 1,405 | 8.66/35.0/63.0 | 11.1ms | 11.2/46.2/140.5 |
| D2 6P2D | c115 ⚠semi-cold | 2029/0 | 117,928 | 921 | 1,336 | 6.74/30.4/56.0 | 11.5ms | 10.4/42.3/133.4 |
| D2 6P2D | c160 | 2848/0 | 185,061 | 1,446 | 1,859 | 7.32/31.6/62.1 | 11.6ms | 10.1/43.2/114.7 |
| D3 6P2D | c160 ⚠cold | 2220/0 | 115,929 | 906 | 1,578 | 6.85/31.3/53.7 | 11.7ms | 11.9/46.9/131.5 |
| **D3 6P2D** | **c115** | **3427/0** | **198,381** | **1,550** | **2,055** | 7.06/32.4/52.9 | 11.0ms | 10.8/40.5/123.9 |
| D3-B 6P2D (prefill cap 8) | c160 warmup ⚠cold | 2573/0 | 161,812 | 1,264 | — | — | — | — |
| D3-B 6P2D (prefill cap 8) | c160 | 2074/**3** | 106,658 | 833 | 1,370 | 8.31/38.9/61.0 | 12.0ms | 12.6/51.0/143.3 |

Zero request failures in all runs except D3-B c160 (3 fails); no serving-pod restarts during any measured window.

## Read (final)

0. **Variance caveat**: c160 runs span 107–185k tok/s across configs/replays (random
   session duplication, shared-fabric neighbors, router index warmth). Single-run deltas
   at c160 are not conclusive; the c115 warm pair (D2 117.9k semi-cold vs D3 198.4k warm)
   overstates D3 for the same reason. Robust claims below survive the caveat; anything
   finer needs repeated runs.
0b. **D3-B (prefill running cap 4→8): clearly worse** (106.7k, and the campaign's only
   request failures: 3). Keep the cap at 4.

## Read (details)
1. **Warm-vs-warm at 6P2D: D3 (improved EPP) 198.4k@c115 vs D2 185.1k@c160** — D3 reaches
   a higher peak at LOWER concurrency (+7% throughput, 1,550 vs 1,446/GPU), i.e. the
   improved router converts the same hardware into more goodput earlier on the curve.
2. **5P2D → 6P2D scaling (warm)**: 156.7k → 185–198k (+18–27%) for +14% GPUs — slightly
   super-linear per-GPU at the right operating point (c160/c115), because the workload
   needs ~c130+ to fill 128 GPUs.
3. **Concurrency matters more than shape below saturation**: 6P2D at c70 idles a third
   of its prefill capacity.
4. D3's TTFT p50 consistently ≤ D2's at matched warm points; tails similar.
5. Campaign-best per-GPU (1,550) is still **2.1× below the D1 aggregated baseline**
   (3,322/GPU at 40 GPUs, us-west8) on this prefill-dominated trace — PD+wide-EP buys
   KV capacity and TTFT structure, not raw prefill efficiency, for this workload.

## Incidents / gotchas (for reproduction)
- EPP `:main` image now requires `--allow-experimental-plugins` for `utilization-filter`
  (alpha gating added upstream); v0.9.0 lacks the plugin entirely.
- Sweep runs with >~1900-session duplicated corpora kill inference-perf workers
  ("did not survive the stage") — generator-side; finals with ≤500-session corpora clean.
  Sweep stage tables are directional only; finals are authoritative.
- Session-cursor rule: total `num_sessions` across stages must be ≤ `duplicate_sessions_target`.
- a4workload-* VMs + broken pool-3 recreations contend for the 40-slot B200 reservation;
  `vllm-deepseek` was relocated to no-RDMA pool-2 (backup manifest in `manifests/`).
