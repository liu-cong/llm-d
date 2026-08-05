#!/usr/bin/env python3
"""Aggregate inference-perf reports across the benchmark runs into one table.

Usage: python3 analyze_results.py
Scans run-*/results/*/reports-*/ for per-stage metrics and prints a comparison
table; writes all_results.json next to this script.
"""
import glob
import json
import os

BASE = os.path.dirname(os.path.abspath(__file__))
GPUS = 40  # default; per-run override via 5th tuple element

RUNS = [
    # (env label, run folder, result name, stage->concurrency map[, gpus])
    ("d1-agg", "run-20260730-glm-fp8-vllm-baseline", "sweep-low", {0: 16, 1: 32, 2: 48}),
    ("d1-agg", "run-20260730-glm-fp8-vllm-baseline", "sweep", {0: 64, 1: 128, 2: 192, 3: 256}),
    ("d1-agg", "run-20260730-glm-fp8-vllm-baseline", "final-c35", {0: 35}),
    ("d1-agg", "run-20260730-glm-fp8-vllm-baseline", "final-c58", {0: 58}),
    ("d2-pd-40g", "run-20260730-glm-fp8-vllm-pd-ep16", "sweep", {0: 16, 1: 32, 2: 48, 3: 64}),
    ("d2-pd-40g", "run-20260730-glm-fp8-vllm-pd-ep16", "final-c35", {0: 35}),
    ("d2-pd-40g", "run-20260730-glm-fp8-vllm-pd-ep16", "final-c58", {0: 58}),
    ("d3-pd-40g", "run-20260730-glm-fp8-vllm-pd-ep16-router", "sweep", {0: 16, 1: 32, 2: 48, 3: 64}),
    ("d3-pd-40g", "run-20260730-glm-fp8-vllm-pd-ep16-router", "final-c35", {0: 35}),
    ("d3-pd-40g", "run-20260730-glm-fp8-vllm-pd-ep16-router", "final-c58", {0: 58}),
    ("d2-pd-5p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d2-5p2d-final-c70", {0: 70}, 112),
    ("d2-pd-5p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d2-5p2d-final-c115", {0: 115}, 112),
    ("d3-pd-5p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d3-5p2d-final-c70", {0: 70}, 112),
    ("d3-pd-5p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d3-5p2d-final-c115", {0: 115}, 112),
    ("d2-pd-6p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d2-6p2d-final-c70", {0: 70}, 128),
    ("d2-pd-6p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d2-6p2d-final-c115", {0: 115}, 128),
    ("d2-pd-6p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d2-6p2d-final-c160", {0: 160}, 128),
    ("d3-pd-6p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d3-6p2d-final-c115", {0: 115}, 128),
    ("d3-pd-6p2d", "run-20260803-glm-fp8-vllm-pd-a4pr-16n", "d3-6p2d-final-c160", {0: 160}, 128),
    ("d4v1-agg", "run-20260804-glm-fp8-d4-agg-dep16", "sweep", {0: 16, 1: 32, 2: 48, 3: 64, 4: 96}, 32),
    ("d4v1-agg", "run-20260804-glm-fp8-d4-agg-dep16", "final-c35", {0: 35}, 32),
    ("d4v1-agg", "run-20260804-glm-fp8-d4-agg-dep16", "final-c58", {0: 58}, 32),
    ("d4v2-agg", "run-20260804-glm-fp8-d4-agg-dep16", "v2-sweep", {0: 32, 1: 64, 2: 128, 3: 192}, 32),
    ("d4v2-agg", "run-20260804-glm-fp8-d4-agg-dep16", "v2-final-c35", {0: 35}, 32),
    ("d4v2-agg", "run-20260804-glm-fp8-d4-agg-dep16", "v2-final-c58", {0: 58}, 32),
    ("d4v2-agg", "run-20260804-glm-fp8-d4-agg-dep16", "v2-final-c160", {0: 160}, 32),
]


def fmt_stage(env, name, conc, d, kind, gpus=GPUS):
    s = d["successes"]
    t = s["throughput"]
    lat = s["latency"]
    ttft = lat["time_to_first_token"]
    tpot = lat["time_per_output_token"]
    req = lat["request_latency"]
    return {
        "env": env,
        "run": name,
        "kind": kind,
        "concurrency": conc,
        "n_ok": s["count"],
        "n_fail": d["failures"]["count"],
        "in_tok_s": round(t["input_tokens_per_sec"], 1),
        "out_tok_s": round(t["output_tokens_per_sec"], 1),
        "in_tok_s_per_gpu": round(t["input_tokens_per_sec"] / gpus, 1),
        "out_tok_s_per_gpu": round(t["output_tokens_per_sec"] / gpus, 2),
        "req_s": round(t["requests_per_sec"], 3),
        "ttft_p50_s": round(ttft["median"], 2),
        "ttft_p95_s": round(ttft["p95"], 2),
        "ttft_p99_s": round(ttft["p99"], 2),
        "tpot_p50_ms": round(tpot["median"] * 1000, 2),
        "tpot_p95_ms": round(tpot["p95"] * 1000, 2),
        "tpot_p99_ms": round(tpot["p99"] * 1000, 2),
        "req_e2e_p50_s": round(req["median"], 1),
        "req_e2e_p90_s": round(req["p90"], 1),
        "req_e2e_p99_s": round(req["p99"], 1),
    }


def main():
    rows = []
    for entry in RUNS:
        env, folder, name, stages = entry[:4]
        gpus = entry[4] if len(entry) > 4 else GPUS
        reps = sorted(glob.glob(os.path.join(BASE, folder, "results", name, "reports-*")))
        if not reps:
            continue
        rep = reps[-1]
        kind = "final" if "final" in name else "sweep"
        for stage_id, conc in stages.items():
            p = os.path.join(rep, f"stage_{stage_id}_lifecycle_metrics.json")
            if not os.path.exists(p):
                continue
            with open(p) as f:
                d = json.load(f)
            if not d.get("successes") or not d["successes"].get("count"):
                continue
            rows.append(fmt_stage(env, name, conc, d, kind, gpus))
        ss_path = os.path.join(rep, "summary_session_lifecycle_metrics.json")
        if kind == "final" and rows and os.path.exists(ss_path):
            with open(ss_path) as f:
                ss = json.load(f)
            dur = ss.get("session_duration_sec") or {}
            rows[-1]["sessions_done"] = ss.get("num_sessions_succeeded")
            rows[-1]["session_e2e_p50_s"] = round(dur.get("median", 0), 1) if dur else None

    cols = ["env", "run", "concurrency", "n_ok", "n_fail", "in_tok_s", "out_tok_s",
            "in_tok_s_per_gpu", "out_tok_s_per_gpu", "ttft_p50_s", "ttft_p95_s", "ttft_p99_s",
            "tpot_p50_ms", "tpot_p95_ms", "tpot_p99_ms", "req_e2e_p50_s", "req_e2e_p90_s", "req_e2e_p99_s"]
    print("\t".join(cols))
    for r in rows:
        print("\t".join(str(r.get(c, "")) for c in cols))
    out = os.path.join(BASE, "all_results.json")
    with open(out, "w") as f:
        json.dump(rows, f, indent=1)
    print(f"\nwrote {out} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
