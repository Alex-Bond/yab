#!/usr/bin/env python3
"""Posted HID scroll events through WindowServer on isolated, built Yab apps.

Use an exclusive, display-enabled farm job with pointer, capture and PyObjC.
The same local pages and event streams run in A/B/B/A order. No DOM wheel
events or in-process NSApp events are used to drive the app. Bench only
opens pages, reads results, and captures the app's layers.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time
import uuid

import Quartz

EVALS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVALS))
from probe_app import launch
from probe_capture import picture
from yab_socket import asker, serve, socket_path, url

PAGE = """<!doctype html><meta charset=utf-8><title>Wheel input {name}</title>
<style>html,body{{margin:0;background:white;color:#171717;font:18px system-ui}}
#sheet{{width:100vw;height:85vh;overflow:auto;overscroll-behavior-x:auto}}
#columns{{width:4800px;height:100%;background:repeating-linear-gradient(90deg,#fff 0 118px,#bbb 118px 120px)}}
span{{display:inline-block;width:120px;text-align:center;padding-top:80px}}
p{{height:48px;margin:0;padding-left:40px;border-bottom:1px solid #ddd}}</style>
{body}
<script>
window.samples=[];window.wheels=[];window.recording=false;
window.begin=function(){{samples=[];wheels=[];recording=true;return performance.now()}};
window.result=function(){{recording=false;return {{url:location.href,y:scrollY,
 left:document.getElementById('sheet')?.scrollLeft??0,samples:samples,wheels:wheels}}}};
{listener}
(function frame(t){{if(recording)samples.push([t,scrollY,document.getElementById('sheet')?.scrollLeft??0]);requestAnimationFrame(frame)}})();
</script>"""


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip('/').split('?')[0]
        feed = name.startswith('feed')
        body = (''.join(f'<p>Feed row {i}</p>' for i in range(5000)) if feed else
                '<div id=sheet><div id=columns>' + ''.join(
                    f'<span>Column {("A" if i >= 26 else "") + chr(65 + i % 26)}</span>'
                    for i in range(40)) + '</div></div>')
        # No wheel listener on the feed: it would alter the event regions
        # whose cost this comparison is intended to detect (#175).
        listener = '' if feed else "addEventListener('wheel',e=>{if(recording)wheels.push([performance.now(),e.deltaX,e.deltaY,e.deltaMode,e.isTrusted])},{passive:true});"
        data = PAGE.format(name=name, body=body, listener=listener).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def percentile(values, fraction):
    return sorted(values)[min(len(values) - 1, round((len(values) - 1) * fraction))] if values else None


def feed_metrics(samples, first_event, active_end):
    active = [s for s in samples if first_event <= s[0] <= active_end]
    moving = [s for i, s in enumerate(active) if i and s[1] - active[i - 1][1] > .5]
    gaps = [b[0] - a[0] for a, b in zip(moving, moving[1:])]
    return dict(frames=len(active), moving_frames=len(moving),
                distance=active[-1][1] - active[0][1] if active else 0,
                first_motion_ms=moving[0][0] - first_event if moving else None,
                p95_motion_gap_ms=percentile(gaps, .95), max_motion_gap_ms=max(gaps) if gaps else None)


def post_scroll(at, dx=0, dy=0, precise=False, phase=0, momentum=0):
    event = Quartz.CGEventCreateScrollWheelEvent(None,
        Quartz.kCGScrollEventUnitPixel if precise else Quartz.kCGScrollEventUnitLine,
        2, int(dy), int(dx))
    if event is None:
        raise RuntimeError('Could not create scroll event')
    Quartz.CGEventSetFlags(event, 0)
    Quartz.CGEventSetLocation(event, at)
    Quartz.CGEventSetIntegerValueField(event, Quartz.kCGScrollWheelEventIsContinuous, int(precise))
    Quartz.CGEventSetIntegerValueField(event, Quartz.kCGScrollWheelEventScrollPhase, phase)
    Quartz.CGEventSetIntegerValueField(event, Quartz.kCGScrollWheelEventMomentumPhase, momentum)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def stream(at, moves):
    start = time.monotonic()
    posted = []
    for due, dx, dy, precise, phase, momentum in moves:
        delay = start + due - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        post_scroll(at, dx, dy, precise, phase, momentum)
        posted.append(dict(ms=(time.monotonic() - start) * 1000, dx=dx, dy=dy,
                           precise=precise, phase=phase, momentum=momentum))
    return posted


def phased(horizontal=False):
    if horizontal:
        moves = [(0, 0, 0, True, 1, 0)]
        moves += [(i / 60, 12, 0, True, 2, 0) for i in range(1, 23)]
        moves += [(23 / 60, 0, 0, True, 4, 0)]
        moves += [(i / 60, max(0, 12 - (i - 24)), 0, True, 0,
                   1 if i == 24 else 3 if i == 36 else 2) for i in range(24, 37)]
    else:
        moves = [(0, 0, 0, True, 1, 0)]
        moves += [(i / 120, 0, -16, True, 2, 0) for i in range(1, 241)]
        moves += [(2.01, 0, 0, True, 4, 0)]
        moves += [(2.03 + i / 60, 0, -max(1, round(40 * .95 ** i)), True, 0,
                   1 if i == 0 else 2) for i in range(80)]
        moves += [(3.4, 0, 0, True, 0, 3)]
    return moves


def run(app, folder, label, base):
    folder.mkdir(parents=True, exist_ok=True)
    world = 'wheel-live-' + uuid.uuid4().hex[:8]
    domain = 'dev.serafim.fast.test.' + world
    for key in ('bench', 'welcomed'):
        subprocess.run(['defaults', 'write', domain, key, '-bool', 'true'], check=True)
    raw = asker(socket_path(world))
    data = dict(label=label, world=world, app=str(app), checks=[], steps=[], transport='CGEventPost(kCGHIDEventTap)')
    proc = None
    tab = None

    def ask(verb, **fields):
        request = dict(do=verb, **fields)
        got = raw(request)
        data['steps'].append(dict(request=request, answer=got))
        if got.get('error'):
            raise RuntimeError(str(got))
        return got

    def js(code):
        return ask('eval', id=tab, js=code).get('value')

    def check(name, passed, observed):
        data['checks'].append(dict(name=name, passed=bool(passed), observed=observed))
        print(('PASS ' if passed else 'FAIL ') + label + ': ' + name + ': ' + str(observed), flush=True)

    def open_pair(kind):
        nonlocal tab
        tab = ask('open', url=base + '/' + kind + '1', plain=True)['id']
        ask('select', id=tab)
        for suffix in ('1', '2'):
            if suffix == '2':
                ask('go', id=tab, url=base + '/' + kind + suffix)
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                try:
                    if js("document.readyState==='complete' && typeof begin==='function' && location.pathname.endsWith('" + suffix + "')"):
                        break
                except RuntimeError:
                    pass
                time.sleep(.1)
            else:
                raise RuntimeError('Page did not load')
            time.sleep(.35)
        ask('front')
        place = ask('smartzoom', where=True)
        window = next((w for w in Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []
            if w.get('kCGWindowNumber') == place['window']), None)
        if window is None:
            raise RuntimeError('Probe window missing from WindowServer')
        bounds = window['kCGWindowBounds']
        x, y, width, height = place['page']
        at = (bounds['X'] + x + width * .55, bounds['Y'] + y + height * .4)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, at, 0))
        for event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, event_type, at, 0))
        time.sleep(.2)
        data.setdefault('places', []).append(dict(window=place, bounds=dict(bounds), point=at))
        return at

    def shot(name):
        path = folder / (name + '.png')
        try:
            picture(proc.pid, path)
        except Exception as error:
            data.setdefault('capture_errors', []).append(str(error))
            if 'blackout is not' in str(error):
                raise
            ask('winshot', path=str(path))

    try:
        proc = launch(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own'), folder,
                      task_name=os.environ.get('YAB_TASK_NAME', 'Wheel input') + ' ' + label)
        at = open_pair('sheet')
        js("document.getElementById('sheet').scrollLeft=720; begin()")
        moves = [(i * .045, 4, 0, False, 0, 0) for i in range(50)]
        data['mouse_events'] = stream(at, moves)
        time.sleep(.7)
        mouse = js('result()')
        data['mouse'] = mouse
        trusted = sum(bool(e[4]) for e in mouse['wheels'])
        check('mouse events reach the page', trusted >= 20, trusted)
        check('mouse scroll reaches column A', mouse['left'] <= 1 and any(s[2] > 100 for s in mouse['samples']), mouse['left'])
        check('mouse overscroll does not navigate', mouse['url'].endswith('/sheet2'), mouse['url'])
        shot('mouse-at-column-a')

        at = open_pair('sheet')
        js("document.getElementById('sheet').scrollLeft=0; begin()")
        data['trackpad_events'] = stream(at, phased(horizontal=True))
        time.sleep(1.0)
        trackpad = js('result()')
        data['trackpad'] = trackpad
        check('phased swipe goes back once with momentum', trackpad['url'].endswith('/sheet1'), trackpad['url'])
        shot('trackpad-after-back')

        at = open_pair('feed')
        p0 = js('scrollTo(0,0);begin()')
        t0 = time.monotonic()
        data['feed_events'] = stream(at, phased())
        time.sleep(.35)
        feed = js('result()')
        data['feed'] = feed
        metrics = feed_metrics(feed['samples'], p0 + 30, p0 + 2750)
        data['feed_metrics'] = metrics
        check('vertical feed stays on its page', feed['url'].endswith('/feed2'), feed['url'])
        check('vertical feed advances throughout input', metrics['distance'] >= 2000 and metrics['moving_frames'] >= 45, metrics)
        check('vertical feed has no long motion stall', metrics['max_motion_gap_ms'] is not None and metrics['max_motion_gap_ms'] <= 180, metrics)
        data['feed_clock'] = dict(page_start=p0, python_start=t0)
        shot('vertical-feed-after-scroll')
    except Exception as error:
        data['error'] = repr(error)
        check('probe completed', False, repr(error))
    finally:
        if proc:
            try:
                proc.terminate()
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
        (folder / 'result.json').write_text(json.dumps(data, indent=2) + '\n')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--base-app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER') != '1':
        parser.error('Run through ./farm exec --exclusive --needs pointer,capture,pyobjc --display')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = dict(host=os.environ.get('WHERE'), load=os.getloadavg(), trials=[], comparison={})
    # An exclusive farm job is needed for the comparison. Do not interrupt
    # unrelated production rendering to make a host quiet.
    processes = subprocess.check_output(['ps', '-Ao', 'comm=,pcpu='], text=True)
    (out / 'processes-before.txt').write_text(processes)
    if any('remotion' in line.lower() or 'ffmpeg' in line.lower() for line in processes.splitlines()):
        report['error'] = 'Production rendering is present; quiet comparison unavailable'
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        raise RuntimeError('Production rendering is present; quiet comparison unavailable')
    server = serve(Page)
    try:
        base = url(server, '')
        for i, label in enumerate(('base', 'candidate', 'candidate', 'base')):
            trial = run(args.base_app if label == 'base' else args.app, out / f'{i}-{label}', label, base)
            report['trials'].append(trial)
        metrics = {}
        for label in ('base', 'candidate'):
            group = [t['feed_metrics'] for t in report['trials'] if t['label'] == label and 'feed_metrics' in t]
            if len(group) == 2 and all(g['p95_motion_gap_ms'] is not None for g in group):
                metrics[label] = {key: statistics.median(g[key] for g in group)
                                  for key in ('distance', 'moving_frames', 'p95_motion_gap_ms', 'max_motion_gap_ms')}
        report['comparison'] = metrics
        if len(metrics) == 2:
            a, b = metrics['base'], metrics['candidate']
            report['vertical_regression'] = (b['distance'] < a['distance'] * .85 or
                b['p95_motion_gap_ms'] > max(a['p95_motion_gap_ms'] * 1.5, a['p95_motion_gap_ms'] + 12) or
                b['max_motion_gap_ms'] > a['max_motion_gap_ms'] + 80)
        else:
            report['vertical_regression'] = None
        # The baseline may reproduce the bug. It must receive real input
        # and supply comparison data; only the candidate must meet every
        # functional expectation.
        delivered = all(c['passed'] for t in report['trials'] if t['label'] == 'base'
                        for c in t['checks'] if c['name'] == 'mouse events reach the page')
        report['passed'] = (len(report['trials']) == 4 and report['vertical_regression'] is False and delivered and
            all(c['passed'] for t in report['trials'] if t['label'] == 'candidate' for c in t['checks']))
        print(json.dumps({k: v for k, v in report.items() if k != 'trials'}, indent=2), flush=True)
    finally:
        server.shutdown()
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report.get('passed') else 1


if __name__ == '__main__':
    raise SystemExit(main())
