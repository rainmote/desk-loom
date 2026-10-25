#!/usr/bin/env python3
"""Opt-in real macOS acceptance. Modifies only an owned WindowLab test window.

Run: python3 tests/computer_acceptance.py --live
Compiles a temporary AppKit fixture; no user documents or remote apps are used.
No synthetic keyboard/mouse input or explicit focus changes are dispatched.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import select
import statistics
import subprocess
import sys
import time
import uuid

from fixtures.window_lab import WindowLab

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import rpc


class Bridge:
    def __init__(self, directory):
        self.log = (directory / ("bridge-" + uuid.uuid4().hex[:8] + ".log")).open("w")
        self.process = subprocess.Popen(
            [str(ROOT / "scripts/dlm"), "agent", "--db-path", str(directory / "xtdb")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, encoding="utf-8", bufsize=1)
        self.sequence = 0

    def call(self, tool, arguments=None):
        self.sequence += 1
        self.process.stdin.write(json.dumps({"id": self.sequence, "tool": tool,
                                             "arguments": arguments or {}}, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 90)[0]:
            raise TimeoutError("Computer bridge did not reply; action was not retried")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("Bridge exited; inspect evidence log")
        response = json.loads(line)
        assert response["id"] == self.sequence, response
        if not response["ok"]:
            raise RuntimeError(json.dumps(response, ensure_ascii=False))
        return response["result"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=20)
        self.process.stdout.close()
        self.log.close()
        assert self.process.returncode == 0, self.process.returncode


def native(method, params=None):
    result = rpc.call(method, params)
    if not result["ok"]:
        raise RuntimeError(json.dumps(result, ensure_ascii=False))
    return result["result"]


def text_value(snapshot):
    areas = [node for node in snapshot["nodes"] if node["role"] == "AXTextArea" and node["settable"]]
    assert len(areas) == 1, "Fixture must have exactly one text area"
    return areas[0].get("value")


def run():
    state = native("status")
    baseline = state["controlled_window_count"]
    assert baseline < 8, "One free control slot is required for acceptance"
    assert state["accessibility"] and state["screen_recording"], "Both permissions required"
    directory = ROOT / "evidence" / ("computer-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    summary = {"outcome": "failed", "evidence": str(directory), "backend": "real-macos-ax", "existing_sessions": baseline}
    bridge = None
    fixture = None
    try:
        fixture = WindowLab()
        fixture.start()
        bridge = Bridge(directory)
        target = fixture.select_windows(bridge.call, count=1)[0]
        summary["fixture"] = {"pid": fixture.process.pid, "title": target["title"], "app": "WindowLab"}
        session = bridge.call("computer_attach", {"pid": fixture.process.pid, "window_id": target["window_id"]})
        assert session["observation"]["complete"], "Fixture observation incomplete"
        summary["session_id"] = session["session_id"]
        selector = {"role": "AXTextArea", "settable": True}
        first = "通用 Computer Use 验证 A\n" + "XTDB 本地页面记忆；新观察校验。\n" * 80
        action = {"request_id": str(uuid.uuid4()), "action": "set_value", "selector": selector, "value": first}
        written = bridge.call("computer_act", action)
        assert written["outcome"] == "verified", written
        assert text_value(written["observation"]) == first
        replay = bridge.call("computer_act", action)
        assert replay["replayed"] and replay["historical"]
        second = first.replace("验证 A", "验证 B")
        final = first.replace("验证 A", "验证 C")
        batch = bridge.call("computer_batch", {"request_id": str(uuid.uuid4()), "steps": [
            {"action": "set_value", "selector": selector, "value": second},
            {"action": "set_value", "selector": selector, "value": final}]})
        assert batch["completed"] == 2 and all(step["outcome"] == "verified" for step in batch["steps"])
        assert text_value(batch["observation"]) == final
        full = bridge.call("computer_observe")
        latest = full["snapshot_id"]
        times = []
        for _ in range(5):
            delta = bridge.call("computer_observe", {"delta": True, "since_snapshot_id": latest})
            assert delta["mode"] == "delta" and not delta["changed_nodes"]
            assert not delta["memory"]["changed"] and not delta["memory"]["new_version"]
            latest = delta["snapshot_id"]
            times.append(delta["elapsed_ms"])
        picture = bridge.call("computer_screenshot", {"max_width": 720})
        png = base64.b64decode(picture["data"], validate=True)
        assert hashlib.sha256(png).hexdigest() == picture["sha256"]
        (directory / "window.png").write_bytes(png)
        page_id = full["memory"]["page_id"]
        recalled = bridge.call("computer_memory_recall", {"page_id": page_id})
        assert recalled["historical"] and not recalled["executable"]
        assert text_value(recalled["snapshot"]) == final
        summary.update({"action_outcomes": [written["outcome"]] + [step["outcome"] for step in batch["steps"]],
                        "page_id": page_id, "request_replay_did_not_dispatch": True,
                        "unchanged_observations_reused_version": True,
                        "full_response_bytes": len(json.dumps(full, ensure_ascii=False).encode()),
                        "delta_response_bytes": len(json.dumps(delta, ensure_ascii=False).encode()),
                        "warm_delta_median_ms": statistics.median(times),
                        "warm_delta_samples_ms": times,
                        "screenshot": {key: picture[key] for key in ("width", "height", "sha256", "elapsed_ms")},
                        "metrics": bridge.call("computer_metrics")})
        bridge.call("computer_detach")
        idle = native("status")
        ui = native("ui_state")
        assert idle["backend"] == "macos-ax"
        assert idle["controlled_window_count"] == baseline
        assert session["session_id"] not in {item["session_id"] for item in idle["sessions"]}
        assert ui["statusTitle"] == str(baseline) and ui["controlledWindowCount"] == baseline
        assert ui["statusIconVisible"] and not ui["statusThumbnailVisible"]
        if baseline == 0:
            assert not idle["active"] and idle["session_id"] == "" and idle["snapshot_id"] == ""
            assert not ui["overlayVisible"] and not ui["previewLive"]
        summary["detached_status_matches_ui"] = True
        bridge.close()
        bridge = None
        # A new JVM proves recovery from the local log/storage, not an in-memory cache.
        bridge = Bridge(directory)
        found = bridge.call("computer_memory_search", {"query": "验证 C"})
        assert page_id in [page["page_id"] for page in found["pages"]]
        recalled = bridge.call("computer_memory_recall", {"page_id": page_id})
        assert text_value(recalled["snapshot"]) == final
        summary["independent_jvm_recovered"] = True
        summary["outcome"] = "passed"
    except Exception as error:
        summary["error"] = str(error)
        raise
    finally:
        try:
            if bridge:
                bridge.close()
        finally:
            try:
                if fixture:
                    fixture.close()
            finally:
                (directory / "result.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
                print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.parse_args()
    run()
