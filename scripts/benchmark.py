#!/usr/bin/env python3
"""
Sol daemon performance benchmark.

Measures:
  - Time-to-first-token (TTFT)
  - Total wall time per query
  - CPU % for daemon + ollama processes during query
  - RAM (RSS) before/after each query
  - Swap usage delta

Usage:
  source ~/.sol/venv/bin/activate
  python3 scripts/benchmark.py [--host http://localhost:8765] [--key <api_key>]

Results written to scripts/benchmark_results_<timestamp>.json
and printed as a summary table.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    import requests
    import psutil
except ImportError:
    print("Missing deps. Run: pip install requests psutil")
    sys.exit(1)

# ── Representative test queries ───────────────────────────────────────────────
QUERIES = [
    # General knowledge (should skip RAG)
    {"question": "What is the capital of France?",  "expect_vault": False},
    {"question": "Who are you?",                    "expect_vault": False},
    # Vault queries (should use RAG)
    {"question": "What do my notes say about Roma?", "expect_vault": True},
    {"question": "Summarise my most recent note.",   "expect_vault": True},
    {"question": "What tags do I use most often?",   "expect_vault": True},
]


def get_process_stats() -> dict:
    """Snapshot CPU/RAM for daemon (uvicorn) and ollama processes."""
    stats = {"daemon_rss_mb": 0, "ollama_rss_mb": 0, "swap_mb": 0}
    try:
        for proc in psutil.process_iter(["name", "cmdline", "memory_info"]):
            name = proc.info["name"] or ""
            cmd  = " ".join(proc.info["cmdline"] or [])
            rss  = proc.info["memory_info"].rss / (1024 * 1024)
            if "uvicorn" in cmd or "daemon" in cmd:
                stats["daemon_rss_mb"] += rss
            elif "ollama" in name:
                stats["ollama_rss_mb"] += rss
        stats["swap_mb"] = psutil.swap_memory().used / (1024 * 1024)
    except Exception:
        pass
    return stats


def measure_query(host: str, api_key: str, question: str) -> dict:
    url = f"{host}/api/query"
    headers = {"X-API-Key": api_key, "Content-Type": "application/json"}
    payload = {"question": question, "history": None}

    stats_before = get_process_stats()
    t0 = time.perf_counter()
    ttft = None
    total_tokens = 0

    try:
        with requests.post(url, headers=headers, json=payload, stream=True, timeout=120) as resp:
            resp.raise_for_status()
            for raw_line in resp.iter_lines():
                if not raw_line:
                    continue
                line = raw_line.decode("utf-8", errors="ignore")
                if not line.startswith("data: "):
                    continue
                try:
                    event = json.loads(line[6:])
                except json.JSONDecodeError:
                    continue

                if event.get("type") == "token":
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    total_tokens += len((event.get("content") or "").split())
                elif event.get("type") in ("done", "error"):
                    break

    except Exception as e:
        return {"error": str(e), "question": question}

    wall = time.perf_counter() - t0
    stats_after = get_process_stats()

    return {
        "question": question,
        "ttft_s": round(ttft or wall, 3),
        "total_s": round(wall, 3),
        "tokens_approx": total_tokens,
        "tokens_per_s": round(total_tokens / wall, 1) if wall > 0 else 0,
        "daemon_rss_delta_mb": round(
            stats_after["daemon_rss_mb"] - stats_before["daemon_rss_mb"], 1
        ),
        "ollama_rss_mb": round(stats_after["ollama_rss_mb"], 1),
        "swap_delta_mb": round(stats_after["swap_mb"] - stats_before["swap_mb"], 1),
    }


def check_gpu(host: str, api_key: str) -> dict:
    """Check Ollama GPU offload via `ollama ps` and Metal availability."""
    gpu_info = {"metal_available": False, "ollama_ps": ""}
    try:
        ps = subprocess.run(["ollama", "ps"], capture_output=True, text=True, timeout=5)
        gpu_info["ollama_ps"] = ps.stdout.strip()
        # Look for GPU percentage in output
        if "100%" in ps.stdout or "GPU" in ps.stdout:
            gpu_info["metal_available"] = True
    except Exception:
        pass

    try:
        result = subprocess.run(
            ["system_profiler", "SPDisplaysDataType", "-json"],
            capture_output=True, text=True, timeout=5,
        )
        data = json.loads(result.stdout)
        gpu_info["gpu_name"] = (
            data.get("SPDisplaysDataType", [{}])[0].get("sppci_model", "unknown")
        )
    except Exception:
        gpu_info["gpu_name"] = "unknown"

    return gpu_info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="http://localhost:8765")
    parser.add_argument("--key", default=None)
    args = parser.parse_args()

    # Load API key from config if not passed
    api_key = args.key
    if not api_key:
        try:
            cfg_path = Path.home() / ".sol" / "config.json"
            api_key = json.loads(cfg_path.read_text())["daemon_api_key"]
        except Exception:
            print("Cannot load API key. Pass --key or ensure ~/.sol/config.json exists.")
            sys.exit(1)

    print(f"Benchmarking Sol daemon at {args.host}")
    print("=" * 60)

    gpu_info = check_gpu(args.host, api_key)
    print(f"GPU: {gpu_info.get('gpu_name', 'unknown')} | Metal: {gpu_info['metal_available']}")
    if gpu_info["ollama_ps"]:
        print(f"ollama ps:\n{gpu_info['ollama_ps']}")
    print()

    results = []
    for q in QUERIES:
        print(f"  Q: {q['question'][:55]}…")
        r = measure_query(args.host, api_key, q["question"])
        r["expect_vault"] = q["expect_vault"]
        results.append(r)
        if "error" in r:
            print(f"     ERROR: {r['error']}")
        else:
            print(
                f"     TTFT={r['ttft_s']}s  total={r['total_s']}s  "
                f"~{r['tokens_approx']} tokens  RAM Δ={r['daemon_rss_delta_mb']}MB"
            )

    # Summary
    good = [r for r in results if "error" not in r]
    if good:
        avg_ttft  = sum(r["ttft_s"] for r in good) / len(good)
        avg_total = sum(r["total_s"] for r in good) / len(good)
        avg_tps   = sum(r["tokens_per_s"] for r in good) / len(good)
        print()
        print("Summary")
        print(f"  Avg TTFT:  {avg_ttft:.2f}s")
        print(f"  Avg total: {avg_total:.2f}s")
        print(f"  Avg tok/s: {avg_tps:.1f}")

    # Save results
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = Path(__file__).parent / f"benchmark_results_{ts}.json"
    payload = {"timestamp": ts, "host": args.host, "gpu": gpu_info, "results": results}
    out_path.write_text(json.dumps(payload, indent=2))
    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    main()
