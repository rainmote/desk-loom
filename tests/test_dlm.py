"""Exercise the real CLI against an isolated authenticated local server."""
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

PROJECT = pathlib.Path(__file__).resolve().parents[1]


class CLI(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="DeskLoom CLI ")
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.environment = dict(os.environ, HOME=str(self.home))
        self.requests = []
        self.secret = "private-test-token-never-printed"
        self.response = {"ok": True, "result": {"accepted": True}}
        self.http_status = 200
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fixture.requests.append((self.path, self.headers.get("Authorization"), payload))
                self.send_response(fixture.http_status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(fixture.response).encode())

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.endpoint = self.write_endpoint("DeskLoom")

    def tearDown(self):
        self.server.shutdown()
        self.worker.join()
        self.server.server_close()
        self.temporary.cleanup()

    def write_endpoint(self, name):
        path = self.home / "Library/Application Support" / name / "endpoint.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"protocol_version": 1, "port": self.server.server_port,
                                    "token": self.secret, "pid": os.getpid()}))
        path.chmod(0o600)
        return path

    def run_cli(self, *args, script=None):
        return subprocess.run([sys.executable, str(script or PROJECT / "scripts/dlm"), *args],
                              env=self.environment, text=True, capture_output=True, timeout=10)

    def test_commands_use_authenticated_local_rpc(self):
        cases = [("status", {}, ["status"]),
                 ("show_settings", {}, ["settings"]),
                 ("icon_settings", {}, ["icon"]),
                 ("icon_settings", {"selected_icon": "D"}, ["icon", "d"]),
                 ("menu_action", {"action": "update"}, ["update"]),
                 ("computer_observe", {"session_id": "中文"}, ["rpc", "computer_observe", '{"session_id":"中文"}'])]
        for method, params, arguments in cases:
            with self.subTest(command=arguments):
                result = self.run_cli(*arguments)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(("/rpc", "Bearer " + self.secret, {"method": method, "params": params}), self.requests[-1])
                self.assertNotIn(self.secret, result.stdout + result.stderr)
        self.assertEqual(len(cases), len(self.requests))

    def test_fallback_to_legacy_endpoint(self):
        self.endpoint.unlink()
        self.write_endpoint("ComputerUsePrototype")
        result = self.run_cli("status")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, len(self.requests))

    def test_invalid_new_endpoint_does_not_use_legacy(self):
        self.write_endpoint("ComputerUsePrototype")
        self.endpoint.write_text(json.dumps({"port": True, "token": self.secret, "protocol_version": 1}))
        result = self.run_cli("status")
        self.assertEqual(1, result.returncode)
        self.assertIn("endpoint is invalid", result.stderr)
        self.assertNotIn(self.secret, result.stdout + result.stderr)
        self.assertEqual([], self.requests)

    def test_errors_are_nonzero_and_not_retried(self):
        self.response = {"ok": False, "error": {"code": "busy", "message": "busy"}}
        result = self.run_cli("rpc", "computer_attach")
        self.assertEqual(1, result.returncode)
        self.assertEqual(1, len(self.requests))
        self.response = {"ok": True, "result": {"accepted": False}}
        result = self.run_cli("update")
        self.assertEqual(1, result.returncode)
        self.assertIn("update was not started", result.stderr)
        self.assertEqual(2, len(self.requests))
        self.http_status = 401
        result = self.run_cli("status")
        self.assertEqual(1, result.returncode)
        self.assertIn("HTTP 401", result.stderr)
        self.assertEqual(3, len(self.requests))

    def test_help_and_invalid_params_do_not_connect(self):
        self.assertEqual(0, self.run_cli("--help").returncode)
        for arguments in [("rpc", "computer_attach", "[]"), ("rpc", "computer_attach", "{"), ("icon", "X")]:
            self.assertNotEqual(0, self.run_cli(*arguments).returncode)
        self.endpoint.unlink()
        result = self.run_cli("status")
        self.assertEqual(1, result.returncode)
        self.assertIn("dlm open", result.stderr)
        self.assertEqual([], self.requests)

    def test_accidental_token_echo_is_redacted(self):
        self.response = {"ok": True, "result": {"message": "echo " + self.secret}}
        result = self.run_cli("status")
        self.assertEqual(0, result.returncode)
        self.assertNotIn(self.secret, result.stdout + result.stderr)
        self.assertIn("[redacted]", result.stdout)

    def test_bundled_symlink_uses_configured_repl_and_keeps_bundle_clean(self):
        resources = self.root / "DeskLoom.app/Contents/Resources"
        resources.mkdir(parents=True)
        for filename in ("dlm", "rpc.py"):
            shutil.copy2(PROJECT / "scripts" / filename, resources / filename)
        source = self.root / "source project"
        (source / "scripts").mkdir(parents=True)
        clojure = source / "scripts/clj"
        clojure.write_text('#!/bin/sh\nprintf "repl:%s\\n" "$1"\n')
        clojure.chmod(0o755)
        (resources / "BuildConfiguration.json").write_text(json.dumps({"sourceDirectory": str(source)}))
        symlink = self.root / "dlm"
        symlink.symlink_to(resources / "dlm")
        status = self.run_cli("status", script=symlink)
        self.assertEqual(0, status.returncode, status.stderr)
        result = self.run_cli("repl", script=symlink)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("repl:-M:xtdb:repl\n", result.stdout)
        self.assertFalse((resources / "__pycache__").exists())
        clojure.unlink()
        result = self.run_cli("repl", script=symlink)
        self.assertEqual(1, result.returncode)
        self.assertIn("source project is missing", result.stderr)

    def test_bridge_commands_forward_paths_as_individual_arguments(self):
        resources = self.root / "Bridge.app/Contents/Resources"
        resources.mkdir(parents=True)
        for filename in ("dlm", "rpc.py"):
            shutil.copy2(PROJECT / "scripts" / filename, resources / filename)
        source = self.root / "source with spaces"
        (source / "scripts").mkdir(parents=True)
        clojure = source / "scripts/clj"
        clojure.write_text("#!" + sys.executable + "\n"
                           "import json, sys\nprint(json.dumps(sys.argv[1:]))\n")
        clojure.chmod(0o755)
        (resources / "BuildConfiguration.json").write_text(json.dumps({"sourceDirectory": str(source)}))
        executable = resources / "dlm"
        database = str(self.root / "中文 local database")
        endpoint = str(self.root / "private endpoint.json")
        for command, expected in [("mcp", ["-M:xtdb:mcp"]),
                                  ("agent", ["-M:xtdb:mcp", "--jsonl"])]:
            with self.subTest(command=command):
                result = self.run_cli(command, "--endpoint", endpoint,
                                      "--db-path", database, script=executable)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(expected + ["--db-path", database, "--endpoint", endpoint],
                                 json.loads(result.stdout))
        self.assertEqual([], self.requests)
        self.assertFalse((resources / "__pycache__").exists())

    def test_llm_accepts_repeated_windows_and_preserves_legacy_pair(self):
        resources = self.root / "LLM.app/Contents/Resources"
        resources.mkdir(parents=True)
        for filename in ("dlm", "rpc.py"):
            shutil.copy2(PROJECT / "scripts" / filename, resources / filename)
        (resources / "llm.py").write_text("import json\ndef main(args, path):\n print(json.dumps(vars(args)))\n return 0\n")
        result = self.run_cli("llm", "run", "--window", "42:source-id", "--window", "43:destination-id",
                              "--prompt-stdin", "--json", script=resources / "dlm")
        self.assertEqual(0, result.returncode, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(["42:source-id", "43:destination-id"], parsed["window"])
        self.assertIsNone(parsed["pid"])
        self.assertIsNone(parsed["window_id"])
        self.assertTrue(parsed["prompt_stdin"])
        result = self.run_cli("llm", "run", "--pid", "42", "--window-id", "source-id", "--prompt", "Task",
                              script=resources / "dlm")
        self.assertEqual(0, result.returncode, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(42, parsed["pid"])
        self.assertEqual("source-id", parsed["window_id"])
        self.assertIsNone(parsed["window"])
        self.assertEqual([], self.requests)


if __name__ == "__main__":
    unittest.main(verbosity=2)
