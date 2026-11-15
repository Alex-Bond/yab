#!/usr/bin/env python3
"""Gracefully checkpoint only this explicitly identified owned Linux build.

No source, configuration, generated output or cache is removed. A new use needs
fresh explicit stop authorization and exact PID/start/runner values.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import time


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def process(pid):
    path = Path('/proc') / str(pid)
    fields = (path / 'stat').read_text().split()
    return {'pid': pid, 'parent': int(fields[3]), 'startTicks': int(fields[21]),
            'state': fields[2], 'argv': (path / 'cmdline').read_bytes().decode().rstrip('\0').split('\0')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--start-ticks', type=int, required=True)
    parser.add_argument('--runner-pid', type=int, required=True)
    args = parser.parse_args()
    root = Path('/data/yab-chromium-baseline')
    source = root / 'checkout/src'
    destination = root / 'attempts/build-j6-user-scope-stop-receipt.json'
    if destination.exists():
        raise RuntimeError('Preserve the existing controlled-stop receipt.')
    if json.loads((root / 'owner.json').read_text()).get('task') != 'yab-android-chromium-20261022':
        raise RuntimeError('Unexpected ownership marker.')
    previous = json.loads((root / 'resume-build-receipt.json').read_text())
    if previous['exitCode'] is not None or previous['completed'] or previous['localJobs'] != 6:
        raise RuntimeError('Expected the exact active six-job incremental attempt.')
    expected = [str(source / 'third_party/siso/cipd/siso'), 'ninja', '--offline',
                '-C', 'out/YabDesktopArm64', '-local_jobs=6', 'chrome_public_apk']
    pinned_hashes = {'configurationSha256': (root / 'baseline.json'),
                     'gnArgsSha256': source / 'out/YabDesktopArm64/args.gn'}
    for key, path in pinned_hashes.items():
        if hashlib.sha256(path.read_bytes()).hexdigest() != previous[key]:
            raise RuntimeError('Pinned configuration drift.')
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip() != previous['sourceRevision']:
        raise RuntimeError('Pinned source drift.')
    for command in (['git', 'diff', '--quiet'], ['git', 'diff', '--cached', '--quiet']):
        subprocess.run(command, cwd=source, check=True)
    pidfd = os.pidfd_open(args.pid)
    try:
        captured = process(args.pid)
        if captured['startTicks'] != args.start_ticks or captured['argv'] != expected:
            raise RuntimeError('Executor PID/start/command mismatch.')
        if (Path('/proc') / str(args.pid) / 'cwd').resolve() != source / 'out/YabDesktopArm64':
            raise RuntimeError('Executor working directory mismatch.')
        chain = []
        parent = captured['parent']
        for _ in range(8):
            row = process(parent)
            chain.append(row)
            if parent == args.runner_pid:
                break
            parent = row['parent']
        if not chain or chain[-1]['pid'] != args.runner_pid or chain[-1]['argv'] != ['python3', str(root / 'resume-build.py')]:
            raise RuntimeError('The executor is not owned by the recorded baseline runner.')
        processes = {}
        for path in Path('/proc').iterdir():
            if not path.name.isdigit():
                continue
            try:
                processes[int(path.name)] = process(int(path.name))
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                pass
        descendants = {args.pid}
        for _ in range(12):
            added = {pid for pid, row in processes.items() if row['parent'] in descendants}
            if added <= descendants:
                break
            descendants |= added
        log = root / 'logs/build-j6.log'
        with log.open('rb') as stream:
            stream.seek(max(0, log.stat().st_size - 32768))
            tail = stream.read().decode(errors='replace')
        counters = re.findall(r'\[(\d+)/(\d+)\]', tail)
        receipt = {'reason': 'user deferred extensions to a later release', 'startedAt': utc(),
                   'baselineCommandId': 'cmd_ef0c4c93634447868731c4879cbc',
                   'preflightCommandId': 'cmd_efb391afc7a441ffab26323a73b0',
                   'executor': captured, 'runnerPid': args.runner_pid,
                   'signal': 'SIGINT via pidfd', 'signalSent': False, 'executorExited': False,
                   'completedActionsBeforeStop': int(counters[-1][0]) if counters else None,
                   'dynamicTotalActionsBeforeStop': int(counters[-1][1]) if counters else None,
                   'freeBytesBefore': shutil.disk_usage(root).free,
                   'sourceRevision': previous['sourceRevision'],
                   'configurationSha256': previous['configurationSha256'],
                   'gnArgsSha256': previous['gnArgsSha256'],
                   'cacheDeleted': False, 'sourceModified': False, 'configurationModified': False}

        def save():
            temporary = destination.with_suffix('.json.tmp')
            temporary.write_text(json.dumps(receipt, indent=2) + '\n')
            temporary.replace(destination)

        save()
        # Revalidate immediately before signalling; pidfd cannot target a reused PID.
        if process(args.pid)['startTicks'] != args.start_ticks:
            raise RuntimeError('Executor identity changed before stop.')
        signal.pidfd_send_signal(pidfd, signal.SIGINT)
        receipt.update(signalSent=True, signalSentAt=utc())
        save()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline and not select.select([pidfd], [], [], 0)[0]:
            time.sleep(0.25)
        receipt['executorExited'] = bool(select.select([pidfd], [], [], 0)[0])
        receipt['executorExitObservedAt'] = utc()
        final_deadline = time.monotonic() + 5
        while time.monotonic() < final_deadline:
            final = json.loads((root / 'resume-build-receipt.json').read_text())
            if final['exitCode'] is not None:
                break
            time.sleep(0.25)
        receipt['runnerExitCode'] = final['exitCode']
        receipt['runnerCompleted'] = final['completed']
        retained = []
        for pid in sorted(descendants - {args.pid}):
            try:
                current = process(pid)
                if current['startTicks'] == processes[pid]['startTicks'] and current['state'] != 'Z':
                    retained.append({'pid': pid, 'startTicks': current['startTicks']})
            except (FileNotFoundError, ProcessLookupError):
                pass
        receipt['remainingOwnedDescendants'] = retained
        with (root / 'baseline.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                receipt['runnerLockReleased'] = True
            except BlockingIOError:
                receipt['runnerLockReleased'] = False
        for command in (['git', 'diff', '--quiet'], ['git', 'diff', '--cached', '--quiet']):
            subprocess.run(command, cwd=source, check=True)
        receipt.update(finishedAt=utc(), freeBytesAfter=shutil.disk_usage(root).free)
        save()
        print(json.dumps({key: value for key, value in receipt.items() if key != 'executor'}))
        return 0 if receipt['executorExited'] and receipt['runnerLockReleased'] and not retained else 1
    finally:
        os.close(pidfd)


if __name__ == '__main__':
    raise SystemExit(main())
