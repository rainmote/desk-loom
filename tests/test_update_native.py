#!/usr/bin/env python3
"""Exercise the updater only against temporary source trees and fake builds."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).resolve().parents[1] / 'scripts/update-native.py'


class UpdateNativeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='computer-use-update-test-')
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'project with spaces'
        self.scripts = self.source / 'scripts'
        self.scripts.mkdir(parents=True)
        self.runner = self.scripts / RUNNER.name
        shutil.copy2(RUNNER, self.runner)
        self.build = self.scripts / 'build-native.sh'
        self.data = self.root / 'application support'
        self.command = [sys.executable, str(self.runner), '--launch', '--source', str(self.source),
                        '--data-directory', str(self.data)]

    def tearDown(self):
        # Release a barrier even if an assertion failed. The fake script also
        # times out itself, so no detached test build can remain indefinitely.
        (self.source / 'release').touch()
        self.wait_until(lambda: not self.locked(), timeout=7)
        self.temporary.cleanup()

    def wait_until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(.02)
        self.fail('Timed out waiting for the isolated updater fixture')

    def state(self):
        path = self.data / 'update-state.json'
        return json.loads(path.read_text()) if path.exists() else {}

    def locked(self):
        path = self.data / 'update.lock'
        if not path.exists():
            return False
        with path.open('r+') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(lock, fcntl.LOCK_UN)
            return False

    def launch(self):
        return subprocess.run(self.command, capture_output=True, text=True, timeout=5)

    def wait_for_terminal_state(self):
        def completed():
            value = self.state()
            return value if value.get('state') in ('succeeded', 'failed') else None
        return self.wait_until(completed)

    def test_detached_worker_survives_launcher_and_excludes_concurrent_update(self):
        self.build.write_text(
            '#!/bin/bash\nset -eu\n'
            'printf "fixture started\\n"\n'
            'touch started\n'
            'for attempt in {1..100}; do\n'
            '  if [ -e release ]; then\n'
            '    printf "built\\n" >> marker.txt\n'
            '    exit 0\n'
            '  fi\n'
            '  sleep 0.05\n'
            'done\n'
            'exit 23\n'
        )
        first = self.launch()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.wait_until(lambda: (self.source / 'started').exists())
        running = self.state()
        self.assertEqual(running['state'], 'running')
        # launch() has already waited for the launcher to exit. The worker has
        # an independent session and is still holding the inherited lock.
        self.assertEqual(os.getsid(running['pid']), running['pid'])
        self.assertNotEqual(os.getsid(running['pid']), os.getsid(0))
        self.assertTrue(self.locked())

        second = self.launch()
        self.assertEqual(second.returncode, 2)
        self.assertIn('进行中', second.stderr)
        self.assertEqual(self.state()['run_id'], running['run_id'])
        self.assertIn('fixture started', (self.data / 'update.log').read_text())

        (self.source / 'release').touch()
        finished = self.wait_for_terminal_state()
        self.assertEqual(finished['state'], 'succeeded')
        self.assertEqual(finished['run_id'], running['run_id'])
        self.assertEqual((self.source / 'marker.txt').read_text().splitlines(), ['built'])
        self.wait_until(lambda: not self.locked())

    def test_failed_build_keeps_error_and_log(self):
        self.build.write_text('#!/bin/bash\nprintf "fixture failure\\n" >&2\nexit 17\n')
        self.assertEqual(self.launch().returncode, 0)
        result = self.wait_for_terminal_state()
        self.assertEqual(result['state'], 'failed')
        self.assertIn('17', result['message'])
        self.assertEqual(result['log_path'], str(self.data / 'update.log'))
        self.assertIn('fixture failure', (self.data / 'update.log').read_text())

    def test_missing_build_script_reports_failure_without_building(self):
        self.assertFalse(self.build.exists())
        self.assertEqual(self.launch().returncode, 1)
        result = self.state()
        self.assertEqual(result['state'], 'failed')
        self.assertIn('找不到本地构建脚本', result['message'])
        self.assertFalse((self.data / 'update.log').exists())
        self.assertFalse(self.locked())

    def test_status_and_log_are_private_including_reused_log(self):
        self.data.mkdir()
        log = self.data / 'update.log'
        log.write_text('previous update\n')
        log.chmod(0o666)
        self.build.write_text('#!/bin/bash\nprintf "new fixture output\\n"\n')
        self.assertEqual(self.launch().returncode, 0)
        self.assertEqual(self.wait_for_terminal_state()['state'], 'succeeded')
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.data / 'update-state.json').stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.data / 'update.lock').stat().st_mode), 0o600)
        self.assertEqual(log.read_text(), 'new fixture output\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
