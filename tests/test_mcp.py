"""Exercise the actual stdio executable without opening a database or desktop.

Tests use either a missing endpoint or an isolated loopback error fixture.
Metrics loads the complete lazy runtime, but does not open XTDB.
"""
import json
import os
import pathlib
import queue
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PROJECT = pathlib.Path(__file__).resolve().parents[1]
EXPECTED_TOOLS = {
    "computer_capabilities", "computer_windows", "computer_attach",
    "computer_observe", "computer_act", "computer_batch", "computer_screenshot",
    "computer_detach", "computer_memory_search", "computer_memory_recall",
    "computer_metrics",
}


class Bridge:
    """Read replies while stdin stays open, including after lazy JVM loading."""

    def __init__(self, directory, mode="mcp"):
        self.root = pathlib.Path(directory)
        self.database = self.root / "must not open xtdb"
        self.endpoint = self.root / "missing endpoint.json"
        self.stderr = tempfile.TemporaryFile(mode="w+b")
        self.process = subprocess.Popen(
            [str(PROJECT / "scripts/dlm"), mode,
             "--db-path", str(self.database), "--endpoint", str(self.endpoint)],
            cwd=self.root,
            env=dict(os.environ, HOME=str(self.root)),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, encoding="utf-8",
        )
        self.lines = queue.Queue()

        def read_output():
            for line in self.process.stdout:
                self.lines.put(line)
            self.lines.put(None)

        self.reader = threading.Thread(target=read_output, daemon=True)
        self.reader.start()

    def diagnostics(self):
        self.stderr.flush()
        return os.pread(self.stderr.fileno(), 8192, 0).decode("utf-8", errors="replace")

    def send(self, message):
        self.send_line(json.dumps(message, ensure_ascii=False))

    def send_line(self, line):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def receive(self):
        try:
            line = self.lines.get(timeout=90)
        except queue.Empty:
            raise AssertionError("No flushed stdio reply within 90 seconds: " + self.diagnostics())
        if line is None:
            raise AssertionError("Server exited before replying: " + self.diagnostics())
        # Every stdout line must be a complete JSON object, never a JVM banner.
        value = json.loads(line)
        if not isinstance(value, dict):
            raise AssertionError("Non-object stdio output: " + line)
        return value

    def finish(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)
        self.reader.join(timeout=5)
        if self.process.returncode != 0:
            raise AssertionError("Bridge exit code %s: %s" % (self.process.returncode, self.diagnostics()))
        remaining = []
        while not self.lines.empty():
            line = self.lines.get_nowait()
            if line is not None:
                remaining.append(line)
        if remaining:
            raise AssertionError("Unexpected stdout, possibly notification replies: " + repr(remaining))
        if self.database.exists():
            raise AssertionError("Protocol/metrics requests unexpectedly opened XTDB")

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=10)
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.stdout.close()
        self.reader.join(timeout=5)
        self.stderr.close()


class MCPIntegration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="DeskLoom MCP 中文 ")
        self.addCleanup(self.temporary.cleanup)

    def bridge(self, mode="mcp"):
        bridge = Bridge(self.temporary.name, mode)
        self.addCleanup(bridge.close)
        return bridge

    def initialize(self, bridge, version="2025-11-25", request_id="init"):
        bridge.send({"jsonrpc": "2.0", "id": request_id, "method": "initialize",
                     "params": {"protocolVersion": version, "capabilities": {},
                                "clientInfo": {"name": "stdio-integration-test", "version": "1"}}})
        reply = bridge.receive()
        self.assertEqual(request_id, reply["id"])
        self.assertEqual("2.0", reply["jsonrpc"])
        bridge.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply["result"]

    def assert_error(self, bridge, message, code, request_id):
        bridge.send(message)
        reply = bridge.receive()
        self.assertEqual("2.0", reply["jsonrpc"])
        self.assertEqual(request_id, reply["id"])
        self.assertEqual(code, reply["error"]["code"])
        self.assertNotIn("result", reply)

    def test_negotiation_discovery_notifications_and_protocol_error_recovery(self):
        bridge = self.bridge()
        self.assert_error(bridge, {"jsonrpc": "2.0", "id": "discover", "method": "server/discover"},
                          -32601, "discover")
        self.assert_error(bridge, {"jsonrpc": "2.0", "id": "early", "method": "tools/list"},
                          -32600, "early")
        result = self.initialize(bridge, "2026-07-28")
        self.assertEqual("2025-11-25", result["protocolVersion"])
        self.assertIn("tools", result["capabilities"])

        bridge.send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                     "params": {"requestId": "not-running"}})
        bridge.send({"jsonrpc": "2.0", "method": "notifications/unknown"})
        # A tool notification must neither execute nor emit a response.
        bridge.send({"jsonrpc": "2.0", "method": "tools/call",
                     "params": {"name": "computer_metrics", "arguments": {}}})
        bridge.send({"jsonrpc": "2.0", "id": "list", "method": "tools/list", "params": {}})
        reply = bridge.receive()
        self.assertEqual("list", reply["id"])
        definitions = {tool["name"]: tool for tool in reply["result"]["tools"]}
        self.assertEqual(EXPECTED_TOOLS, set(definitions))
        for definition in definitions.values():
            self.assertEqual("object", definition["inputSchema"]["type"])
            self.assertFalse(definition["inputSchema"]["additionalProperties"])
        self.assertEqual(20, definitions["computer_batch"]["inputSchema"]["properties"]["steps"]["maxItems"])
        self.assertIn("bundle_id", definitions["computer_windows"]["inputSchema"]["properties"])
        for name in ("computer_observe", "computer_act", "computer_batch",
                     "computer_screenshot", "computer_detach"):
            self.assertEqual("string", definitions[name]["inputSchema"]["properties"]["session_id"]["type"])
            self.assertNotIn("session_id", definitions[name]["inputSchema"]["required"])
        self.assertNotIn("session_id", definitions["computer_batch"]["inputSchema"]["properties"]["steps"]["items"]["properties"])

        bridge.send_line("{invalid JSON")
        parse_error = bridge.receive()
        self.assertEqual(-32700, parse_error["error"]["code"])
        self.assertIsNone(parse_error["id"])
        self.assert_error(bridge, [], -32600, None)
        self.assert_error(bridge, {"jsonrpc": "2.0", "id": None, "method": "ping"}, -32600, None)
        self.assert_error(bridge, {"jsonrpc": "2.0", "id": 2, "method": "unknown"}, -32601, 2)
        self.assert_error(bridge, {"jsonrpc": "2.0", "id": 3, "method": "tools/list",
                                  "params": {"cursor": "missing"}}, -32602, 3)
        for request_id, params in [
                (4, {"name": "missing-tool", "arguments": {}}),
                (5, {"name": "computer_metrics", "arguments": []}),
                (6, {"name": "computer_metrics", "arguments": {"unexpected": True}}),
                (7, {"name": "computer_batch", "arguments": {
                    "request_id": "oversized-batch", "steps": [{"action": "focus"}] * 21}}),
                (8, {"name": "computer_batch", "arguments": {
                    "session_id": "A", "request_id": "cross-session-batch",
                    "steps": [{"action": "focus", "session_id": "B"}]}})]:
            self.assert_error(bridge, {"jsonrpc": "2.0", "id": request_id,
                                      "method": "tools/call", "params": params}, -32602, request_id)
        bridge.send({"jsonrpc": "2.0", "id": "after-errors", "method": "ping"})
        self.assertEqual({"jsonrpc": "2.0", "id": "after-errors", "result": {}}, bridge.receive())
        bridge.finish()

    def test_legacy_version_has_compatible_tool_definitions(self):
        bridge = self.bridge()
        result = self.initialize(bridge, "2024-11-05")
        self.assertEqual("2024-11-05", result["protocolVersion"])
        bridge.send({"jsonrpc": "2.0", "id": "list", "method": "tools/list"})
        reply = bridge.receive()
        self.assertEqual("list", reply["id"])
        self.assertEqual(EXPECTED_TOOLS, {tool["name"] for tool in reply["result"]["tools"]})
        self.assertTrue(all("annotations" not in tool for tool in reply["result"]["tools"]))
        bridge.finish()

    def test_lazy_runtime_metrics_and_native_failure_keep_stdout_clean(self):
        bridge = self.bridge()
        self.initialize(bridge)
        bridge.send({"jsonrpc": "2.0", "method": "tools/call",
                     "params": {"name": "computer_metrics", "arguments": {}}})
        for index in range(2):
            bridge.send({"jsonrpc": "2.0", "id": index, "method": "tools/call",
                         "params": {"name": "computer_metrics", "arguments": {}}})
            reply = bridge.receive()
            self.assertEqual(index, reply["id"])
            result = reply["result"]
            self.assertFalse(result["isError"])
            metadata = result["structuredContent"]
            self.assertEqual(metadata, json.loads(result["content"][0]["text"]))
            self.assertEqual("monotonic", metadata["clock"])
            self.assertGreaterEqual(metadata["elapsed_ms"], 0)
            if index == 0:
                self.assertEqual({}, metadata["operations"])
            else:
                self.assertEqual(1, metadata["operations"]["computer_metrics"]["calls"])

        # This path fails on the explicit absent endpoint, before any native RPC.
        bridge.send({"jsonrpc": "2.0", "id": "missing-native", "method": "tools/call",
                     "params": {"name": "computer_capabilities", "arguments": {}}})
        reply = bridge.receive()
        self.assertEqual("missing-native", reply["id"])
        self.assertNotIn("error", reply)
        self.assertTrue(reply["result"]["isError"])
        self.assertEqual(":endpoint-missing", reply["result"]["structuredContent"]["code"])
        bridge.finish()

    def test_raw_json_lines_metrics_and_validation(self):
        bridge = self.bridge("agent")
        bridge.send({"id": "中文-metrics", "tool": "computer_metrics", "arguments": {}})
        reply = bridge.receive()
        self.assertEqual("中文-metrics", reply["id"])
        self.assertTrue(reply["ok"])
        self.assertNotIn("jsonrpc", reply)
        self.assertEqual({}, reply["result"]["operations"])
        self.assertEqual("monotonic", reply["result"]["clock"])

        bridge.send({"id": "bad", "tool": "computer_metrics", "arguments": {"bad": True}})
        reply = bridge.receive()
        self.assertEqual("bad", reply["id"])
        self.assertFalse(reply["ok"])
        self.assertEqual(":invalid-arguments", reply["error"]["code"])

        bridge.send({"id": "again", "tool": "computer_metrics", "arguments": {}})
        reply = bridge.receive()
        self.assertEqual("again", reply["id"])
        self.assertTrue(reply["ok"])
        self.assertEqual(1, reply["result"]["operations"]["computer_metrics"]["calls"])
        bridge.finish()

    def test_native_capture_diagnostics_survive_both_transports(self):
        details = {"target_pid": 123, "matched_count": 0,
                   "target": {"title": "测试页 - Google Chrome", "bounds": {"x": 12.25}},
                   "candidates": [{"window_id": 456, "title_match": True, "geometry_match": False}]}
        calls = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                calls.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                body = json.dumps({"ok": False, "error": {"code": "ambiguous-capture",
                                  "message": "无法唯一匹配目标窗口", "details": details}}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        for mode in ("mcp", "agent"):
            with self.subTest(mode=mode):
                bridge = self.bridge(mode)
                bridge.endpoint.write_text(json.dumps({"port": server.server_port,
                                                       "token": "test-only-token", "protocol_version": 1}))
                if mode == "mcp":
                    self.initialize(bridge)
                    bridge.send({"jsonrpc": "2.0", "id": "diagnostics", "method": "tools/call",
                                 "params": {"name": "computer_capabilities", "arguments": {}}})
                    reply = bridge.receive()["result"]
                    self.assertTrue(reply["isError"])
                    metadata = reply["structuredContent"]
                    self.assertEqual(metadata, json.loads(reply["content"][0]["text"]))
                else:
                    bridge.send({"id": "diagnostics", "tool": "computer_capabilities", "arguments": {}})
                    reply = bridge.receive()
                    self.assertFalse(reply["ok"])
                    metadata = reply["error"]
                self.assertEqual("ambiguous-capture", metadata["code"])
                self.assertEqual(details, metadata["details"])
                bridge.finish()
        self.assertEqual(["computer_capabilities", "computer_capabilities"], [call["method"] for call in calls])


if __name__ == "__main__":
    unittest.main(verbosity=2)
