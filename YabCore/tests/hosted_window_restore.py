#!/usr/bin/env python3
"""An extension minimizes and restores every window (chrome.windows.update).

Reports #990-1155 (YabCore 0.46.7, macOS 27.2): restoring a hosted page
window from the Dock showed it, and the KVO guard that watches it for being
shown forwarded its own observation to NSWindow, which raised. Passes when the
helper survives the requests and its page still answers.
--expect-crash: the baseline must die of that exception instead.
"""
import json
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import sys
import tempfile
import time

assert os.environ.get('YAB_FARM_WORKER') == '1', 'Run through ./farm'
helper = Path(sys.argv[1])
expect_crash = '--expect-crash' in sys.argv[2:]
out = Path(os.environ['YAB_FARM_OUT'])
fixture = Path(__file__).resolve().parent / 'hosted-window-extension'
report = {'macos': platform.mac_ver()[0], 'expectCrash': expect_crash}
started = time.time()
with tempfile.TemporaryDirectory(prefix='yc-restore-', dir='/tmp') as temporary:
    endpoint = Path(temporary) / 'core.sock'
    log_path = out / ('restore-helper-%s.log' % ('baseline' if expect_crash else 'fixed'))
    with log_path.open('w') as log:
        process = subprocess.Popen([str(helper), '--socket=' + str(endpoint),
            '--data-root=' + temporary + '/data', '--use-mock-keychain', '--no-sandbox'], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while not endpoint.exists():
                assert process.poll() is None and time.monotonic() < deadline, 'Helper did not start'
                time.sleep(.1)
            with socket.socket(socket.AF_UNIX) as sock:
                sock.connect(str(endpoint)); sock.settimeout(20)
                stream = sock.makefile('rb')
                def call(method, **params):
                    call.serial += 1
                    request = str(call.serial)
                    sock.sendall((json.dumps(dict(v=1, id=request, method=method, params=params)) + '\n').encode())
                    while True:
                        raw = stream.readline()
                        assert raw, 'Helper exited during ' + method
                        value = json.loads(raw)
                        if value.get('id') == request:
                            assert 'error' not in value, value
                            return value.get('result')
                call.serial = 0
                call('hello'); call('profile.open', profile='restore')
                page = call('tab.create', profile='restore', url='data:text/html,<title>Hosted</title>')['tab']
                call('tab.resize', tab=page, width=800, height=600, scale=1)
                manager = call('tab.create', profile='restore', url='chrome://extensions/')['tab']
                deadline = time.monotonic() + 30
                while True:
                    try: proof = call('tab.readiness', tab=manager, profile='restore', url='chrome://extensions/')
                    except AssertionError as error: proof = {'error': str(error)}
                    if proof.get('ready') and proof.get('url') == 'chrome://extensions/': break
                    assert time.monotonic() < deadline, proof
                    time.sleep(.1)
                call('extension.load', tab=manager, path=str(fixture))
                report['loaded'] = True
                # The worker minimizes and restores every window four times, 750 ms apart.
                deadline = time.monotonic() + 12
                while process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.25)
                    try: call('tab.state', tab=page)
                    except (OSError, AssertionError): break
                report['alive'] = process.poll() is None
                if report['alive']:
                    report['title'] = call('script.evaluate', tab=page, world='restore-test',
                        function='function(){return document.title}')
        except (OSError, AssertionError) as error:
            report['error'] = str(error)
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=20)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            report['exit'] = process.returncode
    text = log_path.read_text(errors='replace')
    report['exception'] = [line for line in text.splitlines() if 'exception' in line.lower() or 'observeValueForKeyPath' in line][:10]
    print('--- helper log tail', flush=True)
    print('\n'.join(text.splitlines()[-25:]), flush=True)
    # The crash report the system wrote for the helper, if it died: its
    # exception and the faulting thread say which path it took.
    reports = []
    deadline = time.monotonic() + (30 if report.get('exit') not in (0, -15) else 0)
    while True:
        reports = sorted((Path.home() / 'Library/Logs/DiagnosticReports').glob('YabCore*.ips'),
                         key=lambda path: path.stat().st_mtime)
        if any(path.stat().st_mtime >= started for path in reports) or time.monotonic() > deadline: break
        time.sleep(1)
    def ours(path):
        # Only this helper or a child of it: other jobs share the folder.
        try:
            raw = path.read_text(errors='replace')
            body = json.loads(raw[raw.index('\n{') + 1:])
            return process.pid in (body.get('pid'), body.get('parentPid'))
        except (OSError, ValueError):
            return False
    fresh = [path for path in reports if path.stat().st_mtime >= started and ours(path)]
    for path in fresh[-1:]:
        raw = path.read_text(errors='replace')
        body = json.loads(raw[raw.index('\n{') + 1:])
        images = body.get('usedImages', [])
        thread = body['threads'][body.get('faultingThread', 0)]
        crash = {'file': path.name, 'exception': body.get('exception'), 'asi': body.get('asiBacktraces'),
                 'frames': ['%s +%#x %s' % (images[f['imageIndex']].get('name', '?') if f.get('imageIndex', -1) < len(images) else '?',
                                            f.get('imageOffset', 0), f.get('symbol', '')) for f in thread['frames'][:24]]}
        report['crash'] = crash
        (out / ('restore-crash-%s.json' % ('baseline' if expect_crash else 'fixed'))).write_text(json.dumps(crash, indent=2))
        print(json.dumps(crash, indent=2), flush=True)
(out / ('restore-%s.json' % ('baseline' if expect_crash else 'fixed'))).write_text(json.dumps(report, indent=2))
print(json.dumps(report), flush=True)
if expect_crash:
    ok = report.get('exit') in (-signal.SIGTRAP, -signal.SIGABRT) and 'observeValueForKeyPath' in json.dumps(report.get('crash', {}).get('asi'))
    print(('PASS' if ok else 'FAIL') + ': baseline ' + ('dies' if ok else 'does not die') + ' when a hosted window is restored', flush=True)
else:
    ok = report.get('alive') and report.get('title') == 'Hosted'
    print(('PASS' if ok else 'FAIL') + ': helper and page survive minimize/restore of every window', flush=True)
sys.exit(0 if ok else 1)
