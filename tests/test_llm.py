"""Exercise subscription delegation, bounded planner IO and selected-window dispatch."""
import argparse
import copy
import importlib.util
import io
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

PROJECT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("deskloom_llm", PROJECT / "scripts/llm.py")
llm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(llm)


def decision(action=None, window_id="window-42", **fields):
    if action is None:
        return {"kind": "done", "message": "完成", "window_id": None, "action": None}
    params = {key: None for key in llm.ACTION_FIELDS}
    params.update(action=action, modifiers=[])
    params.update(fields)
    return {"kind": "action", "message": "执行 " + action, "window_id": window_id, "action": params}


def snapshot(index=0, value="Before"):
    return {"session_id": "owned-session", "snapshot_id": f"snapshot-{index}",
            "complete": True, "app": {"pid": 42}, "window": {"window_id": "window-42"},
            "window_title": "Fixture", "window_bounds": {"x": 10, "y": 20, "width": 500, "height": 400},
            "focused": True, "nodes": [
                {"id": f"node-{index}", "parent_id": f"parent-{index}", "role": "AXTextArea",
                 "identifier": "fixture-text", "value": value, "enabled": True, "secure": False,
                 "settable": True, "bounds": {"x": 30, "y": 50, "width": 200, "height": 200}},
            ]}


def arguments(**changes):
    values = dict(prompt="将文本改为 After", prompt_stdin=False, pid=42, window_id="window-42",
                  model=None, max_steps=4, timeout=30, db_path=None, endpoint=None)
    values.update(changes)
    return argparse.Namespace(**values)


class FakeAgent:
    def __init__(self, command):
        self.command = command
        self.calls = []
        self.count = 0
        self.value = "Before"
        self.closed = False
        self.owned_sessions = set()
        self.change_session = False
        self.unknown = False
        self.after_plan_changed = False

    def call(self, tool, params, timeout=None):
        self.calls.append((tool, copy.deepcopy(params)))
        self.count += 1
        current = snapshot(self.count, self.value)
        if self.change_session and tool == "computer_observe" and self.count > 2:
            current["session_id"] = "foreign-session"
        if self.after_plan_changed and tool == "computer_observe" and self.count > 2:
            current["nodes"][0]["value"] = "Someone else changed this"
        if tool == "computer_attach":
            return {"session_id": "owned-session", "observation": current}
        if tool == "computer_observe":
            return current
        if tool == "computer_act":
            if params["action"] == "set_value":
                self.value = params["value"]
                current = snapshot(self.count, self.value)
            return {"outcome": "unknown" if self.unknown else "verified", "observation": current}
        raise AssertionError(tool)

    def close(self):
        self.closed = True


class ScriptFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="DeskLoom LLM tests ")
        self.root = pathlib.Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def script(self, name, content):
        path = self.root / name
        path.write_text("#!" + sys.executable + "\n" + content)
        path.chmod(0o755)
        return str(path)


class Authentication(ScriptFixture):
    def test_status_delegates_to_codex_without_reading_or_copying_auth(self):
        codex_home = self.root / "private codex"
        codex_home.mkdir()
        credentials = codex_home / "auth.json"
        credentials.write_text("private-credentials-must-not-be-read")
        original = credentials.stat()
        fake = self.script("codex", 'import sys\nassert sys.argv[1:] == ["login", "status"]\nprint("Logged in using ChatGPT", file=sys.stderr)\n')
        with mock.patch.dict(os.environ, CODEX_HOME=str(codex_home)), mock.patch.object(pathlib.Path, "read_text", side_effect=AssertionError("must not read credentials")):
            result = llm.status(fake)
        self.assertTrue(result["available"])
        self.assertTrue(result["authenticated"])
        self.assertEqual("chatgpt", result["auth_mode"])
        self.assertNotIn("private-credentials", json.dumps(result))
        self.assertEqual(original.st_mtime_ns, credentials.stat().st_mtime_ns)
        self.assertEqual([credentials], list(codex_home.iterdir()))

    def test_api_key_status_is_not_subscription_auth_and_never_echoes_key(self):
        fake = self.script("codex", 'print("Logged in using an API key: sk-private-test-secret")\n')
        result = llm.status(fake)
        self.assertFalse(result["authenticated"])
        self.assertEqual("api_key", result["auth_mode"])
        self.assertNotIn("sk-private", json.dumps(result))

    def test_inherited_api_credentials_removed_but_codex_home_preserved(self):
        with mock.patch.dict(os.environ, CODEX_HOME="/custom/home", OPENAI_API_KEY="secret", CODEX_API_KEY="secret", CODEX_ACCESS_TOKEN="secret"):
            child = llm.child_environment()
        self.assertEqual("/custom/home", child["CODEX_HOME"])
        for name in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"):
            self.assertNotIn(name, child)

    def test_cli_status_emits_exactly_one_json_line(self):
        self.script("codex", 'print("Logged in using ChatGPT")\n')
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"])
        result = subprocess.run([sys.executable, str(PROJECT / "scripts/dlm"), "llm", "status"], env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, len(result.stdout.splitlines()))
        self.assertTrue(json.loads(result.stdout)["authenticated"])


class PlannerContract(ScriptFixture):
    def test_planner_isolated_tools_disabled_and_task_only_in_stdin(self):
        log = self.root / "observed.json"
        fake = self.script("codex", f'''import json, os, pathlib, sys
args = sys.argv[1:]
body = sys.stdin.read()
pathlib.Path({str(log)!r}).write_text(json.dumps({{"argv":args,"cwd":os.getcwd(),"body":json.loads(body),"schema":json.loads(pathlib.Path(args[args.index("--output-schema")+1]).read_text())}}))
print(json.dumps({{"type":"item.completed","item":{{"type":"agent_message","text":json.dumps({decision()!r})}}}}))
print(json.dumps({{"type":"turn.completed"}}))
''')
        result = llm.Planner(fake).decide("PRIVATE TASK 中文", [snapshot()], [], 5)
        observed = json.loads(log.read_text())
        self.assertEqual("done", result["kind"])
        self.assertNotIn("PRIVATE TASK", json.dumps(observed["argv"]))
        self.assertEqual("PRIVATE TASK 中文", observed["body"]["user_task"])
        self.assertEqual([snapshot()], observed["body"]["observed_windows"])
        self.assertIn("window_id", observed["schema"]["required"])
        self.assertIn("--ignore-user-config", observed["argv"])
        self.assertIn("--ignore-rules", observed["argv"])
        self.assertIn("--ephemeral", observed["argv"])
        self.assertIn("read-only", observed["argv"])
        self.assertEqual("-", observed["argv"][-1])
        self.assertIn("shell_tool", observed["argv"])
        self.assertIn("plugins", observed["argv"])
        self.assertNotEqual(str(PROJECT), observed["cwd"])
        self.assertFalse(pathlib.Path(observed["cwd"]).exists())
        self.assertFalse(observed["schema"]["additionalProperties"])

    def test_malformed_or_tool_responses_stop_without_diagnostic_leak(self):
        for name, body in [
            ("invalid", 'print("not json")'),
            ("tool", 'print(\'{"type":"item.completed","item":{"type":"command_execution","command":"echo secret"}}\')'),
            ("array", 'print("[]")'),
            ("error", 'import sys\nprint("secret-key", file=sys.stderr)\nsys.exit(1)'),
        ]:
            with self.subTest(case=name):
                fake = self.script(name, body + "\n")
                with self.assertRaises(llm.LLMError) as error:
                    llm.Planner(fake).decide("task", [snapshot()], [], 5)
                self.assertNotIn("secret", str(error.exception))

    def test_timeout_terminates_process_group(self):
        fake = self.script("hang", 'import time\ntime.sleep(60)\n')
        processes = []
        original_popen = subprocess.Popen
        def launch(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            processes.append(process)
            return process
        started = time.monotonic()
        with mock.patch.object(llm.subprocess, "Popen", side_effect=launch):
            with self.assertRaises(llm.LLMError):
                llm.capture([fake], 0.2, "task")
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(1, len(processes))
        with self.assertRaises(ProcessLookupError):
            os.kill(processes[0].pid, 0)

    def test_closed_output_does_not_escape_as_timeout_exception(self):
        fake = self.script("close-output", 'import os,time\nos.close(1)\nos.close(2)\ntime.sleep(60)\n')
        with self.assertRaises(llm.LLMError):
            llm.capture([fake], 0.2)


class WindowDispatch(unittest.TestCase):
    def run_task(self, agent, planner_callback, **kwargs):
        events = []
        class FakePlanner:
            def __init__(self, *_):
                pass
            def decide(self, task, observed, history, timeout):
                return planner_callback(observed, history)
        result = llm.run_task(arguments(**kwargs), "/fake/codex", PROJECT / "scripts/dlm",
                              lambda kind, message, **extra: events.append(dict(type=kind, message=message, **extra)),
                              agent_factory=lambda _: agent, planner_factory=FakePlanner)
        return result, events

    def test_refreshes_snapshot_after_planning_and_remaps_fresh_node(self):
        agent = FakeAgent([])
        def planner(observed, history):
            return decision("set_value", node_id=observed[0]["nodes"][0]["id"], value="After") if not history else decision()
        result, events = self.run_task(agent, planner)
        self.assertEqual(0, result)
        actions = [params for tool, params in agent.calls if tool == "computer_act"]
        self.assertEqual(1, len(actions))
        self.assertEqual("node-3", actions[0]["node_id"])
        self.assertEqual("snapshot-3", actions[0]["snapshot_id"])
        self.assertEqual("After", actions[0]["value"])
        self.assertEqual("completed", events[-1]["type"])
        attached = [event for event in events if "session_id" in event]
        self.assertEqual("owned-session", attached[0]["session_id"])
        self.assertNotIn('"value":', json.dumps(events))
        self.assertNotIn("After", json.dumps(events))
        self.assertTrue(agent.closed)

    def test_explicit_focus_precedes_synthetic_input_then_remaps(self):
        agent = FakeAgent([])
        def planner(observed, history):
            return decision("type_text", node_id=observed[0]["nodes"][0]["id"], text="hello") if not history else decision()
        result, _ = self.run_task(agent, planner)
        actions = [params for tool, params in agent.calls if tool == "computer_act"]
        self.assertEqual(["focus", "type_text"], [a["action"] for a in actions])
        self.assertEqual("node-5", actions[1]["node_id"])
        self.assertEqual("snapshot-5", actions[1]["snapshot_id"])

    def test_changed_session_or_target_stops_before_any_action(self):
        for mode in ("change_session", "after_plan_changed"):
            with self.subTest(mode=mode):
                agent = FakeAgent([])
                setattr(agent, mode, True)
                with self.assertRaises(llm.LLMError):
                    self.run_task(agent, lambda observed, history: decision("set_value", node_id=observed[0]["nodes"][0]["id"], value="After"))
                self.assertFalse(any(tool == "computer_act" for tool, _ in agent.calls))
                self.assertTrue(agent.closed)

    def test_unknown_outcome_stops_without_retry(self):
        agent = FakeAgent([])
        agent.unknown = True
        with self.assertRaises(llm.LLMError):
            self.run_task(agent, lambda observed, history: decision("set_value", node_id=observed[0]["nodes"][0]["id"], value="After"))
        self.assertEqual(1, sum(tool == "computer_act" for tool, _ in agent.calls))
        self.assertTrue(agent.closed)

    def test_step_limit_and_cancel_always_close_owned_client(self):
        agent = FakeAgent([])
        with self.assertRaises(llm.LLMError):
            self.run_task(agent, lambda observed, history: {"kind": "observe", "message": "读取", "window_id": None, "action": None}, max_steps=2)
        self.assertTrue(agent.closed)
        agent = FakeAgent([])
        def cancel(*_):
            raise llm.Cancelled("cancelled")
        with self.assertRaises(llm.Cancelled):
            self.run_task(agent, cancel)
        self.assertTrue(agent.closed)

    def test_rejects_outside_coordinates_foreign_secure_or_ambiguous_nodes(self):
        before = snapshot(0)
        fresh = snapshot(1)
        for action in (decision("click", x=9999, y=22)["action"],
                       decision("set_value", node_id="foreign-node", value="After")["action"],
                       decision("key", key="tab", modifiers=["command"])["action"]):
            with self.assertRaises(llm.LLMError):
                llm.rebind_action(action, before, fresh)
        before["nodes"][0]["secure"] = True
        with self.assertRaises(llm.LLMError):
            llm.rebind_action(decision("set_value", node_id="node-0", value="secret")["action"], before, fresh)
        before = snapshot(0)
        fresh["nodes"].append(dict(fresh["nodes"][0], id="duplicate"))
        with self.assertRaises(llm.LLMError):
            llm.rebind_action(decision("click", node_id="node-0")["action"], before, fresh)

    def test_invalid_planner_action_cannot_smuggle_a_tool_or_shell_command(self):
        for value in ({"kind": "action", "message": "bad", "action": {"action": "exec", "command": "ls"}},
                      {"kind": "done", "message": "bad", "action": {"action": "click"}},
                      {"kind": "done", "message": "bad", "action": None, "tool": "computer_attach"}):
            with self.assertRaises(llm.LLMError):
                llm.validate_decision(value)


class MultiAgentFixture:
    def __init__(self):
        self.calls = []
        self.owned_sessions = set()
        self.released = set()
        self.closed = False
        self.values = {"source": "Source says 17", "destination": "Blank"}
        self.pids = {"source": 42, "destination": 43}
        self.focused = "source"
        self.failed_attach = None
        self.replaced = None
        self.closed_window = None

    def observation(self, target):
        result = snapshot(len(self.calls), self.values[target])
        result["session_id"] = "session-" + target
        result["window"]["window_id"] = target
        result["app"]["pid"] = self.pids[target]
        result["window_title"] = target.title()
        result["focused"] = self.focused == target
        result["nodes"][0]["focused"] = result["focused"]
        if target == self.replaced:
            result["session_id"] = "replacement-session"
        return result

    def call(self, tool, params, timeout=None):
        self.calls.append((tool, copy.deepcopy(params)))
        if tool == "computer_attach":
            target = params["window_id"]
            if target == self.failed_attach:
                raise llm.LLMError("attach failed")
            return {"session_id": "session-" + target, "observation": self.observation(target)}
        session_id = params.get("session_id")
        assert session_id in self.owned_sessions, "explicit owned session required"
        target = session_id.removeprefix("session-")
        if target == self.closed_window:
            raise llm.LLMError("stale-window")
        if tool == "computer_observe":
            return self.observation(target)
        if tool == "computer_act":
            if params["action"] == "focus":
                self.focused = target
            elif params["action"] == "set_value":
                self.values[target] = params["value"]
            elif params["action"] == "type_text":
                assert self.focused == target
                self.values[target] = params["text"]
            return {"outcome": "verified", "observation": self.observation(target)}
        raise AssertionError(tool)

    def close(self):
        self.released.update(self.owned_sessions)
        self.owned_sessions.clear()
        self.closed = True


class MultiWindowDispatch(unittest.TestCase):
    run_task = WindowDispatch.run_task
    def run_multi(self, agent, planner, **kwargs):
        return self.run_task(agent, planner, pid=None, window_id=None,
                             window=["42:source", "43:destination"], **kwargs)

    def test_reads_source_and_writes_destination_with_both_in_context(self):
        agent = MultiAgentFixture()
        contexts = []
        def planner(observed, history):
            contexts.append(copy.deepcopy(observed))
            by_id = {item["window"]["window_id"]: item for item in observed}
            if history:
                self.assertEqual("Source says 17", by_id["destination"]["nodes"][0]["value"])
                return decision()
            return decision("set_value", window_id="destination",
                            node_id=by_id["destination"]["nodes"][0]["id"],
                            value=by_id["source"]["nodes"][0]["value"])
        result, events = self.run_multi(agent, planner)
        self.assertEqual(0, result)
        self.assertEqual(2, len(contexts))
        self.assertTrue(all(len(observed) == 2 for observed in contexts))
        self.assertEqual(["computer_attach", "computer_attach"], [tool for tool, _ in agent.calls[:2]])
        acts = [params for tool, params in agent.calls if tool == "computer_act"]
        self.assertEqual(1, len(acts))
        self.assertEqual("session-destination", acts[0]["session_id"])
        self.assertEqual("Source says 17", agent.values["destination"])
        self.assertEqual({"session-source", "session-destination"}, agent.released)
        self.assertEqual(0, events[0]["window_count"])
        self.assertEqual(2, events[0]["selected_window_count"])
        attached = [event for event in events if event["type"] == "status" and "session_id" in event]
        self.assertEqual(["source", "destination"], [item["window_id"] for item in attached])
        self.assertEqual([1, 2], [item["window_count"] for item in attached])
        self.assertEqual("destination", next(item for item in events if item["type"] == "tool")["window_id"])

    def test_focus_switches_between_selected_windows_without_invalidating_content(self):
        agent = MultiAgentFixture()
        def planner(observed, history):
            if len(history) == 2:
                return decision()
            target = "destination" if not history else "source"
            current = next(item for item in observed if item["window"]["window_id"] == target)
            return decision("type_text", window_id=target, node_id=current["nodes"][0]["id"], text="Updated " + target)
        result, _ = self.run_multi(agent, planner)
        self.assertEqual(0, result)
        acts = [params for tool, params in agent.calls if tool == "computer_act"]
        self.assertEqual(["focus", "type_text", "focus", "type_text"], [params["action"] for params in acts])
        self.assertEqual(["session-destination"] * 2 + ["session-source"] * 2, [params["session_id"] for params in acts])
        self.assertEqual("Updated source", agent.values["source"])
        self.assertEqual("Updated destination", agent.values["destination"])

    def test_slow_peer_observation_does_not_expire_action_or_post_focus_snapshot(self):
        class SlowPeerAgent(MultiAgentFixture):
            def __init__(self):
                super().__init__()
                self.elapsed = 0
                self.snapshot_times = {}

            def call(self, tool, params, timeout=None):
                if tool == "computer_observe":
                    # A selected background window takes longer to observe than
                    # the native action snapshot lifetime. No real waiting.
                    self.elapsed += 20 if params["session_id"] == "session-destination" else 1
                if tool == "computer_act":
                    if self.elapsed - self.snapshot_times[params["snapshot_id"]] > 15:
                        raise llm.LLMError("stale-snapshot")
                result = super().call(tool, params, timeout)
                observed = result if tool == "computer_observe" else result["observation"]
                self.snapshot_times[observed["snapshot_id"]] = self.elapsed
                return result

        for action in ("set_value", "type_text"):
            with self.subTest(action=action):
                agent = SlowPeerAgent()
                def planner(observed, history):
                    self.assertEqual(["source", "destination"], [item["window"]["window_id"] for item in observed])
                    if history:
                        return decision()
                    field = "value" if action == "set_value" else "text"
                    return decision(action, window_id="source", node_id=observed[0]["nodes"][0]["id"], **{field: "Updated source"})
                result, _ = self.run_multi(agent, planner)
                self.assertEqual(0, result)
                self.assertEqual("Updated source", agent.values["source"])
                acts = [params["action"] for tool, params in agent.calls if tool == "computer_act"]
                self.assertEqual([action] if action == "set_value" else ["focus", action], acts)

    def test_unselected_window_and_foreign_node_are_rejected_before_actions(self):
        for target, node_id in (("unselected", "node-4"), ("destination", "foreign-node")):
            with self.subTest(target=target):
                agent = MultiAgentFixture()
                with self.assertRaises(llm.LLMError):
                    self.run_multi(agent, lambda *_: decision("set_value", window_id=target, node_id=node_id, value="Forbidden"))
                self.assertFalse(any(tool == "computer_act" for tool, _ in agent.calls))
                self.assertEqual({"session-source", "session-destination"}, agent.released)

    def test_changed_source_blocks_copy_to_unchanged_destination(self):
        agent = MultiAgentFixture()
        def planner(observed, history):
            agent.values["source"] = "New source content"
            return decision("set_value", window_id="destination", node_id=observed[1]["nodes"][0]["id"], value="Source says 17")
        with self.assertRaises(llm.LLMError):
            self.run_multi(agent, planner)
        self.assertEqual("Blank", agent.values["destination"])
        self.assertFalse(any(tool == "computer_act" for tool, _ in agent.calls))

    def test_completion_replans_both_fresh_windows_before_announcing_success(self):
        class ChangingTreeAgent(MultiAgentFixture):
            transient_group = True

            def observation(self, target):
                result = super().observation(target)
                if self.transient_group:
                    result["nodes"].append({"id": "transient-group", "role": "AXGroup", "enabled": True})
                return result

        agent = ChangingTreeAgent()
        contexts = []
        def planner(observed, history):
            contexts.append(copy.deepcopy(observed))
            if not history:
                agent.transient_group = False
            else:
                self.assertEqual("observe", history[-1]["kind"])
                self.assertEqual("completion-state-changed", history[-1]["reason"])
                self.assertEqual(["source", "destination"], history[-1]["changed_window_ids"])
                self.assertTrue(all(len(item["nodes"]) == 1 for item in observed))
            return decision()
        result, events = self.run_multi(agent, planner)
        self.assertEqual(0, result)
        self.assertEqual(2, len(contexts))
        self.assertNotEqual(contexts[0][0]["snapshot_id"], contexts[1][0]["snapshot_id"])
        self.assertEqual(1, sum(event["type"] == "completed" for event in events))
        self.assertEqual(1, sum(event["type"] == "message" for event in events))
        self.assertTrue(any(event["type"] == "status" and "重新确认" in event["message"] for event in events))
        self.assertFalse(any(tool == "computer_act" for tool, _ in agent.calls))
        self.assertEqual({"session-source", "session-destination"}, agent.released)

    def test_completion_replanning_never_repeats_an_already_dispatched_action(self):
        class DispatchedAgent(MultiAgentFixture):
            def call(self, tool, params, timeout=None):
                result = super().call(tool, params, timeout)
                if tool == "computer_act":
                    result["outcome"] = "dispatched"
                return result

        agent = DispatchedAgent()
        planned = []
        def planner(observed, history):
            planned.append(copy.deepcopy(observed))
            if not history:
                return decision("set_value", window_id="destination", node_id=observed[1]["nodes"][0]["id"], value="Copied")
            if len(planned) == 2:
                agent.focused = "destination"
            else:
                self.assertEqual(["action", "observe"], [row["kind"] for row in history])
                self.assertFalse(observed[0]["nodes"][0]["focused"])
                self.assertTrue(observed[1]["nodes"][0]["focused"])
                self.assertEqual("Copied", observed[1]["nodes"][0]["value"])
            return decision()
        result, events = self.run_multi(agent, planner)
        self.assertEqual(0, result)
        self.assertEqual(3, len(planned))
        self.assertEqual(1, sum(tool == "computer_act" for tool, _ in agent.calls))
        self.assertEqual(["dispatched"], [event["outcome"] for event in events if event["type"] == "tool"])
        self.assertEqual(1, sum(event["type"] == "completed" for event in events))

    def test_completion_replanning_remains_bounded_by_steps_and_total_time(self):
        for limit in ("steps", "time"):
            with self.subTest(limit=limit):
                agent = MultiAgentFixture()
                contexts, now = [], [0]
                def planner(observed, history):
                    contexts.append(copy.deepcopy(observed))
                    agent.values["source"] = "Changed " + str(len(contexts))
                    if limit == "time":
                        now[0] += 16
                    return decision()
                with mock.patch.object(llm.time, "monotonic", side_effect=lambda: now[0]):
                    with self.assertRaisesRegex(llm.LLMError, "步骤上限" if limit == "steps" else "总时限"):
                        self.run_multi(agent, planner, max_steps=2 if limit == "steps" else 4)
                self.assertEqual(2, len(contexts))
                self.assertEqual("Changed 1", contexts[1][0]["nodes"][0]["value"])
                self.assertFalse(any(tool == "computer_act" for tool, _ in agent.calls))
                self.assertEqual({"session-source", "session-destination"}, agent.released)

    def test_completion_stops_on_invalid_identity_closed_window_or_incomplete_observation(self):
        for mode in ("session", "pid", "window", "closed", "incomplete", "always-incomplete", "missing-complete"):
            with self.subTest(mode=mode):
                agent = MultiAgentFixture()
                original_observation = agent.observation
                planned = []
                def observation(target):
                    current = original_observation(target)
                    if target == "source" and (planned or mode == "always-incomplete"):
                        if mode == "session":
                            current["session_id"] = "foreign-session"
                        elif mode == "pid":
                            current["app"]["pid"] = 999
                        elif mode == "window":
                            current["window"]["window_id"] = "foreign-window"
                        elif mode in ("incomplete", "always-incomplete"):
                            current["complete"] = False
                        elif mode == "missing-complete":
                            del current["complete"]
                    return current
                agent.observation = observation
                def planner(*_):
                    planned.append(True)
                    if mode == "closed":
                        agent.closed_window = "source"
                    return decision()
                with self.assertRaises(llm.LLMError):
                    self.run_multi(agent, planner)
                self.assertEqual(1, len(planned))
                self.assertFalse(any(tool == "computer_act" for tool, _ in agent.calls))
                self.assertEqual({"session-source", "session-destination"}, agent.released)

    def test_partial_attach_failure_releases_only_attached_window(self):
        agent = MultiAgentFixture()
        agent.failed_attach = "destination"
        with self.assertRaises(llm.LLMError):
            self.run_multi(agent, lambda *_: self.fail("planner must not run"))
        self.assertEqual({"session-source"}, agent.released)
        self.assertTrue(agent.closed)

    def test_session_replacement_window_close_and_cancel_stop_whole_task(self):
        for mode in ("replaced", "closed_window", "cancel"):
            with self.subTest(mode=mode):
                agent = MultiAgentFixture()
                def planner(observed, history):
                    if mode == "cancel":
                        raise llm.Cancelled("cancelled")
                    setattr(agent, mode, "source")
                    return decision("set_value", window_id="destination", node_id=observed[1]["nodes"][0]["id"], value="Stopped")
                with self.assertRaises(llm.LLMError):
                    self.run_multi(agent, planner)
                self.assertFalse(any(tool == "computer_act" for tool, _ in agent.calls))
                self.assertEqual({"session-source", "session-destination"}, agent.released)


class SelectionValidation(unittest.TestCase):
    def test_multi_selection_and_legacy_pair(self):
        self.assertEqual([(42, "window-42")], llm.selected_windows(arguments()))
        self.assertEqual([(42, "a"), (43, "b")], llm.selected_windows(arguments(pid=None, window_id=None, window=["42:a", "43:b"])))

    def test_invalid_selection_fails_before_agent_creation(self):
        cases = [dict(pid=None, window_id=None), dict(pid=42, window_id=None),
                 dict(window=["42:a"]), dict(pid=0), dict(pid=True),
                 *[dict(pid=None, window_id=None, window=value) for value in
                   (["42"], ["42:"], ["-1:a"], ["42:a:b"], ["42:a", "43:a"],
                    ["abc:a"], ["42:space here"], ["9" * 5000 + ":a"],
                    [f"42:window-{index}" for index in range(9)])]]
        for changes in cases:
            with self.subTest(changes=str(changes)[:100]):
                factory = mock.Mock(side_effect=AssertionError("must not create an agent"))
                with self.assertRaises(llm.LLMError):
                    llm.run_task(arguments(**changes), "/fake/codex", PROJECT / "scripts/dlm", lambda *_: None, agent_factory=factory)
                factory.assert_not_called()


class AgentTransport(ScriptFixture):
    def test_shutdown_allows_serial_cleanup_after_an_unacknowledged_attach(self):
        for acknowledged_count in (0, 3, 7):
            with self.subTest(acknowledged=acknowledged_count):
                class PendingShutdownProcess:
                    pid = 123456
                    stdin = stdout = stderr = None
                    returncode = None
                    cleaned = False

                    def poll(self):
                        return self.returncode

                    def wait(self, timeout):
                        if self.returncode is not None:
                            return self.returncode
                        # A pending attach can still succeed. The shutdown
                        # hook then detaches it and all acknowledged sessions.
                        required = 15 + 15 * (acknowledged_count + 1)
                        if timeout < required:
                            raise subprocess.TimeoutExpired("slow agent shutdown", timeout)
                        self.cleaned = True
                        self.returncode = 0
                        return 0

                process = PendingShutdownProcess()
                client = llm.AgentClient.__new__(llm.AgentClient)
                client.process = process
                client.owned_sessions = {f"owned-{index}" for index in range(acknowledged_count)}
                client.in_flight = True
                client.call = mock.Mock(side_effect=AssertionError("unknown request must not be retried"))
                signals = []
                def signal_process(pid, signum):
                    self.assertEqual(process.pid, pid)
                    signals.append(signum)
                    if signum == signal.SIGKILL:
                        process.returncode = -signal.SIGKILL
                with mock.patch.object(llm.os, "killpg", side_effect=signal_process):
                    client.close()
                self.assertTrue(process.cleaned)
                self.assertEqual([signal.SIGTERM], signals)
                client.call.assert_not_called()

    def test_persistent_jsonl_and_owned_detach(self):
        log = self.root / "calls.jsonl"
        fake = self.script("agent", f'''import json,pathlib,sys
for line in sys.stdin:
 request=json.loads(line)
 with open({str(log)!r}, "a") as log: log.write(json.dumps(request)+"\\n")
 print(json.dumps({{"id":request["id"],"ok":True,"result":{{"result":"ok"}}}}),flush=True)
''')
        agent = llm.AgentClient([fake])
        try:
            self.assertEqual({"result": "ok"}, agent.call("computer_observe", {}))
            agent.owned_sessions.add("owned-session")
        finally:
            agent.close()
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(["computer_observe", "computer_detach"], [row["tool"] for row in calls])
        self.assertNotEqual(calls[0]["id"], calls[1]["id"])
        self.assertEqual({"session_id": "owned-session"}, calls[1]["arguments"])
        self.assertIsNotNone(agent.process.returncode)

    def test_cleanup_releases_every_owned_session_with_explicit_scope(self):
        log = self.root / "multi-calls.jsonl"
        fake = self.script("multi-agent", f'''import json,sys
for line in sys.stdin:
 request=json.loads(line)
 with open({str(log)!r}, "a") as log: log.write(json.dumps(request)+"\\n")
 result={{"session_id":"session-"+request["arguments"].get("window_id","")}}
 print(json.dumps({{"id":request["id"],"ok":True,"result":result}}),flush=True)
''')
        agent = llm.AgentClient([fake])
        try:
            for target in ("a", "b"):
                agent.call("computer_attach", {"window_id": target})
            self.assertEqual({"session-a", "session-b"}, agent.owned_sessions)
        finally:
            agent.close()
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        detached = [row["arguments"] for row in calls if row["tool"] == "computer_detach"]
        self.assertEqual({"session-a", "session-b"}, {row["session_id"] for row in detached})
        self.assertEqual(2, len(detached))
        self.assertEqual(set(), agent.owned_sessions)

    def test_unowned_client_does_not_send_detach(self):
        fake = self.script("agent", 'import sys,time\ntime.sleep(60)\n')
        agent = llm.AgentClient([fake])
        with mock.patch.object(agent, "call", side_effect=AssertionError("unowned detach")):
            agent.close()

    def test_blocked_pipe_write_is_bounded_and_unknown_call_is_not_retried(self):
        fake = self.script("agent", 'import time\ntime.sleep(60)\n')
        agent = llm.AgentClient([fake], timeout=0.2)
        started = time.monotonic()
        try:
            with self.assertRaises(llm.LLMError):
                agent.call("computer_act", {"value": "x" * 100000})
            self.assertTrue(agent.in_flight)
            with self.assertRaises(llm.LLMError):
                agent.call("computer_act", {})
        finally:
            agent.close()
        self.assertLess(time.monotonic() - started, 5)

    def test_sigterm_cancels_planner_and_reaps_descendant(self):
        pid_file = self.root / "descendant.pid"
        child = self.script("child", f'import os,pathlib,time\npathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))\ntime.sleep(60)\n')
        harness = self.script("harness", f'''import importlib.util,signal,sys
spec=importlib.util.spec_from_file_location("llm", {str(PROJECT / "scripts/llm.py")!r})
llm=importlib.util.module_from_spec(spec);spec.loader.exec_module(llm)
def cancel(*_): raise llm.Cancelled("cancelled")
signal.signal(signal.SIGTERM,cancel)
try: llm.capture([{child!r}],60)
except llm.Cancelled: sys.exit(130)
''')
        process = subprocess.Popen([harness])
        try:
            deadline = time.monotonic() + 15
            while (not pid_file.exists() or not pid_file.stat().st_size) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pid_file.exists())
            process.terminate()
            self.assertEqual(130, process.wait(timeout=5))
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_cancel_waits_for_slow_agent_shutdown_hook(self):
        ready = self.root / "ready"
        detached = self.root / "detached"
        fake = self.script("slow-agent", f'''import pathlib,signal,time,sys
def stop(*_):
 time.sleep(3.2)
 pathlib.Path({str(detached)!r}).write_text("owned session released")
 sys.exit(0)
signal.signal(signal.SIGTERM,stop)
pathlib.Path({str(ready)!r}).touch()
time.sleep(60)
''')
        agent = llm.AgentClient([fake])
        try:
            deadline = time.monotonic() + 15
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            agent.in_flight = True
            agent.close()
            self.assertTrue(detached.exists())
            self.assertEqual(0, agent.process.returncode)
        finally:
            llm.stop_process(agent.process)

    def test_repeated_sigterm_and_sigint_do_not_interrupt_cleanup(self):
        ready = self.root / "child-ready"
        stopping = self.root / "child-stopping"
        cleaned = self.root / "child-cleaned"
        child = self.script("child", f'''import os,pathlib,signal,sys,time
def stop(*_):
 pathlib.Path({str(stopping)!r}).touch()
 time.sleep(0.4)
 pathlib.Path({str(cleaned)!r}).touch()
 sys.exit(0)
signal.signal(signal.SIGTERM,stop)
pathlib.Path({str(ready)!r}).write_text(str(os.getpid()))
time.sleep(60)
''')
        harness = self.script("harness", f'''import argparse,importlib.util,sys
spec=importlib.util.spec_from_file_location("llm", {str(PROJECT / "scripts/llm.py")!r})
llm=importlib.util.module_from_spec(spec);spec.loader.exec_module(llm)
llm.find_codex=lambda: {child!r}
llm.status=lambda _: {{"authenticated":True,"message":"ready"}}
llm.run_task=lambda *_: llm.capture([{child!r}],60)
sys.exit(llm.main(argparse.Namespace(llm_command="run",json=True),"/fake/dlm"))
''')
        process = subprocess.Popen([harness], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while (not ready.exists() or not ready.stat().st_size) and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            process.terminate()
            while not stopping.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(stopping.exists())
            process.send_signal(signal.SIGINT)
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(130, process.returncode, stderr)
            self.assertTrue(cleaned.exists())
            self.assertEqual("cancelled", json.loads(stdout.splitlines()[-1])["code"])
            with self.assertRaises(ProcessLookupError):
                os.kill(int(ready.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main(verbosity=2)
