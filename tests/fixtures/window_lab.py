#!/usr/bin/env python3
"""Compile and own an isolated AppKit fixture for opt-in macOS acceptance.

Compile without opening windows: python3 tests/fixtures/window_lab.py --compile-only
"""
import argparse
import json
import pathlib
import plistlib
import subprocess
import tempfile
import time
import uuid


class WindowLab:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="deskloom-windowlab-")
        self.directory = pathlib.Path(self.temporary.name)
        self.token = uuid.uuid4().hex
        self.titles = [f"DeskLoom WindowLab {self.token} · {role}" for role in ("Source", "Destination")]
        self.bundle_id = "org.deskloom.tests.windowlab"
        self.bundle = self.directory / "WindowLab.app"
        self.executable = self.bundle / "Contents/MacOS/WindowLab"
        self.ready = self.directory / "ready.json"
        self.process = None
        self.log = None

    def compile(self):
        self.executable.parent.mkdir(parents=True, exist_ok=True)
        info = {"CFBundleExecutable": "WindowLab", "CFBundleIdentifier": self.bundle_id,
                "CFBundleName": "DeskLoom WindowLab", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1", "NSHighResolutionCapable": True,
                "NSPrincipalClass": "NSApplication"}
        (self.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        source = pathlib.Path(__file__).with_name("WindowLab.swift")
        result = subprocess.run(["/usr/bin/xcrun", "swiftc", str(source), "-framework", "AppKit",
                                 "-module-cache-path", str(self.directory / "ModuleCache"),
                                 "-o", str(self.executable)], capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise RuntimeError("WindowLab compilation failed:\n" + result.stderr)
        return self.executable

    def start(self):
        if self.process is not None:
            raise RuntimeError("WindowLab has already been started")
        if not self.executable.is_file():
            self.compile()
        self.log = (self.directory / "windowlab.log").open("w")
        self.process = subprocess.Popen([str(self.executable), "--token", self.token,
                                         "--ready-file", str(self.ready)], stdout=self.log, stderr=self.log)
        deadline = time.monotonic() + 20
        while not self.ready.exists():
            if self.process.poll() is not None:
                raise RuntimeError("WindowLab exited before creating its windows")
            if time.monotonic() >= deadline:
                raise TimeoutError("WindowLab did not create its windows")
            time.sleep(0.05)
        ready = json.loads(self.ready.read_text())
        if ready != {"pid": self.process.pid, "titles": self.titles, "bundle_id": self.bundle_id}:
            raise RuntimeError("WindowLab readiness identity does not match the owned fixture")
        return self

    def select_windows(self, call, count=2):
        """Only discover the exact PID and unique titles created by this instance."""
        if self.process is None or self.process.poll() is not None or count not in (1, 2):
            raise RuntimeError("WindowLab must be running with 1 or 2 requested windows")
        deadline = time.monotonic() + 20
        while True:
            response = call("computer_windows", {"pid": self.process.pid})
            windows = response["windows"]
            if any(window["pid"] != self.process.pid for window in windows):
                raise AssertionError("PID-scoped enumeration returned an unowned window")
            selected = []
            for title in self.titles[:count]:
                matches = [window for window in windows if window["title"] == title]
                if len(matches) > 1:
                    raise AssertionError("WindowLab title is not unique")
                if matches:
                    selected.append(matches[0])
            if len(selected) == count:
                return selected
            if self.process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError("Owned WindowLab windows were not found")
            time.sleep(0.1)

    def close(self):
        try:
            if self.process is not None and self.process.poll() is None:
                # Terminate only this Popen child; no app-name or global kill.
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        finally:
            if self.log is not None:
                self.log.close()
            self.temporary.cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile-only", action="store_true", required=True)
    parser.parse_args()
    fixture = WindowLab()
    try:
        fixture.compile()
        print("WindowLab compiled successfully; no application was launched.")
    finally:
        fixture.close()
