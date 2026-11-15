#!/usr/bin/env python3
"""Resume the owned upstream baseline at six local jobs without source/GN edits.

Requires the recorded controlled stop, exact provenance, no concurrent executor,
and the same args.gn bytes. Produces its own log/receipt and never regenerates GN.
"""
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    root = Path('/data/yab-chromium-baseline')
    source = root / 'checkout/src'
    depot = root / 'tools/depot_tools'
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise RuntimeError('Only the explicitly owned Linux baseline is supported.')
    if json.loads((root / 'owner.json').read_text()).get('task') != 'yab-android-chromium-20261022':
        raise RuntimeError('Unexpected owner marker; preserve the directory.')
    stop = json.loads((root / 'attempts/build-j4-stop-receipt.json').read_text())
    if not stop.get('executorExited'):
        raise RuntimeError('Owned previous executor has not exited.')
    with (root / 'baseline.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # The previous runner has now released its lock and written final receipts.
        previous = json.loads((root / 'build-receipt.json').read_text())
        if previous['exitCode'] is None or previous.get('completed'):
            raise RuntimeError('Expected a completed controlled interruption, not a live or successful build.')
        cfg = json.loads((root / 'baseline.json').read_text())
        if hashlib.sha256((root / 'baseline.json').read_bytes()).hexdigest() != stop['configurationSha256']:
            raise RuntimeError('Baseline configuration changed; do not continue.')
        if hashlib.sha256((source / 'out/YabDesktopArm64/args.gn').read_bytes()).hexdigest() != stop['gnArgsSha256']:
            raise RuntimeError('GN arguments changed; do not continue.')
        for directory, expected in ((source, cfg['chromiumRevision']), (depot, cfg['depotToolsRevision'])):
            actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=directory, text=True).strip()
            if actual != expected:
                raise RuntimeError('Pinned source identity changed.')
            subprocess.run(['git', 'diff', '--quiet'], cwd=directory, check=True)
            subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=directory, check=True)
        for process in Path('/proc').iterdir():
            if not process.name.isdigit() or int(process.name) == os.getpid():
                continue
            try:
                argv = (process / 'cmdline').read_bytes().decode(errors='replace').split('\0')
                if len(argv) > 1 and argv[0] == str(source / 'third_party/siso/cipd/siso') and argv[1] == 'ninja':
                    raise RuntimeError('An existing owned siso executor is still running.')
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
        if shutil.disk_usage(root).free < cfg['minimumReserveBytes']:
            raise RuntimeError('Drive reserve is below the existing baseline requirement.')
        receipt_path = root / 'resume-build-receipt.json'
        if receipt_path.exists():
            raise RuntimeError('A resume attempt already exists; preserve it and inspect the result.')
        env = os.environ.copy()
        env.update(DEPOT_TOOLS_UPDATE='0', DEPOT_TOOLS_METRICS='0',
                   CIPD_CACHE_DIR=str(root / 'cache/cipd'),
                   VPYTHON_VIRTUALENV_ROOT=str(root / 'cache/vpython'),
                   XDG_CACHE_HOME=str(root / 'cache'), TMPDIR=str(root / 'tmp'),
                   PATH=env['PATH'] + ':' + str(depot))
        command = [str(depot / 'autoninja'), '-C', 'out/YabDesktopArm64', '-j6', cfg['target']]
        receipt = dict(startedAt=utc(), completed=False, exitCode=None, argv=command,
                       sourceRevision=cfg['chromiumRevision'], depotToolsRevision=cfg['depotToolsRevision'],
                       localJobs=6, configurationSha256=stop['configurationSha256'],
                       gnArgsSha256=stop['gnArgsSha256'], resumedAfterControlledStop=True,
                       previousCompletedActions=stop['completedActionsBeforeStop'],
                       freeBytesBefore=shutil.disk_usage(root).free,
                       runnerSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())

        def save():
            temporary = receipt_path.with_suffix('.json.tmp')
            temporary.write_text(json.dumps(receipt, indent=2) + '\n')
            temporary.replace(receipt_path)

        save()
        try:
            with (root / 'logs/build-j6.log').open('a', buffering=1) as log:
                log.write(utc() + ' ' + json.dumps(command) + '\n')
                result = subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
            receipt['exitCode'] = result.returncode
            if result.returncode == 0:
                artifacts = []
                for apk in sorted((source / 'out/YabDesktopArm64/apks').glob('*.apk')):
                    digest = hashlib.sha256()
                    with apk.open('rb') as stream:
                        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
                            digest.update(block)
                    artifacts.append(dict(path=str(apk), bytes=apk.stat().st_size, sha256=digest.hexdigest()))
                if not artifacts:
                    raise RuntimeError('Build returned success without an APK artifact.')
                receipt.update(completed=True, artifacts=artifacts)
        except Exception as error:
            receipt.update(error=str(error), exitCode=1)
        finally:
            receipt.update(finishedAt=utc(), freeBytesAfter=shutil.disk_usage(root).free)
            save()
        print(json.dumps(receipt))
        return receipt['exitCode']


if __name__ == '__main__':
    sys.exit(main())
