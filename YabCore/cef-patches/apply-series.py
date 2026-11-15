#!/usr/bin/env python3
"""Apply only the missing suffix after checking an overlapping patch series.

Use apply.sh for the shared checkout's source lock. --check only reads source.
The ledger rejects modified/reordered previously applied patches. Interrupted
applications can recover a longer complete prefix without reversing live code.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile

LEDGER = '.yab-owncef-patches.json'


def paths_in(patch):
    result = set()
    for line in patch.read_text().splitlines():
        if not line.startswith(('--- a/', '+++ b/')):
            continue
        name = line[6:].split('\t', 1)[0]
        parts = PurePosixPath(name)
        if (parts.is_absolute() or '..' in parts.parts or '.git' in parts.parts
                or name == LEDGER):
            raise ValueError('Unsafe patch path: ' + name)
        result.add(name)
    if not result:
        raise ValueError('Expected a text source patch: ' + patch.name)
    return result


def safe_file(root, name):
    path = root / name
    for part in [path, *path.parents]:
        if part == root:
            break
        if part.is_symlink():
            raise ValueError('Refusing a symlink in source path: ' + name)
    if path.exists() and not path.is_file():
        raise ValueError('Expected a regular source file: ' + name)
    return path


def fingerprint(root, names):
    result = {}
    for name in names:
        path = safe_file(root, name)
        result[name] = (hashlib.sha256(path.read_bytes()).hexdigest(),
                        stat.S_IMODE(path.stat().st_mode)) if path.exists() else None
    return result


def run_patch(root, patch, reverse=False, check=False):
    command = ['git', '-C', str(root), 'apply']
    if reverse:
        command.append('--reverse')
    if check:
        command.append('--check')
    return subprocess.run([*command, str(patch)], capture_output=True, text=True)


def copy_current(source, destination, names):
    for name in names:
        path = safe_file(source, name)
        if path.exists():
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)


def find_prefix(source, patches, names, minimum):
    # Newest-first reversal is essential: later patches can change the context
    # of earlier hunks. Every trial lives in an isolated directory.
    last_error = ''
    for prefix in range(len(patches), minimum - 1, -1):
        with tempfile.TemporaryDirectory(prefix='owncef-series-') as temporary:
            root = Path(temporary)
            copy_current(source, root, names)
            operations = [(p, True) for p in reversed(patches[:prefix])]
            operations.extend((p, False) for p in patches)
            for patch, reverse in operations:
                result = run_patch(root, patch, reverse=reverse)
                if result.returncode:
                    last_error = result.stderr.strip()
                    break
            else:
                return prefix
    raise ValueError('Source does not match a complete applied prefix; no live '
                     'files changed. ' + last_error)


def write_ledger(source, entries):
    target = source / LEDGER
    contents = json.dumps({'schema': 1, 'patches': entries}, indent=2) + '\n'
    if target.exists() and target.read_text() == contents:
        return
    descriptor, temporary = tempfile.mkstemp(prefix=LEDGER + '.', dir=source)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(contents)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply_series(source, directory, check=False):
    source, directory = source.resolve(), directory.resolve()
    patches = sorted(directory.glob('[0-9][0-9][0-9][0-9]-*.patch'))
    if not patches:
        raise ValueError('No source patches in ' + str(directory))
    entries = [{'name': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
               for p in patches]
    names = set().union(*(paths_in(p) for p in patches))
    ledger = safe_file(source, LEDGER)
    previous = []
    if ledger.exists():
        saved = json.loads(ledger.read_text())
        if saved.get('schema') != 1 or not isinstance(saved.get('patches'), list):
            raise ValueError('Invalid source patch ledger')
        previous = saved['patches']
        if entries[:len(previous)] != previous:
            raise ValueError('An applied patch was changed, removed or reordered; '
                             'refusing to alter the shared source')
    original = fingerprint(source, names)
    prefix = find_prefix(source, patches, names, len(previous))
    plan = {'appliedPrefix': prefix, 'missing': [p.name for p in patches[prefix:]],
            'patches': entries, 'checkOnly': check}
    if check:
        return plan
    if fingerprint(source, names) != original:
        raise ValueError('Source changed during preflight; no live files changed')
    # Record an inferred legacy prefix too, so subsequent retries detect edits.
    write_ledger(source, entries[:prefix])
    for index in range(prefix, len(patches)):
        patch = patches[index]
        result = run_patch(source, patch, check=True)
        if result.returncode:
            raise ValueError(result.stderr.strip())
        result = run_patch(source, patch)
        if result.returncode:
            raise ValueError(result.stderr.strip())
        write_ledger(source, entries[:index + 1])
        print('OwnCEF: applied ' + patch.name)
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--src', type=Path, required=True)
    parser.add_argument('--patches', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(apply_series(args.src, args.patches, args.check), indent=2))
    except (ValueError, OSError) as error:
        raise SystemExit('OwnCEF: ' + str(error)) from error


if __name__ == '__main__':
    main()
