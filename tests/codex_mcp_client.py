"""Actual Codex MCP client for opt-in integration/desktop acceptance.

This uses the installed Codex app-server and existing user configuration. It
creates an ephemeral MCP runtime only: it never sends turn/start, asks a model
to act, or writes Codex configuration. All tool calls are explicit and are never
retried, including after timeout. ``directory`` is the evidence-log directory.
Wire and stderr evidence stay in memory until close(), so benchmark timings do
not include evidence serialization, flushing, or network-filesystem writes.
"""
import json
import pathlib
import queue
import shutil
import subprocess
import threading
import time
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]


class CodexMCP:
    def __init__(self, directory, *, timeout=90, cwd=None, executable=None):
        self.directory = pathlib.Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.timeout = timeout
        self.records = []
        self.rpc_records = []
        self.notifications = []
        self.thread_id = None
        self.startup_ms = None
        self.sequence = 0
        self.closed = False
        self.process = None
        self.reader = None
        self.stderr_reader = None
        self._trace_buffer = []
        self._stderr_buffer = []
        self._lock = threading.Lock()
        self._messages = queue.Queue()
        suffix = uuid.uuid4().hex[:8]
        self.log_path = self.directory / ("codex-app-server-" + suffix + ".log")
        self.wire_path = self.directory / ("codex-app-server-" + suffix + "-wire.jsonl")
        command = executable or shutil.which("codex")
        started = time.perf_counter()
        try:
            if not command:
                raise FileNotFoundError("Installed codex executable was not found in PATH")
            self.process = subprocess.Popen(
                [command, "app-server", "--stdio"],
                cwd=str(cwd or ROOT), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, bufsize=0,
            )
            self.reader = threading.Thread(target=self._read_stdout, daemon=True)
            self.reader.start()
            self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
            self.stderr_reader.start()
            self.initialize_result = self._rpc("initialize", {
                "clientInfo": {"name": "deskloom-integration-test", "version": "1.0"},
                "capabilities": {"experimentalApi": True},
            })[0]
            self._send({"method": "initialized"})
            thread_result, _ = self._rpc("thread/start", {
                "ephemeral": True, "cwd": str(cwd or ROOT),
            })
            thread = thread_result.get("thread", {})
            if thread.get("ephemeral") is not True or not thread.get("id"):
                raise RuntimeError("Codex did not confirm an ephemeral MCP runtime: " + json.dumps(thread))
            self.thread_id = thread["id"]
            self.startup_ms = (time.perf_counter() - started) * 1000
        except BaseException:
            self.close()
            raise

    def _read_stdout(self):
        try:
            for line in iter(self.process.stdout.readline, b""):
                self._messages.put(line)
        except (OSError, ValueError) as error:
            self._messages.put(error)
        finally:
            self._messages.put(None)

    def _trace(self, direction, message, wire_bytes):
        # Keep the immutable wire bytes, avoiding both timed JSON encoding and
        # later caller mutations of parsed result objects changing the evidence.
        self._trace_buffer.append((direction, time.perf_counter(), wire_bytes))

    def _read_stderr(self):
        try:
            for chunk in iter(lambda: self.process.stderr.read(65536), b""):
                self._stderr_buffer.append(chunk)
        except (OSError, ValueError):
            pass

    def _write_evidence(self):
        # Attempt both outputs even when one destination fails. This is called
        # only after request timing and process cleanup have finished.
        try:
            with self.log_path.open("wb") as log:
                log.writelines(self._stderr_buffer)
        finally:
            with self.wire_path.open("w", encoding="utf-8") as wire:
                for direction, at, raw in self._trace_buffer:
                    wire.write(json.dumps({
                        "direction": direction, "at_monotonic": at,
                        "bytes": len(raw), "message": json.loads(raw),
                    }, ensure_ascii=False) + "\n")

    def _send(self, message):
        raw = (json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        self._trace("send", message, raw)
        self.process.stdin.write(raw)
        self.process.stdin.flush()

    def _rpc(self, method, params=None):
        if self.closed:
            raise RuntimeError("Codex MCP client is closed")
        with self._lock:
            self.sequence += 1
            request_id = self.sequence
            message = {"id": request_id, "method": method}
            if params is not None:
                message["params"] = params
            started = time.perf_counter()
            self._send(message)
            deadline = started + self.timeout
            while True:
                remaining = deadline - time.perf_counter()
                if remaining <= 0:
                    raise TimeoutError("Codex %s timed out; request was not retried. Log: %s" % (method, self.log_path))
                try:
                    raw = self._messages.get(timeout=remaining)
                except queue.Empty:
                    raise TimeoutError("Codex %s timed out; request was not retried. Log: %s" % (method, self.log_path))
                if raw is None:
                    raise RuntimeError("Codex app-server exited during %s; inspect %s" % (method, self.log_path))
                if isinstance(raw, Exception):
                    raise RuntimeError("Codex stdout reader failed") from raw
                try:
                    response = json.loads(raw)
                except (UnicodeError, json.JSONDecodeError) as error:
                    raise RuntimeError("Codex app-server wrote non-JSON stdout; inspect %s" % self.log_path) from error
                self._trace("receive", response, raw)
                if not isinstance(response, dict):
                    raise RuntimeError("Codex app-server returned a non-object message")
                if "method" in response:
                    self.notifications.append(response)
                    if "id" in response:
                        raise RuntimeError("Codex requested client input; no automatic approval is implemented: " +
                                           json.dumps(response, ensure_ascii=False))
                    continue
                if response.get("id") != request_id:
                    # Retain late replies in the trace without confusing them with
                    # this request. The client never re-sends a timed-out action.
                    continue
                record = {
                    "method": method,
                    "elapsed_ms": (time.perf_counter() - started) * 1000,
                    "response_bytes": len(raw),
                    "response": response,
                    "response_wire": raw.decode("utf-8"),
                }
                self.rpc_records.append(record)
                if "error" in response:
                    raise RuntimeError("Codex %s: %s" % (method, json.dumps(response["error"], ensure_ascii=False)))
                return response.get("result", {}), record

    def status(self):
        """Discover the configured server through this actual Codex runtime."""
        cursor = None
        while True:
            arguments = {"threadId": self.thread_id, "detail": "toolsAndAuthOnly", "limit": 100}
            if cursor is not None:
                arguments["cursor"] = cursor
            result, _ = self._rpc("mcpServerStatus/list", arguments)
            for server in result.get("data", []):
                if server.get("name") == "deskloom":
                    return server
            cursor = result.get("nextCursor")
            if cursor is None:
                raise RuntimeError("deskloom is not configured in this Codex runtime")

    def call(self, tool, arguments=None):
        """Call DeskLoom through Codex; return JSON metadata, preserving receipts.

        ``records[-1]`` measures the complete outer JSON-RPC response line, so
        duplicated MCP text/structured content and image blocks count towards
        transport size. It is not merely the size of this parsed return value.
        """
        started = time.perf_counter()
        record = {"tool": tool, "arguments": arguments or {}}
        previous_rpc_count = len(self.rpc_records)
        try:
            result, wire_record = self._rpc("mcpServer/tool/call", {
                "threadId": self.thread_id, "server": "deskloom", "tool": tool,
                "arguments": arguments or {},
            })
            record.update(wire_record)
            parsed = result.get("structuredContent")
            if not isinstance(parsed, dict):
                parsed = None
                for content in result.get("content", []):
                    if content.get("type") == "text":
                        try:
                            candidate = json.loads(content.get("text", ""))
                        except json.JSONDecodeError:
                            continue
                        if isinstance(candidate, dict):
                            parsed = candidate
                            break
            if parsed is None:
                raise RuntimeError("DeskLoom returned no JSON tool metadata")
            # MCP carries screenshot bytes outside structuredContent. Restore
            # the native shape expected by acceptance checks without affecting
            # the original byte-count metric or stored response.
            parsed = dict(parsed)
            for content in result.get("content", []):
                if content.get("type") == "image":
                    parsed.setdefault("data", content.get("data"))
                    parsed.setdefault("mime_type", content.get("mimeType"))
                    break
            if result.get("isError"):
                raise RuntimeError("DeskLoom tool failed: " + json.dumps(parsed, ensure_ascii=False))
            return parsed
        except BaseException as error:
            if len(self.rpc_records) > previous_rpc_count:
                record.update(self.rpc_records[-1])
            record["error"] = str(error)
            raise
        finally:
            record["elapsed_ms"] = (time.perf_counter() - started) * 1000
            record.setdefault("response_bytes", None)
            self.records.append(record)

    def close(self):
        """Close this ephemeral runtime and its MCP processes, without retries."""
        if self.closed:
            return
        self.closed = True
        try:
            if self.process is not None:
                if self.process.stdin and not self.process.stdin.closed:
                    self.process.stdin.close()
                try:
                    self.process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait(timeout=5)
                if self.reader:
                    self.reader.join(timeout=5)
                if self.stderr_reader:
                    self.stderr_reader.join(timeout=5)
                if self.process.stdout:
                    self.process.stdout.close()
                if self.process.stderr:
                    self.process.stderr.close()
        finally:
            self._write_evidence()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
