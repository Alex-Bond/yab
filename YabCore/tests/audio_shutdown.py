#!/usr/bin/env python3
"""Quit the helper while a page plays, with the audio service in process.

Yab starts YabCore with --disable-features=AudioServiceOutOfProcess
(ChromiumProcess.launchArguments). On macOS the in-process audio service then
lives in the UI thread's sequence-local storage, which CefShutdown destroys
after ~BrowserMainLoop has freed the AudioManager: a stream still open then
closes into freed memory (~DeviceListenerOutputStream, 0xefefefefefefefef),
reports 1230 to 1418. YabCore/cef-patches/0063 destroys the service first.

On the pinned SDK this ordinary quit (one page, WebAudio running, client
gone) exits cleanly, in process and out (farm ff8a68a7f83a4ee2): its streams
close before the loop ends. The reports' trigger, a stream still open at
CefShutdown, is not reproduced by it; it guards the quit path.

  audio_shutdown.py HELPER [--out-of-process] --expect crash|clean
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

assert os.environ.get('YAB_FARM_WORKER') == '1', 'Run through ./farm'
helper = Path(sys.argv[1])
args = sys.argv[2:]
expect = args[args.index('--expect') + 1]
assert expect in ('crash', 'clean'), expect
in_process = '--out-of-process' not in args
out = Path(os.environ['YAB_FARM_OUT'])
mode = ('in-process' if in_process else 'out-of-process') + '-' + expect
switches = ['--autoplay-policy=no-user-gesture-required']
if in_process: switches.append('--disable-features=AudioServiceOutOfProcess')
reports = Path.home() / 'Library/Logs/DiagnosticReports'
before = {p.name for p in reports.glob('YabCore*')} if reports.exists() else set()

with tempfile.TemporaryDirectory(prefix='yc-audio-', dir='/tmp') as temporary:
    endpoint = Path(temporary) / 'core.sock'
    with (out / (mode + '-helper.log')).open('w') as log:
        process = subprocess.Popen([str(helper), '--socket=' + str(endpoint),
            '--data-root=' + temporary + '/data', '--use-mock-keychain', '--no-sandbox', *switches],
            stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while not endpoint.exists():
                assert process.poll() is None and time.monotonic() < deadline, 'Helper did not start'
                time.sleep(.1)
            sock = socket.socket(socket.AF_UNIX)
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
            call('hello'); call('profile.open', profile='audio', private=True)
            tab = call('tab.create', profile='audio', url='data:text/html,<title>Audio</title>')['tab']
            call('tab.resize', tab=tab, width=800, height=600, scale=1)
            deadline = time.monotonic() + 20
            while not call('tab.state', tab=tab).get('devToolsReady'):
                assert time.monotonic() < deadline, 'Page never became scriptable'
                time.sleep(.1)
            # A quiet oscillator: an output stream the audio service keeps open.
            call('script.evaluate', tab=tab, world='audio-test', function=(
                'function(){window.yabAudio=new AudioContext();const o=yabAudio.createOscillator(),'
                'g=yabAudio.createGain();g.gain.value=0.0001;o.connect(g).connect(yabAudio.destination);'
                'o.start();return yabAudio.state}'))
            deadline = time.monotonic() + 15
            state = None
            while state != 'running':
                assert time.monotonic() < deadline, ('AudioContext never ran', state)
                time.sleep(.2)
                state = call('script.evaluate', tab=tab, world='audio-test',
                             function='function(){return yabAudio.state}')
            time.sleep(2)  # past the first rendered buffers
            # The client going away is how Yab's quit reaches the helper. The
            # file object holds the descriptor too: close both, or no EOF.
            stream.close(); sock.shutdown(socket.SHUT_RDWR); sock.close()
            code = process.wait(timeout=40)
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
    time.sleep(5)  # ReportCrash writes the report a moment after the exit
    new = sorted(p for p in reports.glob('YabCore*') if p.name not in before) if reports.exists() else []
    frames = []
    for report in new[:1]:
        text = report.read_text(errors='replace')
        _, _, body = text.partition('\n')
        try:
            ips = json.loads(body)
            thread = ips['threads'][ips.get('faultingThread', 0)]
            images = ips['usedImages']
            frames = [dict(image=images[f['imageIndex']].get('name'), offset=f.get('imageOffset'))
                      for f in thread['frames'][:30]]
            fault = ips.get('exception', {})
        except (ValueError, KeyError, IndexError):
            fault = {}
    result = dict(mode=mode, exit=code, signal=-code if code < 0 else None,
                  reports=[p.name for p in new], fault=fault if new else None, frames=frames)
    (out / (mode + '.json')).write_text(json.dumps(result, indent=2))
    print(json.dumps(result)[:2000], flush=True)
    if expect == 'crash':
        assert code in (-signal.SIGSEGV, -signal.SIGBUS), ('Expected the shutdown crash', code)
        print('PASS: ' + mode + ': helper crashed at shutdown, signal ' + str(-code), flush=True)
    else:
        assert code == 0 and not new, ('Expected a clean exit', code, [p.name for p in new])
        print('PASS: ' + mode + ': helper exited cleanly', flush=True)
