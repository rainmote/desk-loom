#!/usr/bin/env python3
"""Opt-in multi-window acceptance using two owned, temporary AppKit windows.

--with-llm additionally uses the existing ChatGPT subscription to copy a random
value observed in one window to the second. No user document is selected.
"""
import argparse
import json
import pathlib
import subprocess
import sys
import time
import uuid

from computer_acceptance import Bridge, native, text_value
from fixtures.window_lab import WindowLab

ROOT = pathlib.Path(__file__).resolve().parents[1]


def menu_count(expected):
    deadline = time.monotonic() + 3
    while True:
        state = native("ui_state")
        if (state["controlledWindowCount"] == expected and state["statusTitle"] == str(expected)
                and state["statusIconVisible"] and not state["statusThumbnailVisible"]):
            return state
        if time.monotonic() >= deadline:
            raise AssertionError({"expected_count": expected, "actual": state})
        time.sleep(0.05)


def run(with_llm):
    baseline = native("computer_capabilities")["controlled_window_count"]
    assert baseline <= 6, "Two free control slots are required for acceptance"
    directory = ROOT / "evidence" / ("multiwindow-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    result = {"outcome": "failed", "evidence": str(directory), "existing_sessions": baseline}
    bridge = None
    fixture = None
    owned = []
    try:
        fixture = WindowLab()
        fixture.start()
        titles = fixture.titles
        selected = fixture.select_windows(native)
        result["fixture"] = {"pid": fixture.process.pid, "titles": titles, "app": "WindowLab"}
        bridge = Bridge(directory)
        attached = [bridge.call("computer_attach", {"pid": w["pid"], "window_id": w["window_id"]}) for w in selected]
        owned = [session["session_id"] for session in attached]
        assert len(set(owned)) == 2
        menu_count(baseline + 2)
        result["simultaneous_sessions"] = 2
        value = "协作校验码：" + uuid.uuid4().hex[:12]
        source = bridge.call("computer_act", {"session_id": owned[0], "action": "set_value",
                             "selector": {"role": "AXTextArea", "settable": True},
                             "request_id": str(uuid.uuid4()), "value": value})
        assert source["outcome"] == "verified"
        cleared = bridge.call("computer_act", {"session_id": owned[1], "action": "set_value",
                              "selector": {"role": "AXTextArea", "settable": True},
                              "request_id": str(uuid.uuid4()), "value": ""})
        assert cleared["outcome"] == "verified"
        destination = bridge.call("computer_observe", {"session_id": owned[1]})
        assert text_value(destination) == ""
        wrong = native("computer_observe", {"session_id": owned[0]})
        foreign = [node for node in wrong["nodes"] if node["role"] == "AXTextArea" and node.get("settable")][0]
        # Negative raw RPC: a source snapshot cannot authorize a destination write.
        import rpc
        refused = rpc.call("computer_act", {"session_id": owned[1], "snapshot_id": wrong["snapshot_id"],
                           "node_id": foreign["id"], "request_id": str(uuid.uuid4()),
                           "action": "set_value", "value": "MUST NOT BE WRITTEN"})
        assert not refused["ok"]
        assert text_value(bridge.call("computer_observe", {"session_id": owned[1]})) == ""
        result["cross_window_snapshot_rejected"] = True
        bridge.call("computer_detach", {"session_id": owned.pop(0)})
        menu_count(baseline + 1)
        assert bridge.call("computer_observe", {"session_id": owned[0]})["window"]["window_id"] == selected[1]["window_id"]
        bridge.close()
        bridge = None
        owned.clear()
        menu_count(baseline)
        result["menu_counts"] = [baseline + 2, baseline + 1, baseline]
        result["owned_session_counts"] = [2, 1, 0]
        if with_llm:
            command = [sys.executable, str(ROOT / "scripts/dlm"), "llm", "run", "--json", "--prompt-stdin",
                       "--db-path", str(directory / "llm-xtdb"), "--timeout", "240", "--max-steps", "5"]
            for window in selected:
                command += ["--window", f"{window['pid']}:{window['window_id']}"]
            prompt = (f"这是两个专门创建的测试窗口。请读取标题含 {titles[0]} 的源窗口，将其正文完整复制到"
                      f"标题含 {titles[1]} 的目标窗口，并在末尾加上『｜协作完成』。保持源窗口内容不变，"
                      "不添加换行，不保存或关闭窗口，最后重新读取确认。")
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            started = time.monotonic()
            try:
                process.stdin.write(prompt)
                process.stdin.close()
                process.stdin = None
                deadline = time.monotonic() + 90
                while native("status").get("controlled_window_count", 0) != baseline + 2:
                    assert process.poll() is None, "LLM exited before attaching both windows"
                    assert time.monotonic() < deadline, "LLM did not attach both windows"
                    time.sleep(0.1)
                menu_count(baseline + 2)
                stdout, stderr = process.communicate(timeout=270)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=30)
            events = [json.loads(line) for line in stdout.splitlines()]
            (directory / "llm-events.json").write_text(json.dumps(events, ensure_ascii=False, indent=2))
            assert process.returncode == 0, (events, stderr)
            assert events[-1]["type"] == "completed", events
            menu_count(baseline)
            reads = []
            for window in selected:
                attached = native("computer_attach", {"pid": window["pid"], "window_id": window["window_id"]})
                owned.append(attached["session_id"])
                reads.append(text_value(native("computer_observe", {"session_id": owned[-1]})))
            assert reads == [value, value + "｜协作完成"], reads
            result.update(llm="passed", source_unchanged=True, destination_verified=True,
                          elapsed_seconds=round(time.monotonic() - started, 2), readback=reads)
        result["outcome"] = "passed"
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        try:
            if bridge:
                bridge.close()
        finally:
            try:
                for sid in owned:
                    try:
                        native("computer_detach", {"session_id": sid})
                    except Exception:
                        pass
            finally:
                try:
                    if fixture:
                        fixture.close()
                finally:
                    (directory / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
                    print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--with-llm", action="store_true")
    run(parser.parse_args().with_llm)
