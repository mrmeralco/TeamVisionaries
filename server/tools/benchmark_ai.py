"""Sequential isolated model benchmark; writes reports under logs, never changes .env.

python tools/benchmark_ai.py --repeat 3
Models must already be pulled. Run without other requests to Ollama for comparable timings.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

import httpx

SERVER = Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--models", nargs="+", default=["qwen3.5:4b", "qwen3.5:9b"])
    args = ap.parse_args()
    if args.repeat < 1:
        ap.error("--repeat must be positive")
    sys.path.insert(0, str(SERVER))
    from app import config
    url = config.OLLAMA_URL
    reports = SERVER / "logs" / "benchmark"
    reports.mkdir(parents=True, exist_ok=True)
    summaries = []
    with tempfile.TemporaryDirectory(prefix="solaris-benchmark-") as tmp:
        env = dict(os.environ, SOLARIS_DB=str(Path(tmp) / "history.db"), MQTT_ENABLED="0",
                   LLM_ENABLED="1", LLM_PROVIDER="ollama", SOLARIS_MOCK="0", PYTHONUTF8="1",
                   AI_LOG=str(reports / "ai.jsonl"))
        subprocess.run([sys.executable, "tools/seed_history.py"], cwd=SERVER, env=env, check=True)
        for model in args.models:
            # Unload only benchmark models; do not stop the Ollama service.
            for other in args.models:
                httpx.post(f"{url}/api/generate", json={"model": other, "keep_alive": 0}, timeout=120).raise_for_status()
            name = model.replace(":", "-").replace("/", "-")
            report = reports / f"{name}.json"
            subprocess.run([sys.executable, "tools/eval_ai.py", "--model", model,
                            "--repeat", str(args.repeat), "--report", str(report)], cwd=SERVER, env=env)
            data = json.loads(report.read_text(encoding="utf-8"))
            rows = data["results"]
            ps = httpx.get(f"{url}/api/ps", timeout=10).json()
            summary = {"model": model, "passed": sum(not r["failures"] for r in rows),
                       "total": len(rows), "fallbacks": sum(r["strategy"] == "fallback" for r in rows),
                       "direct_answers": sum(r["strategy"] == "direct" for r in rows),
                       "median_s": statistics.median(r["latency_s"] for r in rows),
                       "max_s": max(r["latency_s"] for r in rows), "running_models": ps}
            summaries.append(summary)
            print(json.dumps(summary), flush=True)
            httpx.post(f"{url}/api/generate", json={"model": model, "keep_alive": 0}, timeout=120).raise_for_status()
    (reports / "summary.json").write_text(json.dumps(summaries, indent=2), encoding="utf-8")
    return 0 if all(s["passed"] == s["total"] for s in summaries) else 1


if __name__ == "__main__":
    sys.exit(main())
