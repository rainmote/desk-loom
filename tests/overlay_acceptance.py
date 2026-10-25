#!/usr/bin/env python3
"""Opt-in overlay ordering acceptance against the running DeskLoom application.

Run: python3 tests/overlay_acceptance.py --live
Creates two owned WindowLab windows, performs 20 real native focus actions, and
requires at most two ordering calls per marker per action. Actions are sent once;
only observation and UI-state polling may repeat. No user document is opened.
"""
import argparse
import json
import pathlib
import plistlib
import sys
import time
import uuid

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import rpc
from fixtures.window_lab import WindowLab

FOCUS_CYCLES = 20
MAX_ORDER_CHANGES = 2
POLL_INTERVAL = 0.05
IDENTITY_FIELDS = ("sessionID", "windowNumber", "targetWindowID", "targetProcessID")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def native(method, params=None):
    response = rpc.call(method, params)
    require(response["ok"], {"method": method, "response": response})
    return response["result"]


def ui_sample():
    state = native("ui_state")
    return {"monotonic": time.monotonic(),
            "controlledWindowCount": state["controlledWindowCount"],
            "statusTitle": state["statusTitle"],
            "statusIconVisible": state["statusIconVisible"],
            "statusThumbnailVisible": state["statusThumbnailVisible"],
            "overlays": sorted(state["overlays"], key=lambda row: row["sessionID"])}


def menu_matches(sample, session_ids):
    rows = sample["overlays"]
    return (sample["controlledWindowCount"] == len(session_ids)
            and sample["statusTitle"] == str(len(session_ids))
            and sample["statusIconVisible"] is True
            and sample["statusThumbnailVisible"] is False
            and len(rows) == len(session_ids)
            and {row["sessionID"] for row in rows} == set(session_ids))


def wait_menu(session_ids, samples, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        sample = ui_sample()
        samples.append(sample)
        if menu_matches(sample, session_ids):
            return sample
        require(time.monotonic() < deadline, "Menu or overlay count did not settle to " + str(len(session_ids)))
        time.sleep(POLL_INTERVAL)


def stable_key(sample):
    return {key: value for key, value in sample.items() if key != "monotonic"}


def wait_stable(session_ids, samples, minimum=0.45, timeout=5):
    """Read at least two 0.2-second overlay timer periods, then require quiet."""
    started = last_changed = time.monotonic()
    previous = None
    while True:
        sample = ui_sample()
        samples.append(sample)
        current = stable_key(sample)
        now = time.monotonic()
        if current != previous:
            last_changed = now
            previous = current
        if menu_matches(sample, session_ids) and now - started >= minimum and now - last_changed >= 0.25:
            return sample
        require(now - started < timeout, "Overlay ordering or geometry did not settle within the deadline")
        time.sleep(POLL_INTERVAL)


def validate_markers(sample, original, fixture_pid):
    require(menu_matches(sample, original), "Controlled count, menu or session ownership changed")
    require(len({row["targetWindowID"] for row in sample["overlays"]}) == len(original),
            "Two sessions share the same native target window")
    for row in sample["overlays"]:
        before = original[row["sessionID"]]
        require(row["visible"] is True and row["visibilityReason"] == "visible" and row["label"] == "控制中",
                {"error": "An attached marker became hidden", "marker": row})
        require(row["targetProcessID"] == fixture_pid and type(row["targetWindowID"]) is int,
                "Marker does not belong to the owned fixture")
        for key in IDENTITY_FIELDS + ("visibilityChanges", "frameChanges", "frame"):
            require(row[key] == before[key], {"error": "Marker changed " + key, "before": before, "after": row})


def validate_observation(observation, session_id, window, fixture):
    require(observation["session_id"] == session_id and observation["complete"] is True,
            "Observation is incomplete or belongs to another session")
    require(observation["app"]["pid"] == fixture.process.pid
            and observation["app"]["bundle_id"] == fixture.bundle_id
            and observation["window"]["window_id"] == window["window_id"]
            and observation["window"]["title"] == window["title"],
            "Observation does not match the owned WindowLab window")


def run():
    directory = ROOT / "evidence" / ("overlay-acceptance-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    report = {"outcome": "failed", "focus_cycles": FOCUS_CYCLES,
              "max_order_changes_per_marker_per_focus": MAX_ORDER_CHANGES,
              "focus": [], "menu_transitions": [], "cleanup": [], "evidence": str(directory)}
    fixture = None
    owned = []
    detach_attempted = set()
    baseline = None
    verified = False

    def detach_once(session_id):
        # A transport failure may have occurred after dispatch. Never resend it.
        require(session_id in owned and session_id not in detach_attempted, "Invalid repeated detach")
        detach_attempted.add(session_id)
        event = {"action": "detach", "session_id": session_id}
        report["cleanup"].append(event)
        try:
            event["receipt"] = native("computer_detach", {"session_id": session_id})
        except (Exception, KeyboardInterrupt) as error:
            event["error"] = str(error)
            raise

    try:
        status = native("status")
        baseline = status["controlled_window_count"]
        report["baseline_count"] = baseline
        report["application"] = status.get("controller_application_path")
        require(baseline == 0 and not status.get("sessions"),
                "Run this isolated check only when no user control session is active")
        if report["application"]:
            info = pathlib.Path(report["application"]) / "Contents/Info.plist"
            with info.open("rb") as stream:
                plist = plistlib.load(stream)
            report["application_version"] = plist.get("CFBundleShortVersionString")
            report["application_build"] = plist.get("CFBundleVersion")
        fixture = WindowLab()
        fixture.start()
        report["fixture"] = {"pid": fixture.process.pid, "bundle_id": fixture.bundle_id, "titles": fixture.titles}
        windows = fixture.select_windows(native)
        for window in windows:
            attached = native("computer_attach", {"pid": window["pid"], "window_id": window["window_id"]})
            owned.append(attached["session_id"])
        report["owned_sessions"] = list(owned)
        report["initial_samples"] = []
        initial = wait_stable(owned, report["initial_samples"], minimum=1.5)
        original = {row["sessionID"]: row for row in initial["overlays"]}
        validate_markers(initial, original, fixture.process.pid)
        report["initial"] = initial
        report["menu_transitions"].append({"expected_count": 2, "sample": initial})

        for index in range(FOCUS_CYCLES):
            session_id = owned[index % 2]
            window = windows[index % 2]
            entry = {"index": index + 1, "session_id": session_id, "samples": []}
            report["focus"].append(entry)
            observation = native("computer_observe", {"session_id": session_id})
            validate_observation(observation, session_id, window, fixture)
            before = ui_sample()
            entry["before"] = before
            validate_markers(before, original, fixture.process.pid)
            request_id = str(uuid.uuid4())
            entry["request_id"] = request_id
            # Exactly one dispatch, including when the outcome is unknown.
            receipt = native("computer_act", {"session_id": session_id, "snapshot_id": observation["snapshot_id"],
                                               "request_id": request_id, "action": "focus"})
            entry["receipt"] = receipt
            require(receipt["session_id"] == session_id and receipt["request_id"] == request_id
                    and receipt["outcome"] in ("dispatched", "verified"),
                    "Focus action did not return a known accepted result; it was not retried")
            # The action receipt can precede activation. Confirm by bounded reads.
            deadline = time.monotonic() + 3
            entry["focus_readbacks"] = []
            while True:
                readback = native("computer_observe", {"session_id": session_id})
                validate_observation(readback, session_id, window, fixture)
                entry["focus_readbacks"].append({"monotonic": time.monotonic(), "focused": readback["focused"],
                                                  "session_id": session_id, "window_id": window["window_id"]})
                if readback["focused"] is True:
                    break
                require(time.monotonic() < deadline, "Accepted focus did not become effective; it was not retried")
                time.sleep(POLL_INTERVAL)
            try:
                after = wait_stable(owned, entry["samples"])
            finally:
                # Retain the last read and its deltas even when settling fails.
                if entry["samples"]:
                    entry["after"] = entry["samples"][-1]
                    before_rows = {row["sessionID"]: row for row in before["overlays"]}
                    entry["deltas"] = {row["sessionID"]: {
                        key: row[key] - before_rows[row["sessionID"]][key]
                        for key in ("orderChanges", "visibilityChanges", "frameChanges")}
                        for row in entry["after"]["overlays"] if row["sessionID"] in before_rows}
            for sample in entry["samples"]:
                validate_markers(sample, original, fixture.process.pid)
            for session, delta in entry["deltas"].items():
                require(0 <= delta["orderChanges"] <= MAX_ORDER_CHANGES,
                        {"error": "Excessive ordering during one focus", "focus": index + 1,
                         "session_id": session, "delta": delta, "maximum": MAX_ORDER_CHANGES})

        report["stable_samples"] = []
        stable = ui_sample()
        report["stable_before"] = stable
        for _ in range(20):
            time.sleep(POLL_INTERVAL)
            sample = ui_sample()
            report["stable_samples"].append(sample)
            validate_markers(sample, original, fixture.process.pid)
            require(stable_key(sample) == stable_key(stable), "Idle markers continued reordering or moving")

        # Verify the real menu follows each individual session release: 2 -> 1 -> 0.
        for index, session_id in enumerate(owned):
            detach_once(session_id)
            samples = []
            transition = {"expected_count": len(owned) - index - 1, "samples": samples}
            report["menu_transitions"].append(transition)
            transition["sample"] = wait_menu(owned[index + 1:], samples)
            validate_markers(transition["sample"],
                             {sid: original[sid] for sid in owned[index + 1:]}, fixture.process.pid)
        verified = True
    except (Exception, KeyboardInterrupt) as error:
        report["error"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        # Every cleanup attempt is scoped to a returned session ID. One failure
        # must not prevent other owned sessions or the fixture from being closed.
        for session_id in owned:
            if session_id not in detach_attempted:
                try:
                    detach_once(session_id)
                except (Exception, KeyboardInterrupt):
                    pass  # The failed attempt is retained in report["cleanup"].
        if fixture is not None:
            try:
                fixture.close()
                report["fixture_closed"] = True
            except Exception as error:
                report["cleanup"].append({"action": "close_fixture", "error": str(error)})
        if baseline == 0:
            try:
                samples = []
                report["final_samples"] = samples
                final = wait_menu([], samples)
                status = native("status")
                require(status["controlled_window_count"] == 0 and not status.get("sessions"),
                        "Native sessions remained after owned fixture cleanup")
                report["final_count"] = final["controlledWindowCount"]
            except Exception as error:
                report["cleanup"].append({"action": "verify_final_state", "error": str(error)})
        if verified and not any("error" in event for event in report["cleanup"]):
            report["outcome"] = "passed"
        (directory / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"outcome": report["outcome"], "evidence": str(directory),
                          "completed_focus_cycles": sum("after" in entry for entry in report["focus"]),
                          "final_count": report.get("final_count"), "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["outcome"] == "passed" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="explicitly allow launching two owned test windows")
    args = parser.parse_args(argv)
    if not args.live:
        parser.error("--live is required; no application was launched and no RPC was sent")
    return run()


if __name__ == "__main__":
    sys.exit(main())
