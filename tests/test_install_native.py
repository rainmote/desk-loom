"""Isolated installer recovery tests; never accesses the real installed app."""
import contextlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/install-native.py'
SPEC = importlib.util.spec_from_file_location('isolated_native_installer', SCRIPT)
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class InstallerRecoveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='native-installer-test-')
        self.addCleanup(temporary.cleanup)
        self.directory = pathlib.Path(temporary.name)
        self.project = self.directory / 'project'
        self.applications = self.directory / 'Applications'
        self.installed = self.applications / 'DeskLoom.app'
        self.renamed_from = self.applications / 'Computer Use Prototype.app'
        self.legacy = self.project / '.build/Computer Use Prototype.app'
        self.source = self.directory / 'candidate/DeskLoom.app'
        self.cli = self.directory / '.local/bin/dlm'
        (self.project / '.runtime').mkdir(parents=True)
        (self.project / '.build').mkdir()
        self.applications.mkdir()
        self.make_bundle(self.installed, 'old')
        self.make_bundle(self.source, 'new')
        self.stages = []
        self.opened = []
        self.reject_requirement = False
        self.fail_first_open = False
        self.expected_requirement = 'identifier "test.prototype" and anchor apple generic'
        self.before = {
            'controller_application_path': str(self.installed),
            'accessibility': False,
            'screen_recording': False,
            'active': False,
        }

        self.mocks = contextlib.ExitStack()
        self.addCleanup(self.mocks.close)
        for name, value in (
            ('ROOT', self.project),
            ('INSTALLED', self.installed),
            ('RENAMED_FROM', self.renamed_from),
            ('LEGACY', self.legacy),
            ('ENDPOINT', self.directory / 'endpoint.json'),
            ('LEGACY_ENDPOINT', self.directory / 'legacy-endpoint.json'),
            ('CLI_PATH', self.cli),
        ):
            self.mocks.enter_context(mock.patch.object(INSTALLER, name, value))

        original_mkdtemp = tempfile.mkdtemp

        def isolated_stage(*, prefix, dir):
            # The production constant must never be passed to the real API.
            self.assertEqual('/Applications', dir)
            path = pathlib.Path(original_mkdtemp(prefix=prefix, dir=self.applications))
            self.stages.append(path)
            return str(path)

        self.create_stage = self.mocks.enter_context(
            mock.patch.object(INSTALLER.tempfile, 'mkdtemp', side_effect=isolated_stage))
        self.mocks.enter_context(mock.patch.object(INSTALLER, 'run', side_effect=self.fake_run))
        self.mocks.enter_context(mock.patch.object(INSTALLER, 'check_bundle', side_effect=self.check_bundle))
        self.mocks.enter_context(mock.patch.object(INSTALLER, 'requirement', return_value=self.expected_requirement))
        self.stop_old = self.mocks.enter_context(
            mock.patch.object(INSTALLER, 'stop_idle_instance', return_value=self.before))
        self.stop_candidate = self.mocks.enter_context(mock.patch.object(INSTALLER, 'stop_failed_candidate'))
        self.wait_ready = self.mocks.enter_context(mock.patch.object(INSTALLER, 'wait_for_installed_application'))

        # Defense in depth: even an accidental call outside the fake interfaces
        # must fail before contacting a process, RPC endpoint, or system command.
        for owner, name in (
            (INSTALLER, 'status'),
            (INSTALLER, 'running_instances'),
            (INSTALLER, 'stop_verified_process'),
            (INSTALLER.subprocess, 'run'),
            (INSTALLER.os, 'kill'),
            (INSTALLER.urllib.request, 'urlopen'),
        ):
            self.mocks.enter_context(mock.patch.object(
                owner, name, side_effect=AssertionError(f'Forbidden real operation: {name}')))

    def local_path(self, path):
        path = pathlib.Path(path)
        self.assertTrue(path.is_relative_to(self.directory), f'Path escaped test directory: {path}')
        return path

    def make_bundle(self, path, marker):
        self.local_path(path).mkdir(parents=True)
        (path / 'version.txt').write_text(marker)

    def check_bundle(self, path, legacy=False):
        self.assertTrue((self.local_path(path) / 'version.txt').is_file())

    def version(self, path):
        return (self.local_path(path) / 'version.txt').read_text()

    def fake_run(self, *args):
        command = str(args[0])
        if command == '/usr/bin/codesign':
            self.assertEqual(('--verify', '--strict', '-R'), args[1:4])
            self.assertEqual('=' + self.expected_requirement, args[4])
            self.local_path(args[5])
            if self.reject_requirement:
                raise subprocess.CalledProcessError(1, ['mock-codesign'])
        elif command == '/usr/bin/ditto':
            if args[1:4] == ('-c', '-k', '--keepParent'):
                self.check_bundle(args[4])
                self.local_path(args[5]).write_bytes(b'isolated legacy archive')
            else:
                source, target = (self.local_path(path) for path in args[1:])
                shutil.copytree(source, target)
        elif command == '/usr/bin/open':
            self.assertEqual('-g', args[1], 'Automatic relaunch must preserve foreground focus')
            self.assertEqual(['--args', '--background'], list(args[3:]))
            path = self.local_path(args[2])
            self.opened.append(path)
            if self.fail_first_open and len(self.opened) == 1:
                raise subprocess.CalledProcessError(1, ['mock-open'])
        else:
            self.fail(f'Unexpected system command: {command}')
        return subprocess.CompletedProcess(['mock-command'], 0, '', '')

    def fail_readiness(self):
        self.assertEqual('new', self.version(self.installed))
        self.assertEqual('old', self.version(self.stages[0] / 'previous.app'))
        raise RuntimeError('simulated readiness failure')

    def test_readiness_failure_restores_previous_bundle(self):
        self.wait_ready.side_effect = self.fail_readiness
        with self.assertRaisesRegex(RuntimeError, 'simulated readiness failure'):
            INSTALLER.install(self.source)

        self.assertEqual('old', self.version(self.installed))
        self.assertEqual('new', self.version(self.source))
        self.assertEqual([self.installed, self.installed], self.opened)
        self.stop_old.assert_called_once_with()
        self.stop_candidate.assert_called_once_with()
        self.assertFalse(self.stages[0].exists())

    def test_open_failure_restores_previous_bundle(self):
        self.fail_first_open = True
        with self.assertRaises(subprocess.CalledProcessError):
            INSTALLER.install(self.source)

        self.assertEqual('old', self.version(self.installed))
        self.assertEqual([self.installed, self.installed], self.opened)
        self.wait_ready.assert_not_called()
        self.stop_candidate.assert_called_once_with()
        self.assertFalse(self.stages[0].exists())

    def test_rollback_failure_retains_backup(self):
        self.wait_ready.side_effect = self.fail_readiness
        self.stop_candidate.side_effect = RuntimeError('simulated candidate stop failure')
        with self.assertRaisesRegex(RuntimeError, 'recovery files retained') as caught:
            INSTALLER.install(self.source)

        self.assertEqual('new', self.version(self.installed))
        self.assertEqual('old', self.version(self.stages[0] / 'previous.app'))
        self.assertIn(str(self.stages[0]), str(caught.exception))
        self.assertEqual([self.installed], self.opened)

    def test_signature_rejection_does_not_stop_old_process(self):
        self.reject_requirement = True
        with self.assertRaises(subprocess.CalledProcessError):
            INSTALLER.install(self.source)

        self.assertEqual('old', self.version(self.installed))
        self.stop_old.assert_not_called()
        self.stop_candidate.assert_not_called()
        self.create_stage.assert_not_called()
        self.assertEqual([], self.opened)

    def test_first_install_readiness_failure_preserves_legacy_copy(self):
        shutil.rmtree(self.installed)
        self.make_bundle(self.legacy, 'legacy')
        self.before['controller_application_path'] = str(self.legacy)
        self.wait_ready.side_effect = RuntimeError('simulated readiness failure')
        with self.assertRaisesRegex(RuntimeError, 'simulated readiness failure'):
            INSTALLER.install(self.source)

        self.assertFalse(self.installed.exists())
        self.assertEqual('legacy', self.version(self.legacy))
        self.assertEqual([self.installed, self.legacy], self.opened)
        self.assertFalse((self.project / '.build/legacy-before-install.zip').exists())
        self.assertFalse(self.stages[0].exists())

    def move_old_app_to_legacy_name(self):
        self.installed.rename(self.renamed_from)
        self.before['controller_application_path'] = str(self.renamed_from)

    def test_rename_success_removes_old_name_and_installs_cli(self):
        self.move_old_app_to_legacy_name()
        self.wait_ready.return_value = (123, dict(self.before, controller_application_path=str(self.installed)))
        INSTALLER.install(self.source)

        self.assertFalse(self.renamed_from.exists())
        self.assertEqual('new', self.version(self.installed))
        self.assertEqual(INSTALLER.cli_target(), self.cli.readlink())
        report = json.loads((self.project / '.runtime/installation.json').read_text())
        self.assertEqual(str(self.renamed_from), report['renamed_from'])
        self.assertTrue(report['previous_requirement_matched'])
        self.assertFalse(self.stages[0].exists())

    def test_rename_failure_restores_original_path(self):
        self.move_old_app_to_legacy_name()
        self.wait_ready.side_effect = self.fail_readiness
        with self.assertRaisesRegex(RuntimeError, 'simulated readiness failure'):
            INSTALLER.install(self.source)

        self.assertFalse(self.installed.exists())
        self.assertEqual('old', self.version(self.renamed_from))
        self.assertEqual([self.installed, self.renamed_from], self.opened)
        self.assertFalse(self.cli.is_symlink())

    def test_rename_signature_rejection_preserves_old_app(self):
        self.move_old_app_to_legacy_name()
        self.reject_requirement = True
        with self.assertRaises(subprocess.CalledProcessError):
            INSTALLER.install(self.source)

        self.assertFalse(self.installed.exists())
        self.assertEqual('old', self.version(self.renamed_from))
        self.stop_old.assert_not_called()
        self.create_stage.assert_not_called()

    def test_unrelated_cli_is_preserved_before_app_is_stopped(self):
        self.cli.parent.mkdir(parents=True)
        self.cli.write_text('unrelated user command')
        with self.assertRaisesRegex(RuntimeError, 'unrelated CLI entry'):
            INSTALLER.install(self.source)
        self.assertEqual('unrelated user command', self.cli.read_text())
        self.stop_old.assert_not_called()

    def test_existing_owned_cli_is_reused(self):
        self.cli.parent.mkdir(parents=True)
        self.cli.symlink_to(INSTALLER.cli_target())
        self.wait_ready.return_value = (123, self.before)
        INSTALLER.install(self.source)
        self.assertEqual(INSTALLER.cli_target(), self.cli.readlink())


class InstallerProcessIdentityTests(unittest.TestCase):
    def setUp(self):
        self.mocks = contextlib.ExitStack()
        self.addCleanup(self.mocks.close)
        for name, value in (
            ('INSTALLED', pathlib.Path('/Applications With Spaces/DeskLoom.app')),
            ('RENAMED_FROM', pathlib.Path('/Applications With Spaces/Computer Use Prototype.app')),
            ('LEGACY', pathlib.Path('/Source With Spaces/.build/Computer Use Prototype.app')),
        ):
            self.mocks.enter_context(mock.patch.object(INSTALLER, name, value))
        self.run = self.mocks.enter_context(mock.patch.object(INSTALLER, 'run'))
        self.kill = self.mocks.enter_context(mock.patch.object(INSTALLER.os, 'kill'))
        # All process observations and signals stay mocked in these tests.
        self.mocks.enter_context(mock.patch.object(
            INSTALLER.subprocess, 'run', side_effect=AssertionError('Forbidden real process access')))

    def ps_output(self, value):
        self.run.return_value = subprocess.CompletedProcess(['mock-ps'], 0, value, '')

    def test_plain_and_background_processes_keep_canonical_paths_with_spaces(self):
        binaries = [str(INSTALLER.INSTALLED / INSTALLER.EXECUTABLE),
                    str(INSTALLER.RENAMED_FROM / INSTALLER.LEGACY_EXECUTABLE),
                    str(INSTALLER.LEGACY / INSTALLER.LEGACY_EXECUTABLE)]
        rows, expected = [], []
        for index, binary in enumerate(binaries):
            for offset, suffix in enumerate(('', ' --background')):
                pid = 100 + index * 2 + offset
                rows.append(f'  {pid} {binary}{suffix}')
                expected.append((pid, binary))
        self.ps_output('\n'.join(rows) + '\n')
        self.assertEqual(expected, INSTALLER.running_instances())
        self.kill.assert_not_called()

    def test_unknown_arguments_and_prefix_lookalikes_are_rejected(self):
        binary = str(INSTALLER.INSTALLED / INSTALLER.EXECUTABLE)
        commands = [binary + ' --unknown', binary + ' --background --unknown',
                    binary + ' --background=1', binary + ' --backgrounded',
                    binary + 'Helper', binary + '/helper', '/wrapper ' + binary]
        self.ps_output('\n'.join(f'{200 + index} {command}'
                                 for index, command in enumerate(commands)))
        self.assertEqual([], INSTALLER.running_instances())
        self.kill.assert_not_called()

    def test_stop_rechecks_plain_or_background_command_before_signalling(self):
        binary = str(INSTALLER.INSTALLED / INSTALLER.EXECUTABLE)
        with mock.patch.object(INSTALLER, 'running_instances', return_value=[]):
            for suffix in ('', ' --background'):
                with self.subTest(suffix=suffix):
                    self.kill.reset_mock()
                    self.ps_output(binary + suffix + '\n')
                    INSTALLER.stop_verified_process(123, binary)
                    self.kill.assert_called_once_with(123, INSTALLER.signal.SIGTERM)

    def test_stop_rejects_changed_process_without_sending_a_signal(self):
        binary = str(INSTALLER.INSTALLED / INSTALLER.EXECUTABLE)
        commands = [binary + 'Helper', binary + ' --unknown',
                    binary + ' --background --unknown',
                    str(INSTALLER.RENAMED_FROM / INSTALLER.LEGACY_EXECUTABLE) + ' --background']
        for command in commands:
            with self.subTest(command=command):
                self.kill.reset_mock()
                self.ps_output(command + '\n')
                with self.assertRaisesRegex(RuntimeError, 'process changed'):
                    INSTALLER.stop_verified_process(123, binary)
                self.kill.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
