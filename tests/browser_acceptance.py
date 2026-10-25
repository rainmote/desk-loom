#!/usr/bin/env python3
"""Opt-in browser acceptance through Codex's registered DeskLoom MCP server.

Run: python3 tests/browser_acceptance.py --live
Uses a new Chrome profile, a loopback fixture and real macOS AX actions. No DOM
automation, DevTools, model turn or existing browser profile is used. Saves page
memory to the registered server's default XTDB directory. Evidence is gitignored.
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import rpc
from codex_mcp_client import CodexMCP

CHROME = pathlib.Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
LABELS = {"title": "任务标题", "note": "任务备注", "save": "保存任务", "reset": "重置测试"}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def native_status():
    response = rpc.call("status")
    require(response["ok"], response)
    return response["result"]


class BrowserFixture:
    def __init__(self, directory, token, executable=CHROME):
        self.directory, self.token = directory, token
        self.executable = pathlib.Path(executable)
        self.events = []
        self.condition = threading.Condition()
        self.profile = tempfile.TemporaryDirectory(prefix="deskloom-browser-")
        self.process = None
        self.log = (directory / "chrome.log").open("w")
        fixture = self
        html = (ROOT / "tests/fixtures/computer-browser.html").read_bytes()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if urlsplit(self.path).path not in ("/", "/computer-browser.html"):
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(html)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(html)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                if self.path != "/events" or not 0 < length < 200000:
                    self.send_error(400)
                    return
                record = json.loads(self.rfile.read(length))
                if record.get("run_token") != fixture.token:
                    self.send_error(400)
                    return
                with fixture.condition:
                    fixture.events.append({**record, "received_monotonic": time.perf_counter()})
                    fixture.condition.notify_all()
                self.send_response(204)
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/computer-browser.html?run={token}"

    def start(self):
        self.process = subprocess.Popen([
            str(self.executable), "--user-data-dir=" + self.profile.name,
            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--disable-sync", "--disable-component-update", "--disk-cache-size=8388608",
            "--media-cache-size=1048576", "--force-renderer-accessibility", "--new-window",
            "--window-size=1100,900", self.url], stdout=self.log, stderr=self.log,
            start_new_session=True)

    def receipt(self, previous, event, title=None, note=None):
        deadline = time.monotonic() + 5
        with self.condition:
            while len(self.events) <= previous and time.monotonic() < deadline:
                self.condition.wait(max(0, deadline - time.monotonic()))
            require(len(self.events) == previous + 1, "Expected exactly one new browser event")
            record = self.events[-1]
        require(record["event"] == event and record["trusted"] is True,
                "Expected a trusted native browser " + event + " event")
        if title is not None:
            require(record["title"] == title and record["note"] == note,
                    "Browser save did not contain the intended values")
        return record

    def close(self):
        if self.process and self.process.poll() is None:
            # Only the process group launched with this temporary profile.
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.log.close()
        self.profile.cleanup()


def labelled(node, key):
    roles = {"AXTextField", "AXTextArea"} if key in ("title", "note") else {"AXButton"}
    return node.get("role") in roles and any(
        node.get(field) == LABELS[key] for field in ("title", "label", "description"))


def control(snapshot, key):
    require(snapshot["complete"], "Browser AX tree is incomplete")
    matches = [node for node in snapshot["nodes"] if labelled(node, key)]
    require(len(matches) == 1, f"Expected one {key} control, found {len(matches)}")
    return matches[0]


def saved_selectors(memory):
    result = {}
    for key in LABELS:
        matches = [row["selector"] for row in memory["selectors"]
                   if not row["ambiguous"] and labelled(row["selector"], key)]
        require(len(matches) == 1, f"Missing unique remembered selector for {key}")
        result[key] = matches[0]
    return result


def accepted(result, *, require_complete=True):
    require(not result.get("replayed"), "A request replay is not a real action")
    require(result.get("outcome") in ("verified", "dispatched"), result)
    require(not result.get("observation_error"), result)
    if require_complete and "observation" in result:
        require(result["observation"]["complete"], "Incomplete post-action tree")
    return result


def stats(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values),
            "samples": values}


def compact_records(records):
    # Full protocol evidence already lives in the client's wire.jsonl log.
    return [{key: value for key, value in record.items() if key not in ("response", "response_wire")}
            for record in records]


def visible_text(snapshot):
    return "\n".join(str(node.get(field, "")) for node in snapshot["nodes"]
                     for field in ("title", "label", "description", "value"))


def await_visible(client, snapshot, expected):
    deadline = time.monotonic() + 5
    while not snapshot["complete"] or expected not in visible_text(snapshot):
        require(time.monotonic() < deadline, "Browser did not display expected state: " + expected)
        time.sleep(0.01)
        snapshot = client.call("computer_observe")
        # A DOM text replacement can invalidate an AX child during traversal.
        # Keep the incomplete sample in protocol evidence, then only re-observe;
        # never perform an action until the required complete state is available.
    return snapshot


def measure_workflow(client, fixture, steps, mode, snapshot=None):
    """Includes returned state and actual browser receipt, excludes resets/setup."""
    start_index, previous = len(client.records), len(fixture.events)
    started = time.perf_counter()
    if mode == "batch":
        result = accepted(client.call("computer_batch", {
            "request_id": str(uuid.uuid4()), "steps": [step for _, step in steps]}))
        require(result["completed"] == len(steps), result)
        for step in result["steps"]:
            accepted(step)
        snapshot = result["observation"]
    else:
        for key, step in steps:
            args = dict(step, request_id=str(uuid.uuid4()))
            if mode == "live_nodes":
                node = control(snapshot, key)
                args.pop("selector", None)
                args.update(snapshot_id=snapshot["snapshot_id"], node_id=node["id"])
            result = accepted(client.call("computer_act", args))
            snapshot = result["observation"]
    receipt = fixture.receipt(previous, "save", steps[0][1]["value"], steps[1][1]["value"])
    require(receipt["revision"] == 1, "Each measured workflow must start after reset")
    # A dispatched AXPress and input readback alone do not prove the save handler ran.
    snapshot = await_visible(client, snapshot, '"event_sequence": ' + str(receipt["event_sequence"]))
    snapshot = await_visible(client, snapshot, "状态：已保存 / Saved · 版本 1")
    elapsed = (time.perf_counter() - started) * 1000
    calls = client.records[start_index:]
    require(control(snapshot, "title")["value"] == receipt["title"], "AX title readback differs")
    require(control(snapshot, "note")["value"] == receipt["note"], "AX note readback differs")
    return {"elapsed_ms": elapsed, "tool_calls": len(calls),
            "response_bytes": sum(record["response_bytes"] for record in calls),
            "event_sequence": receipt["event_sequence"], "native_actions": len(steps)}, snapshot


def independently_reopen(directory, page_id, expected_title, expected_note, expected_memory, expected_event):
    """A separate JVM replays the same default local XTDB after MCP releases it."""
    destination = directory / "xtdb-reopened.json"
    source = """
(require '[desktop.db :as db] '[desktop.memory :as memory]
         '[xtdb.api :as xt] '[clojure.data.json :as json])
(with-open [store (db/open!)]
  (let [page-id (System/getenv "DESKLOOM_TEST_PAGE_ID")
        query #(xt/q (:node store) [% page-id] {:key-fn :snake-case-keyword})
        recalled (memory/recall store page-id)
        result {:db_path (db/default-path) :recall recalled
                :search (memory/search store {:query (System/getenv "DESKLOOM_TEST_TITLE")})
                :version_count (:n (first (query "SELECT COUNT(*) AS n FROM desktop_page_versions WHERE page_id = ?")))
                :visit_count (:n (first (query "SELECT COUNT(*) AS n FROM desktop_page_visits WHERE page_id = ?")))}]
    (spit (System/getenv "DESKLOOM_TEST_RESULT") (json/write-str result))))
"""
    script = directory / "reopen.clj"
    script.write_text(source)
    env = dict(os.environ, DESKLOOM_TEST_PAGE_ID=page_id,
               DESKLOOM_TEST_TITLE=expected_title, DESKLOOM_TEST_RESULT=str(destination))
    with (directory / "xtdb-reopen.log").open("w") as log:
        subprocess.run([str(ROOT / "scripts/clj"), "-M:xtdb", str(script)], env=env,
                       stdout=log, stderr=log, timeout=120, check=True)
    recovered = json.loads(destination.read_text())
    recalled = recovered["recall"]
    require(recalled["historical"] and not recalled["executable"], "Recall must be historical")
    require(control(recalled["snapshot"], "title")["value"] == expected_title, "Persisted title missing")
    require(control(recalled["snapshot"], "note")["value"] == expected_note, "Persisted note missing")
    for field in ("page_id", "version_id", "content_hash", "visit_count"):
        require(recalled[field] == expected_memory[field], "Reopened latest state differs: " + field)
    require('"event_sequence": ' + str(expected_event) in visible_text(recalled["snapshot"]),
            "Latest saved browser result was not recovered")
    require(all("id" not in node for node in recalled["snapshot"]["nodes"]), "Recall exposed live handles")
    require(page_id in [page["page_id"] for page in recovered["search"]], "Persisted page not searchable")
    require(recovered["visit_count"] == recalled["visit_count"], "XTDB visit count mismatch")
    return recovered


def run(trials):
    require(CHROME.exists(), "Google Chrome is required for this opt-in test")
    state = native_status()
    require(not state["active"], "Stop the current DeskLoom session before live acceptance")
    require(state["accessibility"] and state["screen_recording"], "Both native permissions required")
    token = uuid.uuid4().hex
    directory = ROOT / "evidence" / ("browser-" + token)
    directory.mkdir(parents=True)
    summary = {"outcome": "failed", "run_token": token, "evidence": str(directory),
               "transport": "Codex app-server -> registered DeskLoom MCP -> macOS AX",
               "includes_llm_latency": False, "trials": trials}
    client = fixture = None
    try:
        client = CodexMCP(directory)
        status = client.status()
        summary["codex_mcp"] = {key: status.get(key) for key in
                                 ("name", "serverInfo", "runtimeStatus", "toolsError")}
        summary["codex_mcp"]["tool_count"] = len(status["tools"])
        require(len(status["tools"]) == 11 and not status.get("toolsError"), status)
        summary["codex_startup_ms"] = client.startup_ms
        summary["capabilities"] = client.call("computer_capabilities")
        summary["first_tool_roundtrip_ms"] = client.records[-1]["elapsed_ms"]
        fixture = BrowserFixture(directory, token)
        fixture.start()
        summary["fixture_url"] = fixture.url
        deadline = time.monotonic() + 20
        matches = []
        while time.monotonic() < deadline:
            windows = client.call("computer_windows", {"bundle_id": "com.google.Chrome", "pid": fixture.process.pid})
            matches = [window for window in windows["windows"] if token in window.get("title", "")]
            if matches:
                break
            time.sleep(0.2)
        require(len(matches) == 1, "Browser fixture window was not uniquely found")
        attached = client.call("computer_attach", {"window_id": matches[0]["window_id"]})
        summary["attach_and_open_xtdb_ms"] = client.records[-1]["elapsed_ms"]
        snapshot = client.call("computer_observe", {"max_nodes": 1000, "max_depth": 40})
        (directory / "initial-observation.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2))
        for key in LABELS:
            control(snapshot, key)
        page_id = snapshot["memory"]["page_id"]
        summary["page_id"] = page_id
        summary["session_id"] = attached["session_id"]
        require(not fixture.events, "Fixture must not send events on load")
        memory = client.call("computer_memory_recall", {"page_id": page_id})
        selectors = saved_selectors(memory)
        summary["remembered_selectors"] = selectors

        def reset():
            setup_started, setup_index = time.perf_counter(), len(client.records)
            previous = len(fixture.events)
            if previous:
                # A measured save may return before its asynchronous receipt DOM
                # update. Complete that transition before the reset pre-observe.
                previous_sequence = fixture.events[-1]["event_sequence"]
                await_visible(client, client.call("computer_observe"),
                              "事件回执：已记录 / Recorded · " + str(previous_sequence))
                require(len(fixture.events) == previous, "Unexpected event during reset readiness")
            result = accepted(client.call("computer_act", {"request_id": str(uuid.uuid4()),
                              "action": "click", "selector": selectors["reset"]}), require_complete=False)
            # Validate dispatch immediately, but a reset's text replacement can
            # transiently invalidate a child in its post-observation. Keep that
            # sample in the wire log and only re-observe until reset is complete.
            receipt = fixture.receipt(previous, "reset")
            require(receipt["revision"] == 0, "Reset did not restore revision zero")
            ready = await_visible(client, result["observation"],
                                  '"event_sequence": ' + str(receipt["event_sequence"]))
            ready = await_visible(client, ready, "状态：已重置 / Reset · 版本 0")
            ready = await_visible(client, ready,
                                  "事件回执：已记录 / Recorded · " + str(receipt["event_sequence"]))
            accepted(dict(result, observation=ready))
            for key in ("title", "note"):
                require(control(ready, key)["value"] == receipt[key], "Reset AX readback differs: " + key)
            summary.setdefault("reset_setups", []).append({
                "event_sequence": receipt["event_sequence"], "snapshot_id": ready["snapshot_id"],
                "elapsed_ms": (time.perf_counter() - setup_started) * 1000,
                "tool_calls": len(client.records) - setup_index})
            return ready

        def steps(title, note):
            return [("title", {"action": "set_value", "selector": selectors["title"], "value": title}),
                    ("note", {"action": "set_value", "selector": selectors["note"], "value": note}),
                    ("save", {"action": "click", "selector": selectors["save"]})]

        # First successful browser interaction uses only fresh observed handles.
        snapshot = reset()
        first_steps = steps("首次保存 " + token[:8], "真实浏览器操作，第一轮。")
        summary["first_workflow"], snapshot = measure_workflow(client, fixture, first_steps,
                                                               "live_nodes", snapshot)
        print("First real browser save verified", flush=True)
        # Reload selectors from the persisted page for the second actual operation.
        found = client.call("computer_memory_search", {"query": token, "bundle_id": "com.google.Chrome"})
        require(page_id in [page["page_id"] for page in found["pages"]], "Saved browser page missing")
        memory = client.call("computer_memory_recall", {"page_id": page_id})
        selectors = saved_selectors(memory)
        reset()
        second_steps = steps("记忆复用 " + token[:8], "来自 XTDB 的选择器，经新鲜观察后再次保存。")
        summary["second_workflow"], snapshot = measure_workflow(client, fixture, second_steps, "batch")
        print("Remembered-selector browser save verified", flush=True)

        # Paired warm trials: same three actions, same selectors, same start values.
        # Alternate order; never reuse request IDs. Do not charge reset to either arm.
        samples = {"serial_selectors": [], "batch": []}
        for index in range(trials):
            for mode in (("serial_selectors", "batch") if index % 2 == 0 else ("batch", "serial_selectors")):
                reset()
                record, snapshot = measure_workflow(client, fixture,
                    steps("配对测量 " + token[:8], "相同动作与内容 / matched browser workflow"), mode)
                samples[mode].append(record)
        summary["matched_workflows"] = {
            mode: {"elapsed_ms": stats([row["elapsed_ms"] for row in records]),
                   "response_bytes": stats([row["response_bytes"] for row in records]),
                   "tool_calls": stats([row["tool_calls"] for row in records]), "native_actions": 3, "runs": records}
            for mode, records in samples.items()}
        print("Matched repeated workflows verified", flush=True)

        # Fetch acknowledgement updates the page after the server receives a save.
        # Wait once outside the stable-observation benchmark; never discard changed pairs.
        await_visible(client, snapshot, "事件回执：已记录 / Recorded · " + str(fixture.events[-1]["event_sequence"]))
        # Stable paired full/delta observations; do not insert another tool between them.
        pairs = []
        for _ in range(trials):
            full = client.call("computer_observe")
            full_record = dict(client.records[-1])
            delta = client.call("computer_observe", {"delta": True, "since_snapshot_id": full["snapshot_id"]})
            delta_record = dict(client.records[-1])
            require(full["complete"] and delta["complete"], "Incomplete observation")
            require(delta["mode"] == "delta" and not delta["changed_nodes"], "Stable delta changed")
            require(not delta["memory"]["changed"] and not delta["memory"]["new_version"], "Stable page not deduplicated")
            require(delta["memory"]["version_id"] == full["memory"]["version_id"], "Stable version differs")
            pairs.append({"full_bytes": full_record["response_bytes"], "delta_bytes": delta_record["response_bytes"],
                          "full_ms": full_record["elapsed_ms"], "delta_ms": delta_record["elapsed_ms"],
                          "node_count": len(full["nodes"]), "changed_nodes": len(delta["changed_nodes"]),
                          "version_id": full["memory"]["version_id"]})
        summary["full_delta_pairs"] = pairs
        summary["delta_response_reduction_pct"] = 100 * (1 - statistics.median(row["delta_bytes"] for row in pairs)
                                                          / statistics.median(row["full_bytes"] for row in pairs))
        (directory / "final-observation.json").write_text(json.dumps(full, ensure_ascii=False, indent=2))
        picture = client.call("computer_screenshot", {"max_width": 1100})
        png = base64.b64decode(picture["data"], validate=True)
        require(hashlib.sha256(png).hexdigest() == picture["sha256"], "Screenshot hash mismatch")
        require(png.startswith(b"\x89PNG\r\n\x1a\n") and
                struct.unpack(">II", png[16:24]) == (picture["width"], picture["height"]),
                "Screenshot PNG dimensions differ from metadata")
        require(picture["session_id"] == attached["session_id"] and
                picture["window_id"] == snapshot["window"]["id"] and
                picture["observation"]["app"]["pid"] == fixture.process.pid,
                "Screenshot identity differs from owned browser")
        (directory / "browser.png").write_bytes(png)
        summary["screenshot"] = {key: picture[key] for key in ("width", "height", "sha256", "capture_match")}
        summary["latest_memory_before_close"] = picture["observation"]["memory"]
        summary["metrics"] = client.call("computer_metrics")
        client.call("computer_detach")
        summary["tool_records"] = compact_records(client.records)
        client.close()
        client = None
        recovered = independently_reopen(directory, page_id, "配对测量 " + token[:8],
            "相同动作与内容 / matched browser workflow", summary["latest_memory_before_close"],
            fixture.events[-1]["event_sequence"])
        summary["persistence"] = {key: recovered[key] for key in ("db_path", "version_count", "visit_count")}
        summary["persistence"].update(independent_jvm_recovered=True,
                                       version_id=recovered["recall"]["version_id"])
        require(recovered["recall"]["snapshot"]["window"]["url"] == fixture.url, "Page URL not preserved")
        summary["browser_events"] = fixture.events
        require(all(event["event_sequence"] == i + 1 for i, event in enumerate(fixture.events)),
                "Missing or duplicate browser event")
        require(sum(event["event"] == "save" for event in fixture.events) == 2 + 2 * trials,
                "Expected number of real saves differs")
        final_status = native_status()
        require(not final_status["active"], "Native session was not detached")
        require(final_status["controller_application_path"] == "/Applications/DeskLoom.app",
                "Generic status lost the controller identity required for safe app updates")
        summary["outcome"] = "passed"
    except Exception as error:
        summary["error"] = str(error)
        raise
    finally:
        pending_error = sys.exc_info()[0] is not None
        cleanup_errors = []
        if client:
            summary["tool_records"] = compact_records(client.records)
            try:
                client.close()
            except Exception as error:
                cleanup_errors.append("Codex cleanup: " + str(error))
        if fixture:
            summary["browser_events"] = fixture.events
            try:
                fixture.close()
            except Exception as error:
                cleanup_errors.append("Browser cleanup: " + str(error))
        if cleanup_errors:
            summary["outcome"] = "failed"
            summary["cleanup_errors"] = cleanup_errors
        (directory / "result.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        print(json.dumps({key: summary[key] for key in ("outcome", "evidence", "error") if key in summary},
                         ensure_ascii=False), flush=True)
        if cleanup_errors and not pending_error:
            raise RuntimeError("; ".join(cleanup_errors))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--trials", type=int, default=5)
    args = parser.parse_args()
    require(args.trials >= 5, "At least five warm paired trials are required")
    run(args.trials)
