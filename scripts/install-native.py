#!/usr/bin/env python3
"""Install DeskLoom at its canonical path, preserving its established code identity."""
import datetime
import fcntl
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALLED = pathlib.Path('/Applications/DeskLoom.app')
RENAMED_FROM = pathlib.Path('/Applications/Computer Use Prototype.app')
LEGACY = ROOT / '.build/Computer Use Prototype.app'
# This internal identifier is intentionally stable across the product rename:
# changing it would invalidate the user's existing macOS privacy grants.
BUNDLE_ID = 'local.geb.ComputerUsePrototype'
EXECUTABLE = pathlib.Path('Contents/MacOS/DeskLoom')
LEGACY_EXECUTABLE = pathlib.Path('Contents/MacOS/ComputerUsePrototype')
ENDPOINT = pathlib.Path.home() / 'Library/Application Support/DeskLoom/endpoint.json'
LEGACY_ENDPOINT = pathlib.Path.home() / 'Library/Application Support/ComputerUsePrototype/endpoint.json'
CLI_PATH = pathlib.Path.home() / '.local/bin/dlm'


def cli_target():
    return INSTALLED / 'Contents/Resources/dlm'


def check_cli_destination():
    if CLI_PATH.is_symlink() and CLI_PATH.readlink() == cli_target():
        return
    if CLI_PATH.exists() or CLI_PATH.is_symlink():
        raise RuntimeError(f'Refusing to overwrite an unrelated CLI entry: {CLI_PATH}')


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True)


def check_bundle(app, legacy=False):
    if app.is_symlink():
        raise RuntimeError(f'Refusing to replace or install a symlink: {app}')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    expected_executable = LEGACY_EXECUTABLE if legacy else EXECUTABLE
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != expected_executable.name:
        raise RuntimeError(f'Unexpected application identity: {app}')
    if not legacy and any(not (app / 'Contents/Resources' / name).is_file()
                          for name in ('dlm', 'rpc.py')):
        raise RuntimeError(f'Bundled dlm CLI resources are missing: {app}')
    run('/usr/bin/codesign', '--verify', '--strict', app)


def requirement(app):
    result = run('/usr/bin/codesign', '-d', '-r-', app)
    for line in (result.stdout + result.stderr).splitlines():
        if line.startswith('designated => '):
            return line.removeprefix('designated => ')
    raise RuntimeError('Missing designated code requirement')


def status():
    endpoint = ENDPOINT if ENDPOINT.exists() else LEGACY_ENDPOINT
    config = json.loads(endpoint.read_text())
    request = urllib.request.Request(
        f"http://127.0.0.1:{config['port']}/rpc", b'{"method":"status","params":{}}',
        {'Authorization': 'Bearer ' + config['token'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=3) as response:
        result = json.load(response)
    if not result.get('ok'):
        raise RuntimeError('Cannot establish application state')
    return config['pid'], result['result']


def recognized_binary(command):
    # ps does not quote executable paths containing spaces. Match the complete
    # known command rather than splitting argv or accepting a path prefix.
    expected = {str(INSTALLED / EXECUTABLE), str(RENAMED_FROM / LEGACY_EXECUTABLE),
                str(LEGACY / LEGACY_EXECUTABLE)}
    for binary in expected:
        if command in (binary, binary + ' --background'):
            return binary
    return None


def running_instances():
    instances = []
    for line in run('/bin/ps', '-axo', 'pid=,args=').stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            binary = recognized_binary(parts[1])
            if binary is not None:
                instances.append((int(parts[0]), binary))
    return instances


def stop_verified_process(pid, binary):
    # Recheck immediately before signalling to avoid acting on a stale PID.
    command = run('/bin/ps', '-p', pid, '-o', 'args=').stdout.strip()
    if recognized_binary(command) != binary:
        raise RuntimeError('Application process changed during installation')
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 8
    while any(item[0] == pid for item in running_instances()):
        if time.monotonic() >= deadline:
            raise RuntimeError('DeskLoom did not exit; refusing to replace its bundle')
        time.sleep(.1)


def stop_idle_instance():
    instances = running_instances()
    if not instances:
        return None
    if len(instances) != 1:
        raise RuntimeError('Multiple DeskLoom or legacy instances are running; close them before installing')
    pid, binary = instances[0]
    endpoint_pid, before = status()
    if endpoint_pid != pid or before.get('active'):
        raise RuntimeError('Stop the desktop control session before installing; no running action was interrupted')
    if before.get('controller_application_path') != str(pathlib.Path(binary).parents[2]):
        raise RuntimeError('Running application path does not match the local endpoint')
    stop_verified_process(pid, binary)
    return before


def stop_failed_candidate():
    # The old instance was stopped before replacement, so any instance at the
    # installed path belongs to this candidate. A failed startup may have no RPC.
    instances = [item for item in running_instances()
                 if item[1] == str(INSTALLED / EXECUTABLE)]
    if len(instances) > 1:
        raise RuntimeError('Multiple candidate instances are running; recovery files were retained')
    if not instances:
        return
    pid, binary = instances[0]
    try:
        endpoint_pid, current = status()
    except (OSError, ValueError, KeyError, RuntimeError):
        pass
    else:
        if endpoint_pid == pid and current.get('active'):
            raise RuntimeError('Candidate has an active control session; recovery files were retained')
    stop_verified_process(pid, binary)


def wait_for_installed_application():
    deadline = time.monotonic() + 12
    while True:
        try:
            pid, after = status()
            if (after.get('controller_application_path') == str(INSTALLED) and
                    (pid, str(INSTALLED / EXECUTABLE)) in running_instances()):
                return pid, after
        except (OSError, ValueError, KeyError, RuntimeError):
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError('Candidate application endpoint did not become ready')
        time.sleep(.2)


def install(source):
    check_bundle(source)
    check_cli_destination()
    new_requirement = requirement(source)
    if 'cdhash' in new_requirement.lower() or 'anchor apple generic' not in new_requirement:
        raise RuntimeError('A stable Apple development/distribution signature is required')
    if INSTALLED.exists() and RENAMED_FROM.exists():
        raise RuntimeError('Both DeskLoom and the old application exist; refusing an ambiguous replacement')
    previous_app = INSTALLED if INSTALLED.exists() else RENAMED_FROM
    previous_requirement = None
    if previous_app.exists():
        check_bundle(previous_app, legacy=previous_app == RENAMED_FROM)
        previous_requirement = requirement(previous_app)
        # Matching the old requirement is what matters for existing TCC grants.
        run('/usr/bin/codesign', '--verify', '--strict', '-R', '=' + previous_requirement, source)
    if LEGACY.exists():
        check_bundle(LEGACY, legacy=True)
        if (ROOT / '.build/legacy-before-install.zip').exists():
            raise RuntimeError('Legacy archive already exists; refusing to overwrite it')

    # Build/copy/verify completely before stopping the app. Keep the previous
    # bundle on the same volume until the replacement has actually started.
    # Manage cleanup explicitly so a failed rollback cannot delete the backup.
    stage = pathlib.Path(tempfile.mkdtemp(prefix='.DeskLoom-install-', dir='/Applications'))
    remove_stage = True
    try:
        incoming = stage / INSTALLED.name
        backup = stage / 'previous.app'
        run('/usr/bin/ditto', source, incoming)
        check_bundle(incoming)
        if LEGACY.exists():
            run('/usr/bin/ditto', '-c', '-k', '--keepParent', LEGACY,
                stage / 'legacy-before-install.zip')
        before = stop_idle_instance()
        had_previous = previous_app.exists()
        candidate_installed = False
        created_cli = False
        try:
            if had_previous:
                previous_app.rename(backup)
                remove_stage = False
            incoming.rename(INSTALLED)
            candidate_installed = True
            remove_stage = False
            check_bundle(INSTALLED)
            run('/usr/bin/open', '-g', INSTALLED, '--args', '--background')
            pid, after = wait_for_installed_application()
            check_cli_destination()
            if not CLI_PATH.is_symlink():
                CLI_PATH.parent.mkdir(parents=True, exist_ok=True)
                # symlink_to is exclusive: a newly appeared unrelated file is
                # never replaced, even after the earlier preflight check.
                CLI_PATH.symlink_to(cli_target())
                created_cli = True
            if LEGACY.exists():
                (stage / 'legacy-before-install.zip').rename(ROOT / '.build/legacy-before-install.zip')
        except Exception:
            try:
                if created_cli and CLI_PATH.is_symlink() and CLI_PATH.readlink() == cli_target():
                    CLI_PATH.unlink()
                if candidate_installed:
                    stop_failed_candidate()
                    if INSTALLED.exists():
                        INSTALLED.rename(stage / 'failed.app')
                if backup.exists():
                    backup.rename(previous_app)
                # The previous bundle is safely back in place. Restore whichever
                # verified copy was running, including the first-install legacy.
                remove_stage = True
                if before:
                    run('/usr/bin/open', '-g', before['controller_application_path'], '--args', '--background')
            except Exception as recovery_error:
                remove_stage = False
                raise RuntimeError(
                    f'Installation and automatic recovery did not finish; recovery files retained at {stage}'
                ) from recovery_error
            raise
        remove_stage = True
    finally:
        if remove_stage:
            shutil.rmtree(stage)

    # Retire the generated development copy so Finder/Launch Services cannot
    # keep launching it. Keep a recoverable archive outside the installed app.
    if LEGACY.exists():
        shutil.rmtree(LEGACY)

    report = {
        'installed_at': datetime.datetime.now().astimezone().isoformat(),
        'application_path': str(INSTALLED),
        'renamed_from': str(RENAMED_FROM) if had_previous and previous_app == RENAMED_FROM else None,
        'cli_path': str(CLI_PATH),
        'bundle_id': BUNDLE_ID,
        'previous_requirement_matched': True if previous_requirement else None,
        'designated_requirement_unchanged': previous_requirement == new_requirement if previous_requirement else None,
        'adhoc': False,
        'previous_permissions': {key: before[key] for key in ('accessibility', 'screen_recording')} if before else None,
        'current_permissions': {key: after[key] for key in ('accessibility', 'screen_recording')},
        'running_pid': pid,
    }
    (ROOT / '.runtime/installation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        (ROOT / '.runtime').mkdir(exist_ok=True)
        with (ROOT / '.runtime/install.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            install(pathlib.Path(sys.argv[1]).resolve())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        # Avoid leaking code requirements containing certificate personal data.
        message = f'Command failed (exit {error.returncode})' if isinstance(error, subprocess.CalledProcessError) else str(error)
        raise SystemExit('Install failed: ' + message)
