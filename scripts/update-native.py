#!/usr/bin/env python3
"""Rebuild this local source tree independently of the application being replaced."""
import argparse
import datetime
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import uuid


def write_state(directory, run_id, state, message):
    value = {
        'run_id': run_id,
        'state': state,
        'message': message,
        'pid': os.getpid(),
        'updated_at': datetime.datetime.now().astimezone().isoformat(),
        'log_path': str(directory / 'update.log'),
    }
    fd, temporary = tempfile.mkstemp(prefix='.update-state-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        os.replace(temporary, directory / 'update-state.json')
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_source(source):
    if source != pathlib.Path(__file__).resolve().parent.parent:
        raise RuntimeError('更新配置与本地源码位置不一致，请从项目重新构建安装。')
    if not (source / 'scripts/build-native.sh').is_file():
        raise RuntimeError('找不到本地构建脚本，无法更新。')


def launch(source, directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_fd = os.open(directory / 'update.lock', os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('本地更新已在进行中。', file=sys.stderr)
            return 2
        run_id = str(uuid.uuid4())
        try:
            validate_source(source)
            log_fd = os.open(directory / 'update.log', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.fchmod(log_fd, 0o600)
            with os.fdopen(log_fd, 'wb') as log:
                write_state(directory, run_id, 'running', '正在从本地源码构建；完成后应用会自动重启。')
                subprocess.Popen(
                    [sys.executable, str(pathlib.Path(__file__).resolve()), '--worker',
                     '--source', str(source), '--data-directory', str(directory),
                     '--run-id', run_id, '--lock-fd', str(lock_fd)],
                    cwd=source, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                    start_new_session=True, close_fds=True, pass_fds=(lock_fd,),
                )
            # The worker inherited the same flock file description. Closing the
            # launcher's descriptor keeps the lock held until that worker exits.
            return 0
        except (OSError, RuntimeError, ValueError) as error:
            write_state(directory, run_id, 'failed', str(error))
            return 1
    finally:
        os.close(lock_fd)


def worker(source, directory, run_id, lock_fd):
    try:
        # Keep this inherited descriptor alive throughout build and installation.
        # It excludes a second update even after the old app has been terminated.
        os.fstat(lock_fd)
        validate_source(source)
        write_state(directory, run_id, 'running', '正在从本地源码构建；完成后应用会自动重启。')
        environment = os.environ.copy()
        environment['PATH'] = os.pathsep.join([
            str(pathlib.Path(sys.executable).parent), '/usr/bin', '/bin', '/usr/sbin', '/sbin',
            environment.get('PATH', ''),
        ])
        result = subprocess.run(['/bin/bash', str(source / 'scripts/build-native.sh')],
                                cwd=source, env=environment, stdin=subprocess.DEVNULL)
        if result.returncode != 0:
            write_state(directory, run_id, 'failed',
                        f'本地构建或安装失败（退出码 {result.returncode}）。日志：{directory / "update.log"}')
            return 1
        write_state(directory, run_id, 'succeeded', '已从本地源码更新并重新启动，应用签名身份保持不变。')
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        write_state(directory, run_id, 'failed', f'更新未完成：{error}')
        return 1
    finally:
        os.close(lock_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--launch', action='store_true')
    mode.add_argument('--worker', action='store_true')
    parser.add_argument('--source', required=True, type=pathlib.Path)
    parser.add_argument('--data-directory', required=True, type=pathlib.Path)
    parser.add_argument('--run-id')
    parser.add_argument('--lock-fd', type=int)
    args = parser.parse_args()
    source, directory = args.source.resolve(), args.data_directory.resolve()
    if args.launch:
        return launch(source, directory)
    if args.run_id is None or args.lock_fd is None:
        parser.error('worker requires the inherited lock and run identifier')
    return worker(source, directory, args.run_id, args.lock_fd)


if __name__ == '__main__':
    raise SystemExit(main())
