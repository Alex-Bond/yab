#!/usr/bin/env python3
"""Real Yab window, two Chromium tabs and displayed remote pixels. Farm only."""
import argparse
import http.server
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'chromium-scripts'))
from probe_app import OwnedApp, _same
from probe_capture import picture
from ownership import record, on_exit
import yab_socket


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = 'B' if self.path.startswith('/b') else 'A'
        color = '#bc3543' if name == 'B' else '#12783c'
        body = f'''<!doctype html><meta charset="utf-8"><title>Chromium {name}</title>
<meta name="theme-color" content="{color}">
<style>html,body{{margin:0;background:{color};color:white;font:24px system-ui}}body{{height:2400px}}h1{{margin:20px}}input{{position:absolute;top:90px;left:30px;width:280px;height:40px;font:20px system-ui}}</style>
<h1>Chromium {name} inside Yab</h1><input aria-label="Chromium acceptance input">
<script>window.pageOnly=41;window.moves=0;addEventListener('wheel',()=>window.moves++);</script>'''.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def wait_for(fn, message, seconds=35):
    until = time.monotonic() + seconds
    last = None
    while time.monotonic() < until:
        last = fn()
        if last:
            return last
        time.sleep(.15)
    raise RuntimeError(f'{message}; last={last}')


def launch_exact(app, env, out, *, foreground=False, launch_stats=None):
    """Keep the assembled app's signature and role-specific JIT entitlements."""
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    log = str(out / 'browser.log')
    command = ['open', *([] if foreground else ['-g']), '-n', '-a', str(app), '--stdout', log, '--stderr', log]
    for key, value in env.items():
        if key.startswith('YAB_'):
            command += ['--env', key + '=' + value]
    if launch_stats is not None:
        launch_stats['requested_at'] = time.monotonic()
    subprocess.run(command, check=True, timeout=30)
    until = time.monotonic() + 30
    while time.monotonic() < until:
        rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
        for row in rows:
            fields = row.strip().split(None, 1)
            if len(fields) == 2 and _same(fields[1], binary):
                return OwnedApp(int(fields[0]), binary)
        time.sleep(.1)
    raise RuntimeError('Exact signed Chromium dev app did not launch')


def run(app, out, site, foreground=False):
    out.mkdir(parents=True, exist_ok=True)
    world = 'chromium-tabs-' + uuid.uuid4().hex[:8]
    domain = 'dev.serafim.fast.test.' + world
    sock = Path.home() / 'Library/Application Support' / f'Yab ({world})' / 'bench.sock'
    defaults = out / 'defaults.plist'
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False,
                                        'hints.noticing': False, 'searchSuggest': False}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True)
    proc = launch_exact(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE='chromium',
                                 YAB_AGENT_CLAUDE='/usr/bin/true', YAB_AGENT_CODEX='/nonexistent/chromium'), out,
                        foreground=foreground)
    record(proc, out)
    on_exit(out)
    ask = yab_socket.kwasker(sock, timeout=45, strict=True, takes_timeout=True,
                            fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
    report = {'app': str(app), 'pid': proc.pid, 'world': world, 'checks': {}, 'states': {}, 'pictures': []}
    checks = report['checks']

    def state(tab=None):
        return ask(do='chromium', **({'id': tab} if tab else {}))

    def ready(tab, suffix):
        def poll():
            s = state(tab)
            report['states']['last_poll'] = s
            return s if s['url'].endswith(suffix) and not s['loading'] and s['context'] > 0 and s['title'] == 'Chromium ' + ('B' if suffix == '/b' else 'A') else None
        return wait_for(poll, 'Chromium page did not become ready')

    def script(body, tab=None, **kwargs):
        return ask(do='chromium', op='script', body=body, **({'id': tab} if tab else {}), **kwargs)['value']

    def capture(name, color):
        s = state()
        path = out / (name + '.png')
        metadata = picture(proc.pid, path, window_id=s['window'])
        from PIL import Image  # Only the picture checks need it; not every worker has it.
        image = Image.open(path).convert('RGB')
        samples = list(image.resize((160, 100)).getdata())
        if color == 'green':
            count = sum(g > r * 1.5 and g > b * 1.3 and g > 60 for r, g, b in samples)
        else:
            count = sum(r > g * 1.5 and r > b * 1.4 and r > 100 for r, g, b in samples)
        fraction = count / len(samples)
        report['pictures'].append({'file': path.name, 'color': color, 'fraction': fraction, 'capture': metadata})
        checks[name + '_remote_pixels'] = fraction > .25
        checks[name + '_sck'] = metadata.get('capture') == 'ScreenCaptureKit'
        return s

    try:
        wait_for(lambda: sock.exists() if proc.poll() is None else False, 'Yab bench socket missing', 60)
        ask(do='ui', welcome=False, sidebar=True)
        if foreground:
            # Some hosts leave a background-launched Browser with no window.
            report['launch_focus'] = ask(do='front')
        a = ask(do='usage-open', url=site + '/a')['id']
        report['states']['a'] = ready(a, '/a')
        checks['chromium_factory'] = state(a)['engine'] == 'chromium'
        time.sleep(.7)
        capture('01-first-tab', 'green')
        ask(do='chromium', id=a, op='navigate', url=site + '/b')
        report['states']['navigated'] = ready(a, '/b')
        checks['history_back_available'] = state(a)['back']
        capture('02-navigation', 'red')
        ask(do='chromium', id=a, op='back')
        report['states']['back'] = ready(a, '/a')
        checks['history_returned'] = state(a)['forward']
        checks['document_world'] = script('return window.pageOnly', a) == 41
        checks['named_world_arguments'] = script('window.trackValue=argsValue;return {title:document.title,value:trackValue}', a,
                                                world='acceptance', arguments={'argsValue': 73}) == {'title': 'Chromium A', 'value': 73}
        checks['world_isolated'] = script('return typeof window.trackValue', a) == 'undefined'
        ask(do='chromium', id=a, op='click', x=80, y=110)
        ask(do='chromium', id=a, op='text', text='Yab Chromium ✓')
        checks['native_committed_text'] = script('return document.querySelector("input").value', a) == 'Yab Chromium ✓'
        ask(do='chromium', id=a, op='snapshot', path=str(out / 'cdp-page.png'))
        checks['cdp_snapshot'] = (out / 'cdp-page.png').is_file()
        b = ask(do='usage-open', url=site + '/b')['id']
        report['states']['b'] = ready(b, '/b')
        time.sleep(.7)
        capture('03-second-tab', 'red')
        ask(do='select', id=a)
        time.sleep(.7)
        report['states']['selected_a'] = capture('04-column-switch', 'green')
        checks['same_tab_after_switch'] = state(a)['remote'] == report['states']['a']['remote']
        before = script('return [innerWidth,innerHeight]', a)
        ask(do='chromium', id=a, op='resize', width=1100, height=780)
        time.sleep(1)
        after = script('return [innerWidth,innerHeight]', a)
        if after == before:
            # LaunchServices may restore the size used by the previous probe.
            # Require a real viewport change, rather than assuming its start size.
            ask(do='chromium', id=a, op='resize', width=980, height=700)
            time.sleep(1)
            after = script('return [innerWidth,innerHeight]', a)
        report['states']['viewport'] = {'before': before, 'after': after}
        checks['resize_reaches_renderer'] = before != after and after[0] > 300 and after[1] > 200
        capture('05-resized', 'green')
        ask(do='select', id=b)
        time.sleep(.7)
        capture('06-second-resized', 'red')
        checks['two_tabs_distinct'] = state(a)['remote'] != state(b)['remote']
        checks['one_helper_per_app'] = state(a)['helperPID'] == state(b)['helperPID'] == report['states']['a']['helperPID']
        original_rows = ask(do='tabs')['tabs']
        report['states']['rows_before_recovery'] = original_rows
        original_ids = [row['id'] for row in original_rows]
        checks['two_original_rows'] = len(original_ids) == 2 and set(original_ids) == {a, b}

        def recovery_rows(label, selected):
            rows = ask(do='tabs')['tabs']
            report['states'][label] = rows
            checks[label + '_exact_rows'] = [row['id'] for row in rows] == original_ids
            checks[label + '_selection'] = [row['id'] for row in rows if row['active']] == [selected]

        report['states']['tabs_before_helper_loss'] = ask(do='tabs')['tabs']
        first_helper = state(b)['helperPID']
        ask(do='chromium', op='crash-helper')
        wait_for(lambda: state(b)['failure'], 'helper loss did not reach Yab')
        checks['helper_loss_visible'] = bool(state(b)['failure'])
        ask(do='chromium', id=b, op='reload')
        ready(b, '/b')
        time.sleep(.7)
        capture('07-helper-restarted', 'red')
        recovery_rows('rows_after_first_recovery', b)
        report['states']['tabs_after_first_recovery'] = ask(do='tabs')['tabs']
        checks['helper_restarted'] = state(b)['context'] > 0 and not state(b)['failure'] and state(b)['helperPID'] != first_helper
        report['states']['restarted_helper'] = state(b)['helperPID']
        ask(do='select', id=a)
        ask(do='chromium', id=a, op='reload')
        ready(a, '/a')
        time.sleep(.7)
        capture('08-other-tab-recovered', 'green')
        recovery_rows('rows_after_both_recovered', a)
        report['states']['tabs_after_both_recovered'] = ask(do='tabs')['tabs']
        expected_ids = {a, b}
        checks['two_tabs_before_helper_loss'] = {row['id'] for row in report['states']['tabs_before_helper_loss']} == expected_ids
        checks['no_duplicate_tabs_after_recovery'] = all(
            len(report['states'][key]) == 2 and {row['id'] for row in report['states'][key]} == expected_ids
            for key in ('tabs_after_first_recovery', 'tabs_after_both_recovered'))
        checks['both_tabs_recovered'] = state(a)['remote'] != state(b)['remote'] and not state(a)['failure']
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        checks['exact_signed_app'] = True
        report['passed'] = all(checks.values())
    except Exception as error:
        report['error'] = repr(error)
        if proc.poll() is not None:
            with (out / 'crash-diagnosis.log').open('w') as log:
                subprocess.run([sys.executable, str(Path(__file__).with_name('diagnose.py')), str(proc.pid)],
                               env=dict(os.environ, YAB_FARM_OUT=str(out)), stdout=log, stderr=log)
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2))
        try: ask(do='ui', act='quit')
        except Exception: pass
        if proc.poll() is None:
            proc.terminate()
        try: proc.wait(timeout=10)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
    print(json.dumps(report, indent=2))
    if not report.get('passed'):
        raise RuntimeError('Chromium tab acceptance failed: ' + ', '.join(k for k, v in checks.items() if not v))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--foreground', action='store_true')
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try: run(args.app.resolve(), args.out.resolve(), 'http://127.0.0.1:' + str(server.server_port), args.foreground)
    finally: server.shutdown(); server.server_close()
