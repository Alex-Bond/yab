#!/usr/bin/env python3
"""Exercise the renderer -> Chrome F12 accelerator -> CEF command callback."""
import json
import os
from pathlib import Path
import socket
import signal
import subprocess
import sys
import tempfile
import time

assert os.environ.get('YAB_FARM_WORKER') == '1', 'Run through ./farm'
helper = Path(sys.argv[1])
out = Path(os.environ['YAB_FARM_OUT'])
expect_crash = '--expect-crash' in sys.argv[2:]
with tempfile.TemporaryDirectory(prefix='yc-devtools-', dir='/tmp') as temporary:
    endpoint = Path(temporary) / 'core.sock'
    with (out / 'accelerator-helper.log').open('w') as log:
        process = subprocess.Popen([str(helper), '--socket=' + str(endpoint),
            '--data-root=' + temporary + '/data', '--use-mock-keychain', '--no-sandbox'], stdout=log, stderr=log)
        events = []
        try:
            deadline = time.monotonic() + 30
            while not endpoint.exists():
                assert process.poll() is None and time.monotonic() < deadline, 'Helper did not start'
                time.sleep(.1)
            with socket.socket(socket.AF_UNIX) as sock:
                sock.connect(str(endpoint)); sock.settimeout(20)
                stream = sock.makefile('rb')
                def call(method, **params):
                    # A mutable request count avoids a class solely for this probe.
                    call.serial += 1
                    request = str(call.serial)
                    sock.sendall((json.dumps(dict(v=1, id=request, method=method, params=params)) + '\n').encode())
                    while True:
                        raw = stream.readline()
                        assert raw, 'Helper exited during ' + method
                        value = json.loads(raw)
                        if 'event' in value: events.append(value)
                        elif value.get('id') == request:
                            assert 'error' not in value, value
                            return value.get('result')
                call.serial = 0
                call('hello'); call('profile.open', profile='accelerator', private=True)
                tab = call('tab.create', profile='accelerator', url='data:text/html,<title>Accelerator</title>')['tab']
                call('tab.resize', tab=tab, width=800, height=600, scale=1)
                deadline = time.monotonic() + 20
                while not call('tab.state', tab=tab).get('devToolsReady'):
                    assert time.monotonic() < deadline
                    time.sleep(.1)
                token = call('script.evaluate', tab=tab, world='accelerator-test',
                    function='function(){window.token=Math.random().toString(36)+Date.now();return window.token}')
                if expect_crash:
                    try:
                        call('input.send', tab=tab, kind='keyDown', keyCode=111,
                            characters='\uf70f', unmodified='\uf70f', modifiers=0)
                        deadline = time.monotonic() + 10
                        while process.poll() is None and time.monotonic() < deadline:
                            time.sleep(.1)
                            call('tab.state', tab=tab)
                    except (OSError, AssertionError):
                        pass
                    code = process.wait(timeout=10)
                    assert code == -signal.SIGSEGV, ('Expected baseline SIGSEGV', code)
                    (out / 'baseline.json').write_text(json.dumps(dict(expectedCrash=True, exit=code)))
                    print('PASS: main baseline reproduces SIGSEGV on native F12', flush=True)
                    sys.exit(0)
                for cycle in range(3):
                    mark = len(events)
                    for kind in ('keyDown', 'keyUp'):
                        call('input.send', tab=tab, kind=kind, keyCode=111, characters='\uf70f', unmodified='\uf70f', modifiers=0)
                    deadline = time.monotonic() + 10
                    while not any(e.get('event') == 'page.devToolsCommand' for e in events[mark:]):
                        assert time.monotonic() < deadline, events[mark:]
                        time.sleep(.1); call('tab.state', tab=tab)
                    routed = [e for e in events[mark:] if e.get('event') == 'page.devToolsCommand']
                    assert len(routed) == 1 and routed[0]['params']['action'] == 'toggle', routed
                    assert process.poll() is None
                    assert call('script.evaluate', tab=tab, world='accelerator-test',
                        function='function(){return window.token}') == token, 'Document was replaced'
                (out / 'accelerator.json').write_text(json.dumps(dict(passed=True, cycles=3, events=events), indent=2))
                print('PASS: F12 routed once per press; helper and page survived all 3 cycles', flush=True)
        finally:
            process.terminate()
            try: process.wait(timeout=20)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
