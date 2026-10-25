#!/usr/bin/env python3
"""Opt-in real LLM acceptance from Google Chrome to Microsoft Edge.

Run: python3 tests/cross_app_acceptance.py --live
Uses two owned temporary browser profiles and local forms. The random source
value is absent from the task prompt. No save button or user window is touched.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import time
import uuid

from browser_acceptance import BrowserFixture, CHROME, accepted, control
from computer_acceptance import native
from screenshot_acceptance import png_dimensions

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from llm import semantic_snapshot

EDGE = pathlib.Path("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
SUFFIX = "｜跨应用协作完成"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def changes(before, after):
    """Record exact semantic changes without relaxing the production comparison."""
    a, b = semantic_snapshot(before), semantic_snapshot(after)
    output = []
    for field in ("window_title", "window_bounds", "complete"):
        if a[field] != b[field]:
            output.append({"field": field, "before": a[field], "after": b[field]})
    for index in range(max(len(a["nodes"]), len(b["nodes"]))):
        old = a["nodes"][index] if index < len(a["nodes"]) else None
        new = b["nodes"][index] if index < len(b["nodes"]) else None
        if old != new:
            output.append({"node_index": index, "before": old, "after": new})
    return output


def await_form(observe, expected_note, expected_title, timeout=15):
    """Confirm asynchronous AX dispatch by bounded reads; never send an action."""
    deadline = time.monotonic() + timeout
    while True:
        snapshot = observe()
        if snapshot["complete"]:
            require(control(snapshot, "title")["value"] == expected_title, "Initialization changed the title field")
            if control(snapshot, "note")["value"] == expected_note:
                return snapshot
        require(time.monotonic() < deadline, "Initialization was dispatched but exact note readback did not arrive")
        time.sleep(0.1)


def save_events(directory):
    """Keep valid events even if a failed or cancelled process left a partial line."""
    source = directory / "llm-stdout.jsonl"
    events, errors = [], []
    if source.exists():
        for line_number, line in enumerate(source.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                events.append(json.loads(line))
            except ValueError as error:
                errors.append({"line": line_number, "error": str(error), "raw": line})
    (directory / "llm-events.json").write_text(json.dumps(events, ensure_ascii=False, indent=2))
    if errors:
        (directory / "llm-event-errors.json").write_text(json.dumps(errors, ensure_ascii=False, indent=2))
    return events, errors


def operation_result(snapshot, token):
    """Read the fixture's synchronous result through its labelled AX subtree."""
    nodes = snapshot["nodes"]
    groups = [node for node in nodes if node.get("role") == "AXGroup"
              and any(node.get(field) == "最近操作结果" for field in ("title", "label", "description"))]
    require(len(groups) == 1, "Expected one recent-operation result group")
    by_id = {node["id"]: node for node in nodes}
    records = []
    for node in nodes:
        parent = node.get("parent_id")
        visited = set()
        while parent in by_id and parent not in visited and parent != groups[0]["id"]:
            visited.add(parent)
            parent = by_id[parent].get("parent_id")
        if parent == groups[0]["id"] and node.get("role") == "AXStaticText":
            try:
                record = json.loads(node.get("value", ""))
            except ValueError:
                continue
            if isinstance(record, dict):
                records.append(record)
    require(len(records) == 1, "Expected one JSON record in the recent-operation AX subtree")
    require(records[0].get("run_token") == token, "Recent-operation result belongs to another fixture")
    return records[0]


def run(dlm_path):
    require(CHROME.is_file() and EDGE.is_file(), "Google Chrome and Microsoft Edge must be installed")
    require(dlm_path.is_file(), "The selected DeskLoom CLI must exist")
    directory = ROOT / "evidence" / ("cross-app-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    result = {"outcome": "failed", "evidence": str(directory), "transport": "real Codex LLM -> DeskLoom -> macOS AX",
              "dlm_executable": str(dlm_path)}
    fixtures, selected, owned = [], [], set()
    state_samples, observations, stability_changes, phases = [], [], [], []
    initialization_receipts = []
    process = None
    streams = []
    baseline_ids = set()
    baseline = None
    started = time.monotonic()

    def phase(name, **details):
        row = {"phase": name, "elapsed_seconds": round(time.monotonic() - started, 3), **details}
        phases.append(row)
        with (directory / "phases.jsonl").open("a") as log:
            log.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(json.dumps(row, ensure_ascii=False), flush=True)

    def sample_state(label):
        state = native("status")
        capabilities = native("computer_capabilities")
        ui = native("ui_state")
        row = {"phase": label, "elapsed_seconds": round(time.monotonic() - started, 3),
               "status": state, "capabilities": capabilities, "ui": ui}
        state_samples.append(row)
        # The only sessions discovered this way that we may later clean up
        # belong to exact windows in our newly launched, owned browser PIDs.
        targets = {(window["pid"], window["window_id"]) for window in selected}
        for session in state.get("sessions", []):
            if (session.get("pid"), session.get("window_id")) in targets:
                owned.add(session["session_id"])
        return row

    def matches_count(row, expected):
        ui, state, capabilities = row["ui"], row["status"], row["capabilities"]
        session_ids = {session["session_id"] for session in state.get("sessions", [])}
        require(baseline_ids <= session_ids, "A pre-existing session changed during acceptance")
        return (state["controlled_window_count"] == capabilities["controlled_window_count"] == expected
                and ui["controlledWindowCount"] == expected and ui["statusTitle"] == str(expected)
                and ui["statusIconVisible"] and not ui["statusThumbnailVisible"])

    def menu_count(expected, label):
        deadline = time.monotonic() + 5
        while True:
            row = sample_state(label)
            if matches_count(row, expected):
                return row
            require(time.monotonic() < deadline, f"Menu count did not reach {expected}")
            time.sleep(0.1)

    def observe(index, sid, label):
        snapshot = native("computer_observe", {"session_id": sid, "max_nodes": 1000, "max_depth": 40})
        expected = selected[index]
        require(snapshot["session_id"] == sid and snapshot["app"]["pid"] == expected["pid"]
                and snapshot["app"]["bundle_id"] == expected["bundle_id"]
                and snapshot["window"]["window_id"] == expected["window_id"], "Observation identity changed")
        observations.append({"phase": label, "elapsed_seconds": round(time.monotonic() - started, 3),
                             "app": index, "snapshot": snapshot})
        return snapshot

    def attach(index):
        window = selected[index]
        response = native("computer_attach", {"pid": window["pid"], "window_id": window["window_id"]})
        owned.add(response["session_id"])
        return response["session_id"]

    def detach(sid):
        native("computer_detach", {"session_id": sid})
        owned.discard(sid)

    def complete_observation(index, sid, label):
        deadline = time.monotonic() + 20
        while True:
            snapshot = observe(index, sid, label)
            if snapshot["complete"]:
                control(snapshot, "title")
                control(snapshot, "note")
                return snapshot
            require(time.monotonic() < deadline, "Browser AX tree did not become complete")
            time.sleep(0.2)

    def screenshot(index, sid):
        picture = native("computer_screenshot", {"session_id": sid, "max_width": 1200})
        require(picture["session_id"] == sid and picture["window_id"] == selected[index]["window_id"],
                "Screenshot identity differs from the verified window")
        png = base64.b64decode(picture["data"], validate=True)
        digest = hashlib.sha256(png).hexdigest()
        require(digest == picture["sha256"], "Screenshot checksum differs")
        width, height = png_dimensions(png)
        require([width, height] == [picture["width"], picture["height"]], "Screenshot dimensions differ")
        path = directory / ("source-chrome.png" if index == 0 else "destination-edge.png")
        path.write_bytes(png)
        return {**{key: value for key, value in picture.items() if key != "data"}, "path": str(path)}

    try:
        phase("preflight")
        initial = sample_state("baseline")
        baseline = initial["capabilities"]["controlled_window_count"]
        baseline_ids = {session["session_id"] for session in initial["status"].get("sessions", [])}
        require(len(baseline_ids) == baseline <= 6, "Two free control slots and a consistent baseline are required")
        require(initial["status"]["accessibility"] and initial["status"]["screen_recording"], "Both native permissions are required")
        menu_count(baseline, "baseline-verified")
        result.update(existing_sessions=baseline, baseline_session_ids=sorted(baseline_ids))

        phase("launch-owned-browsers")
        definitions = [(CHROME, "com.google.Chrome", "source"), (EDGE, "com.microsoft.edgemac", "destination")]
        for executable, bundle_id, role in definitions:
            app_directory = directory / role
            app_directory.mkdir()
            fixture = BrowserFixture(app_directory, role + "-" + uuid.uuid4().hex, executable=executable)
            fixtures.append(fixture)
            fixture.start()
            deadline = time.monotonic() + 30
            while True:
                require(fixture.process.poll() is None, f"Owned {role} browser exited")
                windows = native("computer_windows", {"pid": fixture.process.pid})["windows"]
                require(all(window["pid"] == fixture.process.pid for window in windows), "Enumeration escaped the owned PID")
                found = [window for window in windows if fixture.token in window.get("title", "")]
                require(len(found) <= 1, "Owned browser window title is ambiguous")
                if found:
                    window = found[0]
                    require(window["bundle_id"] == bundle_id, "Browser bundle ID differs from the expected real application")
                    selected.append(window)
                    break
                require(time.monotonic() < deadline, f"Owned {role} browser window was not found")
                time.sleep(0.2)
        require(selected[0]["pid"] != selected[1]["pid"]
                and selected[0]["bundle_id"] != selected[1]["bundle_id"], "Cross-app acceptance requires different real applications")
        result["applications"] = selected

        phase("initialize-owned-form-values")
        setup_sessions = [attach(index) for index in range(2)]
        menu_count(baseline + 2, "setup-two")
        nonce = uuid.uuid4().hex
        source_value = "跨应用中文校验串：" + nonce
        expected_values = [source_value, ""]
        titles = []
        for index, sid in enumerate(setup_sessions):
            before = complete_observation(index, sid, "before-initialization")
            titles.append(control(before, "title")["value"])
            note = control(before, "note")
            request = {"session_id": sid, "snapshot_id": before["snapshot_id"],
                       "node_id": note["id"], "request_id": str(uuid.uuid4()),
                       "action": "set_value", "value": expected_values[index]}
            receipt = native("computer_act", request)
            initialization_receipts.append({"app": index, "request": request, "receipt": receipt})
            # A browser may acknowledge AX dispatch before updating its value.
            # Save the original receipt, reject unknown/replayed outcomes, then
            # only read until the exact value appears. Never resend the write.
            (directory / "initialization-receipts.json").write_text(json.dumps(initialization_receipts, ensure_ascii=False, indent=2))
            accepted(receipt, require_complete=False)
            await_form(lambda: observe(index, sid, "initialization-readback"), expected_values[index], titles[index])

        phase("observe-browser-stability", minimum_seconds=25)
        stable_start = stable_since = time.monotonic()
        previous = [None, None]
        while True:
            complete = True
            for index, sid in enumerate(setup_sessions):
                current = observe(index, sid, "stability")
                complete = complete and current["complete"]
                if previous[index] is not None:
                    difference = changes(previous[index], current)
                    if difference:
                        stable_since = time.monotonic()
                        stability_changes.append({"app": index, "elapsed_seconds": round(time.monotonic() - stable_start, 3),
                                                  "changes": difference})
                if current["complete"]:
                    require(control(current, "note")["value"] == expected_values[index]
                            and control(current, "title")["value"] == titles[index], "Fixture values changed while waiting for stability")
                previous[index] = current
            now = time.monotonic()
            if complete and now - stable_start >= 25 and now - stable_since >= 5:
                break
            require(now - stable_start < 75, "Browser AX semantics did not stabilize")
            time.sleep(1)
        result["stability"] = {"observed_seconds": round(time.monotonic() - stable_start, 3),
                               "changes_recorded": len(stability_changes), "production_comparison": "semantic_snapshot"}
        for sid in setup_sessions:
            detach(sid)
        menu_count(baseline, "before-llm")

        prompt = (f"请从 Google Chrome 中标题含『{fixtures[0].token}』的源窗口读取『任务备注』字段，"
                  f"把完整内容填写到 Microsoft Edge 中标题含『{fixtures[1].token}』的目标窗口的『任务备注』字段，"
                  f"并在末尾追加『{SUFFIX}』。只填写目标备注，不改变任何『任务标题』字段，不改变源窗口内容，"
                  "不添加换行，不点击保存或重置，不切换页面或关闭窗口；最后重新读取两边确认结果。")
        require(source_value not in prompt and nonce not in prompt, "Source value leaked into the task prompt")
        (directory / "task-prompt.txt").write_text(prompt)
        result.update(prompt_excludes_source_value=True, source_value=source_value, expected_destination=source_value + SUFFIX)
        command = [sys.executable, str(dlm_path), "llm", "run", "--json", "--prompt-stdin",
                   "--db-path", str(directory / "llm-xtdb"), "--timeout", "360", "--max-steps", "6"]
        for window in selected:
            command += ["--window", f"{window['pid']}:{window['window_id']}"]
        require(nonce not in json.dumps(command), "Source value leaked into process arguments")
        stdout = (directory / "llm-stdout.jsonl").open("w")
        stderr = (directory / "llm-stderr.log").open("w")
        streams.extend([stdout, stderr])
        phase("run-real-llm", source_bundle=selected[0]["bundle_id"], destination_bundle=selected[1]["bundle_id"])
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, text=True)
        process.stdin.write(prompt)
        process.stdin.close()
        process.stdin = None
        deadline = time.monotonic() + 540
        saw_two = False
        while process.poll() is None:
            sample = sample_state("llm-running")
            if matches_count(sample, baseline + 2):
                controlled = {(row.get("pid"), row.get("window_id")) for row in sample["status"]["sessions"]}
                require(all((window["pid"], window["window_id"]) in controlled for window in selected), "Count two did not refer to both selected applications")
                if not saw_two:
                    phase("llm-controls-both-applications", actual_menu_count=baseline + 2)
                saw_two = True
            require(time.monotonic() < deadline, "LLM process exceeded its task and cleanup deadline")
            time.sleep(0.25)
        for stream in streams:
            stream.flush()
        events, event_errors = save_events(directory)
        # A failed completion check may follow a real write. Preserve the final
        # window state before declaring failure and closing the owned browsers.
        # Independent evidence never turns a failed LLM run into a passing run.
        completed = bool(events and isinstance(events[-1], dict) and events[-1].get("type") == "completed")
        llm_failures = []
        if event_errors:
            llm_failures.append("LLM event stream contained malformed JSON")
        if process.returncode != 0:
            llm_failures.append(f"LLM exited with code {process.returncode}")
        if not completed:
            llm_failures.append("LLM did not report completion")
        if not saw_two:
            llm_failures.append("Did not observe both real applications under LLM control")
        if llm_failures:
            result["llm_failure"] = {"exit_code": process.returncode, "completed": completed,
                                     "reasons": llm_failures, "event_parse_errors": event_errors,
                                     "error_events": [event for event in events
                                                      if isinstance(event, dict) and event.get("type") == "error"]}
            phase("llm-failed-collecting-evidence", reasons=llm_failures)
        result["llm_saw_both_applications"] = saw_two
        menu_count(baseline, "llm-cleaned-up")
        owned.clear()

        phase("independent-native-readback")
        verification = [attach(index) for index in range(2)]
        menu_count(baseline + 2, "verification-two")
        readbacks = [complete_observation(index, sid, "independent-readback") for index, sid in enumerate(verification)]
        (directory / "independent-readbacks.json").write_text(json.dumps(readbacks, ensure_ascii=False, indent=2))

        phase("capture-verification-evidence")
        result["screenshots"] = [screenshot(index, sid) for index, sid in enumerate(verification)]
        menu_count(baseline + 2, "before-menu-render")
        rendered = native("render_ui")
        menu_path = directory / f"menu-count-{baseline + 2}.png"
        shutil.copyfile(rendered["status-item"], menu_path)
        menu_png = menu_path.read_bytes()
        result["menu_render"] = {"path": str(menu_path), "sha256": hashlib.sha256(menu_png).hexdigest(),
                                 "dimensions": png_dimensions(menu_png), "count": baseline + 2,
                                 "stage": "independent verification after LLM exit"}
        menu_count(baseline + 2, "after-menu-render")

        # Keep screenshots/menu evidence even when the final values are wrong.
        require([control(snapshot, "note")["value"] for snapshot in readbacks] == [source_value, source_value + SUFFIX], "Independent source/destination readback differs")
        require([control(snapshot, "title")["value"] for snapshot in readbacks] == titles, "A title field was changed")
        visible_results = [operation_result(snapshot, fixture.token) for snapshot, fixture in zip(readbacks, fixtures)]
        result["visible_operation_results"] = visible_results
        require(all(record.get("event") == "initial" and record.get("event_sequence") == 0
                    and record.get("revision") == 0 for record in visible_results),
                "A page's visible result shows a save or reset during the copy-only task")
        require(all(not fixture.events for fixture in fixtures), "A save or reset occurred despite the copy-only task")
        result.update(source_unchanged=True, destination_verified=True, title_fields_unchanged=True, no_save_or_reset=True)

        detach(verification[0])
        menu_count(baseline + 1, "verification-one")
        remaining = complete_observation(1, verification[1], "remaining-destination")
        require(control(remaining, "note")["value"] == source_value + SUFFIX, "Detaching source affected destination")
        detach(verification[1])
        menu_count(baseline, "verification-zero")
        require(not llm_failures, {"llm_failure": result.get("llm_failure")})
        result.update(outcome="passed", menu_counts=[baseline + 2, baseline + 1, baseline], owned_session_counts=[2, 1, 0],
                      llm_saw_both_applications=saw_two)
        phase("passed")
    except (Exception, KeyboardInterrupt) as error:
        result["error"] = str(error) or type(error).__name__
        phase("failed", error=result["error"])
    finally:
        cleanup_errors = []
        if process is not None and process.poll() is None:
            try:
                process.terminate()
                process.wait(timeout=180)
            except Exception as error:
                cleanup_errors.append("LLM cleanup: " + str(error))
                try:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=5)
                except Exception as kill_error:
                    cleanup_errors.append("LLM forced cleanup: " + str(kill_error))
        for stream in streams:
            try:
                stream.close()
            except Exception as error:
                cleanup_errors.append("Log cleanup: " + str(error))
        try:
            _, event_errors = save_events(directory)
            if event_errors:
                result["llm_event_parse_errors"] = event_errors
        except Exception as error:
            cleanup_errors.append("LLM event evidence: " + str(error))
        if selected:
            try:
                sample_state("cleanup-discovery")
                active = {session["session_id"] for session in native("status")["sessions"]}
                for sid in sorted(owned & active):
                    try:
                        detach(sid)
                    except Exception as error:
                        cleanup_errors.append("Session cleanup: " + str(error))
            except Exception as error:
                cleanup_errors.append("Session discovery: " + str(error))
        for fixture in reversed(fixtures):
            try:
                fixture.close()
            except Exception as error:
                cleanup_errors.append("Owned browser cleanup: " + str(error))
            finally:
                (fixture.directory / "browser-events.json").write_text(json.dumps(fixture.events, ensure_ascii=False, indent=2))
        if baseline is not None:
            try:
                menu_count(baseline, "final-baseline")
            except Exception as error:
                cleanup_errors.append("Baseline check: " + str(error))
        if cleanup_errors:
            result.update(outcome="failed", cleanup_errors=cleanup_errors)
        for name, data in (("state-samples.json", state_samples), ("observations.json", observations),
                           ("stability-changes.json", stability_changes), ("phases.json", phases),
                           ("initialization-receipts.json", initialization_receipts)):
            (directory / name).write_text(json.dumps(data, ensure_ascii=False, indent=2))
        result["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (directory / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
    return 0 if result["outcome"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--dlm", type=pathlib.Path, default=ROOT / "scripts/dlm",
                        help="CLI to validate; may point to the signed installed app's Resources/dlm")
    args = parser.parse_args()
    sys.exit(run(args.dlm.resolve()))
