#!/usr/bin/env python3
"""Public upstream build baseline. Run only in the owned Linux test VM.

No project sources, credentials, browser profiles or private build services are
inputs. Every stage records its actual exit code; a fetched tree is not a build.
"""
import argparse
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


def atomic_json(path, value):
    temporary = path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--stage', choices=('fetch', 'tools', 'deps', 'sync', 'hooks', 'generate', 'build'), required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        parser.error('This baseline requires Linux x86_64; never run a native Mac build here.')
    if root != Path('/data/yab-chromium-baseline') or not root.is_dir():
        parser.error('Only the explicitly owned /data/yab-chromium-baseline directory is allowed.')
    cfg = json.loads((Path(__file__).parent / 'baseline.json').read_text())
    marker = root / 'owner.json'
    if marker.exists():
        if json.loads(marker.read_text()).get('task') != 'yab-android-chromium-20261022':
            parser.error('Unexpected owner marker; preserve the directory.')
    else:
        atomic_json(marker, {'task': 'yab-android-chromium-20261022', 'createdAt': utc()})
    lock = (root / 'baseline.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    free = shutil.disk_usage(root).free
    if free < cfg['minimumReserveBytes']:
        parser.error('Owned drive has less than the 16 GiB reserve; no cleanup is automatic.')
    if args.stage == 'fetch' and not (root / 'checkout/src/.git').exists() and free < cfg['minimumInitialFreeBytes']:
        parser.error('Initial checkout requires at least 100 GiB of free space.')
    for name in ('logs', 'cache/cipd', 'cache/vpython', 'tmp', 'tools', 'checkout'):
        (root / name).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({
        'DEPOT_TOOLS_UPDATE': '0',
        'DEPOT_TOOLS_METRICS': '0',
        'CIPD_CACHE_DIR': str(root / 'cache/cipd'),
        'VPYTHON_VIRTUALENV_ROOT': str(root / 'cache/vpython'),
        'XDG_CACHE_HOME': str(root / 'cache'),
        'TMPDIR': str(root / 'tmp'),
        'PATH': env['PATH'] + ':' + str(root / 'tools/depot_tools'),
    })
    log_path = root / 'logs' / (args.stage + '.log')
    receipt_path = root / (args.stage + '-receipt.json')
    receipt = {'stage': args.stage, 'startedAt': utc(), 'sourceRevision': cfg['chromiumRevision'],
               'depotToolsRevision': cfg['depotToolsRevision'], 'commands': [], 'freeBytesBefore': free,
               'configurationSha256': hashlib.sha256((Path(__file__).parent / 'baseline.json').read_bytes()).hexdigest(),
               'runnerSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'completed': False, 'exitCode': None}
    atomic_json(receipt_path, receipt)

    with log_path.open('a', buffering=1) as log:
        def run(command, cwd=root):
            item = {'argv': command, 'cwd': str(cwd), 'startedAt': utc(), 'exitCode': None}
            receipt['commands'].append(item)
            atomic_json(receipt_path, receipt)
            log.write('\n' + utc() + ' ' + json.dumps(command) + '\n')
            result = subprocess.run(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
            item.update({'exitCode': result.returncode, 'finishedAt': utc()})
            atomic_json(receipt_path, receipt)
            if result.returncode:
                raise subprocess.CalledProcessError(result.returncode, command)

        def checkout(name, url, revision):
            destination = root / name
            if not destination.exists():
                destination.mkdir()
            if not (destination / '.git').exists():
                run(['git', 'init'], destination)
                run(['git', 'remote', 'add', 'origin', url], destination)
                run(['git', 'fetch', '--depth=1', 'origin', revision], destination)
                run(['git', 'checkout', '--detach', 'FETCH_HEAD'], destination)
            actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=destination, env=env, text=True).strip()
            if actual != revision:
                raise RuntimeError('Existing source revision mismatch; preserve the checkout.')
            return destination

        try:
            source = root / 'checkout/src'
            depot = root / 'tools/depot_tools'
            if args.stage != 'fetch':
                for directory, expected in ((source, cfg['chromiumRevision']),
                                            (depot, cfg['depotToolsRevision'])):
                    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=directory,
                                                     env=env, text=True).strip()
                    if actual != expected:
                        raise RuntimeError('Existing source revision mismatch; preserve the checkout.')
                    for command in (['git', 'diff', '--quiet'], ['git', 'diff', '--cached', '--quiet']):
                        if subprocess.run(command, cwd=directory, env=env).returncode:
                            raise RuntimeError('Baseline contains tracked edits; preserve them and do not call it upstream.')
            if args.stage == 'fetch':
                checkout('tools/depot_tools', cfg['depotToolsRepository'], cfg['depotToolsRevision'])
                checkout('checkout/src', cfg['chromiumRepository'], cfg['chromiumRevision'])
                gclient = root / 'checkout/.gclient'
                contents = ("solutions = " + repr([{'name': 'src', 'url': cfg['chromiumRepository'],
                            'deps_file': 'DEPS', 'managed': False, 'custom_deps': {}, 'custom_vars': {}}])
                            + "\ntarget_os = ['android']\n")
                if gclient.exists() and gclient.read_text() != contents:
                    raise RuntimeError('Existing gclient differs; preserve it.')
                gclient.write_text(contents)
            elif args.stage == 'tools':
                run([str(depot / 'ensure_bootstrap')], root)
            elif args.stage == 'deps':
                run(['sudo', 'apt-get', 'update'])
                run(['sudo', 'apt-get', 'install', '-y', 'lsb-release'])
                run(['sudo', 'python3', 'build/install-build-deps.py', '--android', '--no-arm',
                     '--no-chromeos-fonts', '--no-nacl', '--no-prompt'], source)
            elif args.stage == 'sync':
                run([str(depot / 'gclient'), 'sync', '--nohooks', '--noprehooks', '--no-history',
                     '--jobs', str(cfg['localJobs']), '--revision', 'src@' + cfg['chromiumRevision']], root / 'checkout')
            elif args.stage == 'hooks':
                run([str(depot / 'gclient'), 'runhooks'], root / 'checkout')
            elif args.stage == 'generate':
                build = source / 'out/YabDesktopArm64'
                build.mkdir(parents=True, exist_ok=True)
                text = '\n'.join(k + ' = ' + json.dumps(v) for k, v in cfg['gnArgs'].items()) + '\n'
                (build / 'args.gn').write_text(text)
                run([str(depot / 'gn'), 'gen', 'out/YabDesktopArm64', '--fail-on-unused-args'], source)
                run([str(depot / 'gn'), 'desc', 'out/YabDesktopArm64', cfg['targetLabel'], 'deps'], source)
            elif args.stage == 'build':
                run([str(depot / 'autoninja'), '-C', 'out/YabDesktopArm64', '-j' + str(cfg['localJobs']), cfg['target']], source)
                artifacts = []
                for apk in sorted((source / 'out/YabDesktopArm64/apks').glob('*.apk')):
                    sha = hashlib.sha256()
                    with apk.open('rb') as stream:
                        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
                            sha.update(block)
                    artifacts.append({'path': str(apk), 'bytes': apk.stat().st_size, 'sha256': sha.hexdigest()})
                if not artifacts:
                    raise RuntimeError('Build returned success without an APK artifact.')
                receipt['artifacts'] = artifacts
            receipt.update({'completed': True, 'exitCode': 0})
        except Exception as error:
            receipt.update({'error': str(error), 'exitCode': getattr(error, 'returncode', 1)})
        finally:
            receipt.update({'finishedAt': utc(), 'freeBytesAfter': shutil.disk_usage(root).free})
            atomic_json(receipt_path, receipt)
    print(json.dumps({k: v for k, v in receipt.items() if k != 'commands'}, indent=2))
    return receipt['exitCode']


if __name__ == '__main__':
    sys.exit(main())
