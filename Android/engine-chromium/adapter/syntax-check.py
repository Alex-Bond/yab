#!/usr/bin/env python3
"""Bounded syntax-only checks of a disposable patch overlay, never the active tree.

This uses existing generated headers and the exact pinned cookies/unit_tests target flags.
It is not a GN build, JNI generation, link, unit-test run, or APK acceptance.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean(source):
    for args in (['diff', '--quiet'], ['diff', '--cached', '--quiet']):
        subprocess.run(['git', *args], cwd=source, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--patch', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    patch = args.patch.resolve()
    scratch = args.scratch.resolve()
    if source == scratch or source in scratch.parents:
        parser.error('Scratch must be outside the active source tree.')
    if scratch.exists():
        parser.error('Use a fresh owned scratch directory for each syntax attempt.')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if revision != 'ac19329a1d32108fd05ead15568cb6e188f8615a':
        parser.error('Unexpected upstream revision.')
    clean(source)
    receipt = json.loads(patch.with_suffix('.json').read_text())
    if sha(patch) != receipt['patchSha256']:
        parser.error('Patch/receipt hash mismatch.')
    out = source / 'out/YabDesktopArm64'
    flags_path = out / 'obj/extensions/browser/api/cookies/cookies.ninja'
    needed = ['gen/extensions/common/api/cookies.h',
              'gen/services/network/public/mojom/cookie_manager.mojom.h',
              'gen/content/public/common/extra_mojo_js_features.mojom.h',
              'obj/build/modules/system/module.pcm']
    if not all((out / name).is_file() for name in needed):
        parser.error('The running baseline has not generated the required headers/modules yet.')
    scratch.mkdir(parents=True)
    overlay = scratch / 'overlay'
    overlay.mkdir()
    for row in receipt['files']:
        rel = Path(row['path'])
        if rel.is_absolute() or '..' in rel.parts:
            parser.error('Invalid patch path.')
        dest = overlay / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        original = source / rel
        if original.exists():
            if sha(original) != row['originalSha256']:
                parser.error('Source drift in ' + row['path'])
            shutil.copyfile(original, dest)
    subprocess.run(['patch', '--batch', '-p1', '-i', str(patch)],
                   cwd=overlay, stdout=subprocess.DEVNULL, check=True)
    for row in receipt['files']:
        if sha(overlay / row['path']) != row['proposedSha256']:
            parser.error('Overlay result mismatch in ' + row['path'])
    clang = source / 'third_party/llvm-build/Release+Asserts/bin/clang++'
    rows = []
    result = {'upstreamRevision': revision, 'patchSha256': sha(patch),
              'targetFlagsSha256': sha(flags_path), 'sourceUnchanged': False,
              'syntaxOnly': True, 'linked': False, 'testsExecuted': False,
              'apkBuilt': False, 'checks': rows}
    for name in ('yab_cookie_store_policy.cc', 'cookies_api.cc',
                 'yab_cookie_store_policy_unittest.cc'):
        file = overlay / 'extensions/browser/api/cookies' / name
        target_flags = out / 'obj/extensions/browser/unit_tests.ninja' if name.endswith(
            '_unittest.cc') else flags_path
        flags = dict(re.findall(r'^(\w+) = (.*)$', target_flags.read_text(), re.M))
        compiler_flags = []
        for key in ('defines', 'include_dirs', 'cflags', 'cflags_cc', 'module_deps'):
            value = flags[key].replace('$:', ':').replace('$$', '$')
            compiler_flags.extend(shlex.split(value))
        # Keep crash reports and any compiler cache outside active build inputs/outputs.
        compiler_flags = [flag for flag in compiler_flags if not flag.startswith(
            ('-fcrash-diagnostics-dir=', '-fmodules-cache-path='))]
        compiler_flags += ['-fcrash-diagnostics-dir=' + str(scratch / 'crashes'),
                          '-fmodules-cache-path=' + str(scratch / 'module-cache'),
                          # Object-only target options can be unused under -fsyntax-only.
                          '-Wno-unused-command-line-argument',
                          '-ferror-limit=8', '-fno-color-diagnostics']
        command = ['nice', '-n', '10', str(clang), '-I' + str(overlay),
                   *compiler_flags, '-fsyntax-only', str(file)]
        (scratch / (name + '.command.json')).write_text(json.dumps(command, indent=2) + '\n')
        log = scratch / (name + '.log')
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with log.open('w') as output:
            try:
                run = subprocess.run(command, cwd=out, stdout=output,
                                     stderr=subprocess.STDOUT, timeout=180)
                code = run.returncode
            except subprocess.TimeoutExpired:
                code = 124
        rows.append({'file': name, 'targetFlagsSha256': sha(target_flags),
                     'startedAt': started, 'exitCode': code,
                     'log': str(log)})
        (scratch / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
        if code:
            break
    clean(source)
    result['sourceUnchanged'] = True
    (scratch / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return int(any(row['exitCode'] != 0 for row in rows))


if __name__ == '__main__':
    raise SystemExit(main())
