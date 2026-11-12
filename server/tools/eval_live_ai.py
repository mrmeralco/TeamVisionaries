"""Isolated MQTT -> API -> AI smoke test. No changes to demo DB or running services.

python tools/eval_live_ai.py --broker "C:/Program Files/mosquitto/mosquitto.exe"
Default tests deterministic fallback with an unreachable Ollama URL.
Add --model qwen3.5:4b to exercise the real model instead.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

import httpx
import paho.mqtt.client as mqtt

SERVER = Path(__file__).resolve().parent.parent


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait(fn, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result:
                return result
        except (httpx.HTTPError, OSError):
            pass
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for test service/state")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--broker", required=True)
    ap.add_argument("--model")
    args = ap.parse_args()
    sys.path.insert(0, str(SERVER))
    from ai.answers import direct_ids
    broker_port, api_port, dead_port = port(), port(), port()
    processes = []
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    with tempfile.TemporaryDirectory(prefix="solaris-live-") as tmp:
        tmp = Path(tmp)
        conf = tmp / "mosquitto.conf"
        conf.write_text(f"listener {broker_port} 127.0.0.1\nallow_anonymous true\npersistence false\n")
        env = dict(os.environ, SOLARIS_DB=str(tmp / "test.db"), MQTT_HOST="127.0.0.1",
                   MQTT_PORT=str(broker_port), MQTT_ENABLED="1", SOLARIS_MOCK="0", PYTHONUTF8="1",
                   LLM_ENABLED="1", LLM_PROVIDER="ollama", OFFLINE_AFTER_S="5",
                   AI_LOG=str(tmp / "ai.jsonl"))
        if args.model:
            env["LLM_MODEL"] = args.model
        else:
            env["OLLAMA_URL"] = f"http://127.0.0.1:{dead_port}"
        with (tmp / "services.log").open("w", encoding="utf-8") as log:
            try:
                subprocess.run([sys.executable, "tools/seed_history.py"], cwd=SERVER, env=env, check=True,
                               stdout=log, stderr=log)
                hidden = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
                processes.append(subprocess.Popen([args.broker, "-c", str(conf)], stdout=log, stderr=log, **hidden))
                processes.append(subprocess.Popen([sys.executable, "-m", "uvicorn", "app.main:app",
                                  "--host", "127.0.0.1", "--port", str(api_port)], cwd=SERVER,
                                  env=env, stdout=log, stderr=log, **hidden))
                with httpx.Client(base_url=f"http://127.0.0.1:{api_port}", timeout=40) as api:
                    wait(lambda: api.get("/api/health").is_success)
                    wait(lambda: client.connect("127.0.0.1", broker_port) == 0)
                    client.loop_start()
                    wait(lambda: client.is_connected())
                    payload = {"pv_w": 1200, "load_w": 900, "grid_w": 0, "batt_soc": 80,
                               "batt_w": -300, "grid_on": True, "inv_temp_c": 42, "fault_code": 0}
                    def publish(**changes):
                        payload.update(changes)
                        payload["ts"] = int(time.time())
                        # Retain on this disposable broker so startup subscription timing cannot drop a sample.
                        client.publish("solaris/solaris-001/telemetry", json.dumps(payload), qos=1, retain=True).wait_for_publish()
                        wait(lambda: (api.get("/api/live").json().get("telemetry") or {}).get("pv_w") == payload["pv_w"])
                    def chat(question):
                        response = api.post("/api/chat", json={"message": question})
                        response.raise_for_status()
                        out = response.json()
                        direct = direct_ids(question)
                        expected_source = "fallback" if direct or not args.model else "llm"
                        assert out["source"] == expected_source, out
                        if direct:
                            assert set(direct) <= set(out["facts_used"]), out
                        return out["reply"].lower()
                    publish()
                    assert "1.2" in chat("Kumusta ang solar ko?")
                    time.sleep(1.1)  # distinct telemetry timestamps
                    publish(pv_w=3700)
                    assert "3.7" in chat("Kumusta ang solar ko?")
                    publish(pv_w=0, grid_on=False, batt_w=900)
                    wait(lambda: api.get("/api/brownout").json()["active"])
                    assert "brownout" in chat("Magkano na ang bill ko ngayong buwan?").split(".")[0]
                    publish(pv_w=500, fault_code=21, inv_temp_c=78)
                    wait(lambda: api.get("/api/live").json()["telemetry"]["fault_code"] == 21)
                    assert "21" in chat("Kumusta ang solar ko?").split(".")[0]
                    publish(pv_w=700, grid_on=True, fault_code=0)
                    wait(lambda: not api.get("/api/live").json()["device"]["online"], seconds=15)
                    reply = chat("Kumusta ang solar ko?")
                    assert "offline" in reply or "luma" in reply
                    summary = api.get("/api/summary/daily").json()
                    start = time.monotonic()
                    assert api.get("/api/summary/daily").json() == summary
                    assert time.monotonic() - start < 2
                    print("PASS: changing solar, brownout, fault 21, stale readings, cached recap; "
                          + ("real model" if args.model else "unreachable-model fallback"))
            except Exception:
                log.flush()
                print((tmp / "services.log").read_text(encoding="utf-8"), file=sys.stderr)
                raise
            finally:
                client.disconnect()
                client.loop_stop()
                for process in reversed(processes):
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
