#!/usr/bin/env python3
"""Apply the reviewed patch only to a clean, exact, current-job-owned Gecko checkout.

No checkout, bootstrap, SDK install, build, emulator, provider or app action is implicit.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

KIT = Path(__file__).resolve().parents[1]


def sha(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise RuntimeError('Unexpected pinned source file')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_inputs(kit=KIT):
    pins = json.loads((kit / 'source-pins.json').read_text())
    patch = json.loads((kit / 'patch-manifest.json').read_text())
    if pins['mozillaRevision'] != 'e4ce606692cd81e6898547e2edd7c552fefcbb04' or patch['fullClearSupported']:
        raise RuntimeError('Unexpected revision or falsely complete qualification patch')
    for item in pins['files']:
        path = Path(item['path'])
        if path.is_absolute() or '..' in path.parts or sha(kit / 'upstream' / path) != item['sha256']:
            raise RuntimeError('Upstream source pin mismatch')
    relative = Path(patch['patch'])
    if relative.is_absolute() or '..' in relative.parts or sha(kit / relative) != patch['sha256']:
        raise RuntimeError('Patch pin mismatch')
    for item in patch['files']:
        if item['beforeSHA256'] is None and sha(kit / 'runtime' / Path(item['path']).name) != item['afterSHA256']:
            raise RuntimeError('Runtime source differs from its reviewed patch')
    return pins, patch


def apply(source, environment=None):
    environment = os.environ if environment is None else environment
    module = KIT.parents[0] / 'scripts' / 'emulator_hosts.py'
    spec = importlib.util.spec_from_file_location('yab_gecko_farm_hosts', module)
    hosts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hosts)
    host = hosts.require_worker(environment)
    if host != 'aws-2':
        raise RuntimeError('First Gecko qualification preparation is explicitly owned by aws-2')
    output = Path(environment['YAB_FARM_OUT']).resolve(strict=True)
    original = Path(source)
    source = original.resolve(strict=True)
    if original.is_symlink() or source == output or not source.is_relative_to(output):
        raise RuntimeError('Gecko source must be inside this fresh farm result slot')
    pins, patch = checked_inputs()
    revision = subprocess.run(['hg', '-R', str(source), 'log', '-r', '.', '--template', '{node}'],
                              capture_output=True, text=True, timeout=20, check=True).stdout
    dirty = subprocess.run(['hg', '-R', str(source), 'status'], capture_output=True, text=True,
                           timeout=30, check=True).stdout
    if revision != pins['mozillaRevision'] or dirty:
        raise RuntimeError('Gecko qualification requires the exact clean revision')
    # Preflight every destination before writing any file.
    for item in patch['files']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('Invalid patch destination')
        destination = source / relative
        if not destination.resolve(strict=False).is_relative_to(source):
            raise RuntimeError('Patch destination escapes the owned checkout')
        if item['beforeSHA256'] is None:
            if destination.exists() or destination.is_symlink():
                raise RuntimeError('New patch destination already exists')
        elif sha(destination) != item['beforeSHA256']:
            raise RuntimeError('Gecko source changed since the reviewed pin')
    command = ['patch', '--batch', '--forward', '-p1', '-i', str(KIT / patch['patch'])]
    subprocess.run(command[:1] + ['--dry-run'] + command[1:], cwd=source, check=True, timeout=20)
    subprocess.run(command, cwd=source, check=True, timeout=20)
    for item in patch['files']:
        if sha(source / item['path']) != item['afterSHA256']:
            raise RuntimeError('Patched Gecko source differs from reviewed bytes')
    receipt = {'schema': 1, 'host': host, 'upstreamRevision': revision,
               'patchSHA256': patch['sha256'], 'qualificationOnly': True,
               'supportedTypes': patch['supportedTypes'], 'requiredFullTypes': patch['requiredFullTypes'],
               'fullClearSupported': False, 'sourcePatched': True, 'buildExecuted': False,
               'nativeTestsExecuted': False, 'currentAppDependencyChanged': False}
    (output / 'gecko-source-preparation.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(apply(args.source), indent=2))


if __name__ == '__main__':
    main()
