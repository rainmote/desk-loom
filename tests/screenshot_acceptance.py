#!/usr/bin/env python3
"""Opt-in screenshot reliability regression through the registered Codex MCP.

Run: python3 tests/screenshot_acceptance.py --live
The fixed sample plan defaults to three independent Chrome launches, each with
one immediate capture, one after a real form save, and five repeated captures.
The first launch has a short title; the remaining launches have deliberately
long titles to exercise ScreenCaptureKit's middle-title elision.
One Codex MCP runtime keeps XTDB warm across launches. A failed capture is never
retried or discarded; later planned captures still run. Any non-capture failure
stops the run without replaying an uncertain action. Only temporary profiles and
their own process groups are created/closed; existing windows are not focused.
"""
import argparse
import base64
import hashlib
import json
import math
import struct
import sys
import time
import uuid
import zlib
from collections import Counter

from browser_acceptance import (CHROME, LABELS, ROOT, BrowserFixture, CodexMCP,
                                await_visible, compact_records, control, measure_workflow,
                                native_status, require)


def png_dimensions(data):
    """Check the actual PNG header/chunks, independently of tool metadata."""
    require(data.startswith(b"\x89PNG\r\n\x1a\n"), "Screenshot is not a PNG")
    offset, dimensions, has_pixels, has_end = 8, None, False, False
    while offset < len(data):
        require(offset + 12 <= len(data), "Truncated PNG chunk")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        require(end <= len(data), "Truncated PNG payload")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length:end])[0]
        require(zlib.crc32(kind + payload) & 0xffffffff == expected_crc,
                "PNG chunk checksum differs")
        if dimensions is None:
            require(kind == b"IHDR" and length == 13, "PNG has no initial IHDR")
            dimensions = struct.unpack(">II", payload[:8])
            require(all(0 < value <= 2048 for value in dimensions), "PNG size exceeds capture bounds")
        elif kind == b"IHDR":
            raise AssertionError("PNG has multiple IHDR chunks")
        if kind == b"IDAT" and length:
            has_pixels = True
        if kind == b"IEND":
            require(length == 0 and end == len(data), "PNG has invalid end or trailing bytes")
            has_end = True
        offset = end
    require(dimensions is not None and has_pixels and has_end, "PNG is missing image data or end")
    return dimensions


def snapshot_identity(snapshot):
    """Keep URL and foreground evidence even when absent from window metadata."""
    window = snapshot.get("window", {})
    urls = sorted({node["url"] for node in snapshot.get("nodes", [])
                   if node.get("role") == "AXWebArea" and node.get("url")})
    return {"session_id": snapshot.get("session_id"), "snapshot_id": snapshot.get("snapshot_id"),
            "captured_at": snapshot.get("captured_at"),
            "capture_finished_at": snapshot.get("capture_finished_at"),
            "complete": snapshot.get("complete"), "focused": snapshot.get("focused"),
            "app": snapshot.get("app"), "window": window,
            "webarea_urls": urls, "memory": snapshot.get("memory")}


def structured_error(record):
    """Preserve native diagnostics from an MCP failure, not only its string."""
    response = record.get("response", {})
    result = response.get("result", {})
    parsed = result.get("structuredContent")
    if not isinstance(parsed, dict):
        for content in result.get("content", []):
            if content.get("type") == "text":
                try:
                    candidate = json.loads(content.get("text", ""))
                except json.JSONDecodeError:
                    continue
                if isinstance(candidate, dict):
                    parsed = candidate
                    break
    return {"mcp_is_error": result.get("isError"), "structured_content": parsed,
            "json_rpc_error": response.get("error")}


def brief_error(message, structured=None):
    """Keep terminal output small; full native diagnostics remain in JSON/wire."""
    if not isinstance(structured, dict):
        # CodexMCP exceptions may carry the structured error after a prefix.
        opening = str(message).find("{")
        if opening >= 0:
            try:
                structured = json.loads(str(message)[opening:])
            except json.JSONDecodeError:
                pass
    if isinstance(structured, dict) and isinstance(structured.get("error"), dict):
        structured = structured["error"]
    if isinstance(structured, dict):
        code, short_message = structured.get("code"), structured.get("message")
    else:
        code, short_message = None, None
    lines = str(short_message or message).splitlines()
    return {"error_code": code, "error_message": lines[0][:200] if lines else ""}


def capture_coverage(samples):
    """Count verified samples only; a returned image with bad metadata is not coverage."""
    passed = [sample for sample in samples if sample["outcome"] == "passed"]
    modes = dict(Counter(sample["capture_match_mode"] for sample in passed))
    coverage = {"short_title_exact_or_suffix": any(
                    sample["title_case"] == "short" and sample["capture_match_mode"] in
                    ("exact_title", "application_suffix") for sample in passed),
                "long_title_middle_ellipsis": any(
                    sample["title_case"] == "long" and sample["capture_match_mode"] == "middle_ellipsis"
                    for sample in passed)}
    return modes, coverage


def validate_picture(picture, fixture, expected, max_width, png):
    require(picture.get("mime_type") == "image/png", "Screenshot MIME type differs")
    require(hashlib.sha256(png).hexdigest() == picture["sha256"], "Screenshot hash mismatch")
    dimensions = png_dimensions(png)
    require(dimensions == (picture["width"], picture["height"]), "PNG dimensions differ from metadata")
    require(dimensions[0] <= max_width, "Screenshot exceeds requested width")
    snapshot = picture["observation"]
    identity = snapshot_identity(snapshot)
    require(snapshot["complete"], "Screenshot observation is incomplete")
    require(picture["session_id"] == snapshot["session_id"] == expected["session_id"],
            "Screenshot session differs from attached fixture")
    require(picture["window_id"] == snapshot["window"]["id"] == expected["window"]["id"],
            "Screenshot window differs from attached fixture")
    require(snapshot["app"]["pid"] == expected["app"]["pid"] == fixture.process.pid,
            "Screenshot PID differs from owned Chrome")
    require(snapshot["app"]["bundle_id"] == "com.google.Chrome", "Screenshot app differs")
    require(fixture.token in snapshot["window"]["title"], "Screenshot target title lacks run token")
    require(identity["webarea_urls"] == [fixture.url], "Screenshot target URL differs")
    bounds = picture["window_bounds"]
    observed_bounds = snapshot["window"]["bounds"]
    for key in ("x", "y", "width", "height"):
        require(isinstance(bounds[key], (int, float)) and math.isfinite(bounds[key]),
                "Screenshot bounds are invalid")
        require(math.isclose(bounds[key], observed_bounds[key], abs_tol=0.01, rel_tol=0),
                "Screenshot bounds differ from associated observation: " + key)
    require(bounds["width"] > 0 and bounds["height"] > 0, "Screenshot bounds are empty")
    require(picture["coordinate_space"] == "desktop_points", "Unexpected screenshot coordinates")
    require(math.isclose(picture["scale_x"], dimensions[0] / bounds["width"], abs_tol=1e-9),
            "Screenshot scale_x differs from PNG dimensions")
    require(math.isclose(picture["scale_y"], dimensions[1] / bounds["height"], abs_tol=1e-9),
            "Screenshot scale_y differs from PNG dimensions")
    match = picture.get("capture_match")
    require(isinstance(match, dict), "Screenshot is missing capture_match evidence")
    require(match.get("mode") in ("exact_title", "application_suffix", "middle_ellipsis"),
            "Screenshot has an unknown capture match mode")
    require(match.get("ax_state_stable") is True, "Screenshot AX state was not stable")
    require(isinstance(match.get("cg_window_id"), int) and match["cg_window_id"] > 0,
            "Screenshot has no concrete CG window identity")
    if match["mode"] == "middle_ellipsis":
        require(match.get("sc_geometry_candidates") == 1 and match.get("ax_geometry_candidates") == 1,
                "Elided-title screenshot lacks unique SC and AX geometry")
        require(match.get("ax_selected_window_confirmed") is True,
                "Elided-title screenshot did not confirm the attached AX window")
    return dimensions


def capture_sample(client, fixture, sample, snapshot, expected, directory):
    """Exactly one request per predeclared sample, including failures."""
    sample["last_observation_before_call"] = snapshot_identity(snapshot)
    sample["started_monotonic"] = time.perf_counter()
    record_index = len(client.records)
    picture = None
    try:
        try:
            picture = client.call("computer_screenshot", {"max_width": sample["max_width"]})
        finally:
            # Excludes validation, evidence writes and printing.
            sample["external_elapsed_ms"] = (time.perf_counter() - sample["started_monotonic"]) * 1000
        sample["screenshot"] = {key: value for key, value in picture.items()
                                 if key not in ("data", "observation")}
        match = picture.get("capture_match")
        sample["capture_match_mode"] = match.get("mode") if isinstance(match, dict) else None
        candidate_snapshot = picture.get("observation")
        require(isinstance(candidate_snapshot, dict), "Screenshot is missing its observation")
        sample["observation"] = snapshot_identity(candidate_snapshot)
        snapshot = candidate_snapshot
        (directory / (sample["name"] + "-observation.json")).write_text(
            json.dumps(snapshot, ensure_ascii=False, indent=2))
        png = base64.b64decode(picture["data"], validate=True)
        # Preserve an invalid image too, if available, for diagnosis.
        png_path = directory / (sample["name"] + ".png")
        png_path.write_bytes(png)
        sample["image"] = str(png_path)
        sample["png_dimensions"] = validate_picture(picture, fixture, expected, sample["max_width"], png)
        sample["outcome"] = "passed"
    except Exception as error:
        sample["outcome"] = "failed"
        sample["error"] = str(error)
        sample["failure_stage"] = "tool_call" if picture is None else "response_validation"
        if len(client.records) > record_index:
            sample.update(structured_error(client.records[record_index]))
    finally:
        if len(client.records) > record_index:
            sample["tool_record"] = compact_records([client.records[record_index]])[0]
        brief = {key: sample[key] for key in
                 ("launch", "title_case", "name", "max_width", "outcome", "external_elapsed_ms",
                  "capture_match_mode")
                 if key in sample}
        if sample.get("error"):
            brief.update(brief_error(sample["error"], sample.get("structured_content")))
        print(json.dumps(brief, ensure_ascii=False), flush=True)
    return snapshot


def run(launches=3, repeats=5):
    require(CHROME.exists(), "Google Chrome is required for this opt-in test")
    state = native_status()
    require(not state["active"], "Stop the current DeskLoom session before screenshot regression")
    require(state["accessibility"] and state["screen_recording"], "Both native permissions required")
    directory = ROOT / "evidence" / ("screenshots-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    launch_plan = [{"launch": launch, "title_case": "short" if launch == 1 else "long",
                    "run_token": "short-" + uuid.uuid4().hex[:8] if launch == 1
                    else "capture-regression-" + uuid.uuid4().hex}
                   for launch in range(1, launches + 1)]
    samples = []
    for planned in launch_plan:
        schedule = [("immediate", 720), ("after-save", 1100)]
        schedule.extend(("repeat-%02d" % (index + 1), 720 if index % 2 == 0 else 1100)
                        for index in range(repeats))
        samples.extend({"launch": planned["launch"], "title_case": planned["title_case"],
                        "name": name, "max_width": width, "outcome": "not_run"}
                       for name, width in schedule)
    summary = {"outcome": "failed", "evidence": str(directory), "launches": [], "samples": samples,
               "planned_launches": launches, "planned_samples": len(samples),
               "launch_plan": launch_plan,
               "transport": "Codex app-server -> registered DeskLoom MCP -> macOS AX/ScreenCaptureKit",
               "one_mcp_runtime": True, "capture_retries": 0, "includes_llm_latency": False,
               "plan": "First launch short title; remaining launches long titles. Each: immediate 720px, "
                       "after-save 1100px, then alternating 720/1100px repeats"}
    # Write the plan before executing, so an interrupted run cannot lose its denominator.
    (directory / "plan.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    client = fixture = None
    attached = False
    try:
        client = CodexMCP(directory)
        status = client.status()
        require(not status.get("toolsError"), status)
        summary["codex_mcp"] = {key: status.get(key) for key in
                                 ("name", "serverInfo", "runtimeStatus", "toolsError")}
        summary["codex_startup_ms"] = client.startup_ms
        summary["capabilities"] = client.call("computer_capabilities")
        for planned in launch_plan:
            launch, token = planned["launch"], planned["run_token"]
            launch_directory = directory / ("launch-%02d" % launch)
            launch_directory.mkdir()
            fixture = BrowserFixture(launch_directory, token)
            record = {**planned, "url": fixture.url}
            summary["launches"].append(record)
            fixture.start()
            record["pid"] = fixture.process.pid
            matches = []
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                windows = client.call("computer_windows", {"pid": fixture.process.pid})
                require(all(window["pid"] == fixture.process.pid for window in windows["windows"]),
                        "PID-scoped enumeration returned a window outside the owned fixture")
                matches = [window for window in windows["windows"] if token in window.get("title", "")]
                if matches:
                    break
                time.sleep(0.2)
            require(len(matches) == 1, "Owned browser fixture was not uniquely found")
            require(matches[0]["pid"] == fixture.process.pid, "Discovered browser PID differs from owned process")
            session = client.call("computer_attach", {"window_id": matches[0]["window_id"]})
            attached = True
            record["session_id"] = session["session_id"]
            snapshot = client.call("computer_observe", {"max_nodes": 1000, "max_depth": 40})
            for key in LABELS:
                control(snapshot, key)
            expected = snapshot_identity(snapshot)
            record["initial_observation"] = expected
            launch_samples = [sample for sample in samples if sample["launch"] == launch]
            snapshot = capture_sample(client, fixture, launch_samples[0], snapshot, expected, launch_directory)

            # A screenshot performs a new observation even when capture fails.
            # Obtain fresh handles for the one mutation workflow; never replay it.
            snapshot = client.call("computer_observe")
            title, note = "截图回归 " + token[:8], "真实浏览器保存后截图 / capture regression"
            steps = [("title", {"action": "set_value", "value": title}),
                     ("note", {"action": "set_value", "value": note}),
                     ("save", {"action": "click"})]
            record["workflow"], snapshot = measure_workflow(client, fixture, steps, "live_nodes", snapshot)
            record["browser_events"] = fixture.events
            require(len(fixture.events) == 1 and fixture.events[0]["event_sequence"] == 1,
                    "Each fixture must contain exactly one real save")
            # The server receipt arrives before the browser replaces its status
            # text. Wait for that DOM update before the fixed capture samples.
            # All intermediate/incomplete observations remain in the wire log.
            receipt_text = "事件回执：已记录 / Recorded · " + str(fixture.events[-1]["event_sequence"])
            wait_started, wait_record_index = time.perf_counter(), len(client.records)
            snapshot = await_visible(client, snapshot, receipt_text)
            record["receipt_wait"] = {"expected": receipt_text,
                                      "elapsed_ms": (time.perf_counter() - wait_started) * 1000,
                                      "observation_calls": len(client.records) - wait_record_index,
                                      "observation": snapshot_identity(snapshot)}
            for sample in launch_samples[1:]:
                snapshot = capture_sample(client, fixture, sample, snapshot, expected, launch_directory)
            # If detach itself fails, do not explicitly replay an uncertain call.
            # Closing the owned runtime still performs its session-safe cleanup.
            attached = False
            client.call("computer_detach")
            fixture.close()
            fixture = None
            record["closed_owned_browser"] = True
        _, coverage = capture_coverage(samples)
        require(coverage["short_title_exact_or_suffix"],
                "Short-title samples did not verify exact_title or application_suffix matching")
        require(coverage["long_title_middle_ellipsis"],
                "Long-title samples did not verify the middle_ellipsis matching path")
        summary["outcome"] = "passed" if all(sample["outcome"] == "passed" for sample in samples) else "failed"
    except Exception as error:
        summary["error"] = str(error)
    finally:
        cleanup_errors = []
        if client and attached:
            try:
                client.call("computer_detach")
            except Exception as error:
                cleanup_errors.append("Detach: " + str(error))
        if fixture:
            try:
                fixture.close()
            except Exception as error:
                cleanup_errors.append("Owned browser cleanup: " + str(error))
        if client:
            summary["tool_records"] = compact_records(client.records)
            try:
                client.close()
            except Exception as error:
                cleanup_errors.append("Codex cleanup/evidence: " + str(error))
            summary["wire_path"] = str(client.wire_path)
        if cleanup_errors:
            summary["cleanup_errors"] = cleanup_errors
            summary["outcome"] = "failed"
        summary["sample_counts"] = {outcome: sum(sample["outcome"] == outcome for sample in samples)
                                    for outcome in ("passed", "failed", "not_run")}
        summary["capture_match_mode_counts"], summary["capture_match_coverage"] = capture_coverage(samples)
        (directory / "result.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        brief = {key: summary[key] for key in ("outcome", "evidence", "sample_counts",
                                             "capture_match_mode_counts", "capture_match_coverage")}
        if summary.get("error"):
            brief.update(brief_error(summary["error"]))
        if cleanup_errors:
            brief["cleanup_errors"] = [brief_error(error) for error in cleanup_errors]
        print(json.dumps(brief, ensure_ascii=False), flush=True)
    return 0 if summary["outcome"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--launches", type=int, default=3)
    parser.add_argument("--repeats", type=int, default=5)
    args = parser.parse_args()
    require(args.launches >= 3, "At least three independent Chrome launches are required")
    require(args.repeats >= 5, "At least five repeated captures per launch are required")
    sys.exit(run(args.launches, args.repeats))
