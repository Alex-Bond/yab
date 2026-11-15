#!/usr/bin/env python3
"""Real c31305f5 before, WebKit controls and connected-mail candidate proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time

BASE = 'c31305f5'


def logged(command, env, folder, budget):
    folder.mkdir(parents=True, exist_ok=True)
    result = {'command': command, 'budget': budget, 'passed': False}
    child = None
    reader = None
    with (folder / 'eval.log').open('w') as log:
        try:
            child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True,
                                     bufsize=1, start_new_session=True)
            def output():
                for line in child.stdout:
                    log.write(line)
                    log.flush()
                    print(line, end='', flush=True)
            reader = threading.Thread(target=output, daemon=True)
            reader.start()
            result['exit'] = child.wait(timeout=budget)
            reader.join(timeout=5)
            result['pipeHeld'] = reader.is_alive()
            result['passed'] = result['exit'] == 0 and not result['pipeHeld']
        except subprocess.TimeoutExpired:
            result['timeout'] = True
        finally:
            if child is not None and (child.poll() is None or (reader is not None and reader.is_alive())):
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(child.pid, sig)
                    except ProcessLookupError:
                        pass
                    if sig == signal.SIGTERM:
                        time.sleep(.5)
                child.wait(timeout=5)
            if reader is not None:
                reader.join(timeout=5)
    (folder / 'process.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def signed(app, name):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleName'] == info['CFBundleDisplayName'] == name, info
    signatures = {}
    for code in (app, app / 'Contents/MacOS/YabCore'):
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(code)], check=True, timeout=60)
        text = subprocess.run(['codesign', '-d', '--verbose=4', str(code)], check=True,
                              capture_output=True, text=True, timeout=60).stderr
        assert 'TeamIdentifier=25UG4QYN9F' in text, text
        signatures[str(code)] = text
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    return {'app': str(app), 'name': name, 'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'signatures': signatures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER') != '1':
        raise SystemExit('Run through the farm')
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    app, out = args.app.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    name = os.environ['YAB_TASK_NAME']
    assert name.endswith(' B'), 'The paired candidate task name must end in B'
    base_name = name.removesuffix(' B') + ' A'
    base_app = out / (base_name + '.app')
    report = {'baseCommit': BASE, 'candidateCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'phases': {}, 'passed': False}
    try:
        # Candidate changes are Swift agent routing. The base may reuse
        # this exact helper source, never a helper from an unmerged SDK track.
        native_delta = subprocess.check_output(['git', 'diff', '--name-only', BASE, 'HEAD', '--', 'YabCore'], text=True)
        assert not native_delta.strip(), native_delta
        report['candidateApp'] = signed(app, name)
        env = dict(os.environ, YAB_CEF='1', YAB_UNIVERSAL='0',
                   YAB_CEF_HELPER=str(app / 'Contents/MacOS/YabCore'), YAB_TASK_NAME=base_name)
        report['baseBuild'] = logged(['bash', 'scripts/runs/rev_app.sh', BASE, str(base_app)],
                                     env, out / 'base-build', 2400)
        if not report['baseBuild']['passed']:
            raise RuntimeError('Actual committed baseline did not build completely')
        report['baseApp'] = signed(base_app, base_name)
        for label, source, engine, title, extra in (
            ('main-webKit', base_app, 'webKit', base_name, []),
            ('main-chromium', base_app, 'chromium', base_name, ['--expect-main-refusal']),
            ('candidate-webKit', app, 'webKit', name, []),
            ('candidate-chromium', app, 'chromium', name, []),
        ):
            folder = out / label
            command = [sys.executable, '-u', str(root / 'evals/chromium-agents/mail_code.py'),
                       '--repo', str(root), '--app', str(source), '--out', str(folder), '--engine', engine, *extra]
            try:
                row = logged(command, dict(os.environ, YAB_TASK_NAME=title), folder, 360)
                report['phases'][label] = row
                receipt = folder / 'report.json'
                if receipt.is_file():
                    row['fixture'] = json.loads(receipt.read_text())
                    expected = 'expected-main-failure' if label == 'main-chromium' else 'passed'
                    row['passed'] = row['passed'] and row['fixture'].get('outcome') == expected
                else:
                    row['passed'] = False
            finally:
                subprocess.run([sys.executable, 'evals/chromium-scripts/ownership.py', str(folder)],
                               check=True, timeout=60)
                (out / 'pair.json').write_text(json.dumps(report, indent=2) + '\n')
        report['passed'] = len(report['phases']) == 4 and all(row['passed'] for row in report['phases'].values())
    finally:
        (out / 'pair.json').write_text(json.dumps(report, indent=2) + '\n')
    if not report['passed']:
        raise SystemExit('Connected-mail before/after incomplete or failed')


if __name__ == '__main__':
    main()
