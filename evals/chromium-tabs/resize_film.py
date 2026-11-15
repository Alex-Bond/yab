#!/usr/bin/env python3
"""Resize film of a real Yab window with a Chromium page. Farm only.

ScreenCaptureKit pictures are taken continuously while the bench drags the
window corner in small steps (expand, shrink, A/B/A). Each frame is scanned
from the page's right and bottom edges inward for the first page-colored
pixel; the distance beyond the settled margin is exposed backing.
"""
import argparse
import http.server
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from probe_capture import picture
import yab_socket
from PIL import Image
from run import launch_exact, wait_for

PAGE = b'''<!doctype html><meta charset="utf-8"><title>Resize film</title>
<style>html,body{margin:0;background:#12783c;color:white;font:24px system-ui}h1{margin:20px}</style>
<h1>Chromium resize film</h1>'''


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(PAGE)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def green(pixel):
    r, g, b = pixel[:3]
    return g > 60 and g > r * 1.5 and g > b * 1.3


def exposure(path, frame, window_size, scale):
    """Pixels between the page view's right/bottom edge and the first page color.

    The page keeps constant margins to the window's left, top, right and bottom
    edges while the window is dragged, so its edges are placed from the
    captured picture's own size, not from a state read a moment earlier.
    """
    captured = Image.open(path).convert('RGBA')
    # SCK can retain the previous stream allocation during a shrink. The
    # transparent padding surrounds the whole window, including its sidebar;
    # it is not backing exposed inside the page. Preserve every opaque pixel.
    extent = captured.getchannel('A').getbbox()
    if extent is None:
        raise RuntimeError('Capture contains no window pixels')
    image = captured.crop(extent).convert('RGB')
    width, height = image.size
    pixels = image.load()
    margin_right = window_size[0] - (frame[0] + frame[2])
    margin_top = window_size[1] - (frame[1] + frame[3])
    left = int(frame[0] * scale)
    right = width - int(margin_right * scale) - 1
    top = int(margin_top * scale)
    bottom = height - int(frame[1] * scale) - 1
    result = {}
    gaps = []
    for k in range(2, 7):
        y = top + (bottom - top) * k // 8
        x = right
        while x > left and not green(pixels[x, y]):
            x -= 1
        gaps.append(right - x)
    result['right'] = max(gaps)
    gaps = []
    for k in range(2, 7):
        x = left + (right - left) * k // 8
        y = bottom
        while y > top and not green(pixels[x, y]):
            y -= 1
        gaps.append(bottom - y)
    result['bottom'] = max(gaps)
    result['image'] = [width, height]
    result['captureExtent'] = list(extent)
    result['captureSize'] = list(captured.size)
    return result


def run(app, out, site, require_ack=False, split=False):
    out.mkdir(parents=True, exist_ok=True)
    frames_dir = out / 'frames'
    frames_dir.mkdir(exist_ok=True)
    world = 'chromium-film-' + uuid.uuid4().hex[:8]
    domain = 'dev.serafim.fast.test.' + world
    sock = Path.home() / 'Library/Application Support' / f'Yab ({world})' / 'bench.sock'
    defaults = out / 'defaults.plist'
    defaults.write_bytes(plistlib.dumps({'bench': True, 'welcomed': True, 'mail': False,
                                        'hints.noticing': False, 'searchSuggest': False}))
    subprocess.run(['defaults', 'import', domain, str(defaults)], check=True)
    proc = launch_exact(app, dict(os.environ, YAB_PROBE=world, YAB_HISTORY='own', YAB_ENGINE='chromium',
                                 YAB_AGENT_CLAUDE='/usr/bin/true', YAB_AGENT_CODEX='/nonexistent/chromium'), out)
    ask = yab_socket.kwasker(sock, timeout=45, strict=True, takes_timeout=True,
                            fail=lambda req, reply: RuntimeError(f'{req}: {reply}'))
    report = {'app': str(app), 'mode': 'split' if split else 'ordinary', 'frames': [], 'settled': []}
    try:
        wait_for(lambda: sock.exists() if proc.poll() is None else False, 'Yab bench socket missing', 60)
        ask(do='ui', welcome=False, sidebar=True)
        tab = ask(do='usage-open', url=site + '/')['id']
        wait_for(lambda: (lambda s: s if s['context'] > 0 and not s['loading'] and s['title'] == 'Resize film' else None)(
            ask(do='chromium', id=tab)), 'Chromium page did not become ready')
        partner = None
        if split:
            other = ask(do='usage-open', url=site + '/other')['id']
            wait_for(lambda: (lambda s: s['context'] > 0 and not s['loading'])(ask(do='chromium', id=other)),
                     'Second Chromium page did not become ready', 30)
            ask(do='split', act='with', id=tab)
            time.sleep(.8)
            pair = sorted([tab, other], key=lambda value: ask(do='chromium', id=value)['frame'][0])
            partner, tab = pair
            report['splitTabs'] = pair
        ask(do='resize', width=1000, height=700, steps=1)
        time.sleep(1.2)
        counter = [0]
        scale = []

        def acknowledged():
            state = ask(do='chromium', id=tab)
            surface = state.get('surface', {})
            size = [math.ceil(v) for v in state['frame'][2:]]
            ready = (surface.get('resizeNative') and not surface.get('resizePending') and
                     surface.get('resizeAcknowledged') and surface.get('resizeCommitted') == size)
            if ready and partner:
                other = ask(do='chromium', id=partner)
                receipt = other.get('surface', {})
                ready = (receipt.get('resizeNative') and not receipt.get('resizePending') and
                         receipt.get('resizeAcknowledged') and
                         receipt.get('resizeCommitted') == [math.ceil(v) for v in other['frame'][2:]])
            return state if ready else None

        if require_ack:
            wait_for(acknowledged, 'Initial native resize acknowledgement missing', 15)

        def shot(label):
            state = ask(do='chromium', id=tab)
            counter[0] += 1
            path = frames_dir / f'{counter[0]:03d}-{label}.png'
            meta = picture(proc.pid, path, window_id=state['window'])
            if not scale:
                # The capture is the window at its screen's pixel scale.
                scale.append(Image.open(path).size[0] / state['windowSize'][0])
            row = {'file': path.name, 'label': label, 'frame': state['frame'],
                   'capture': meta.get('capture'), 'scale': scale[0], 'surface': state.get('surface', {})}
            row.update(exposure(path, state['frame'], state['windowSize'], scale[0]))
            return row

        settled = shot('settled-1000x700')
        report['settled'].append(settled)
        legs = [(1300, 860), (900, 620), (1300, 860), (1000, 700), (1250, 820), (1000, 700)]
        for width, height in legs:
            done = threading.Event()
            error = []

            def drag():
                try:
                    ask(do='resize', width=width, height=height, steps=45)
                except Exception as failure:
                    error.append(failure)
                finally:
                    done.set()
            thread = threading.Thread(target=drag)
            thread.start()
            while not done.is_set():
                report['frames'].append(shot(f'drag-{width}x{height}'))
            thread.join()
            if error:
                raise error[0]
            time.sleep(.8)
            if require_ack:
                wait_for(acknowledged, f'Native resize acknowledgement missing at {width}x{height}', 15)
            report['settled'].append(shot(f'settled-{width}x{height}'))
        margin_right = max(s['right'] for s in report['settled'])
        margin_bottom = max(s['bottom'] for s in report['settled'])
        exposed = [{'file': f['file'], 'right': f['right'] - margin_right, 'bottom': f['bottom'] - margin_bottom}
                   for f in report['frames']]
        report['margin'] = {'right': margin_right, 'bottom': margin_bottom}
        report['exposed'] = exposed
        report['maxExposedPixels'] = max([max(e['right'], e['bottom']) for e in exposed] or [0])
        report['framesWithExposure'] = sum(1 for e in exposed if max(e['right'], e['bottom']) > 2)
        report['captures'] = sorted({f['capture'] for f in report['frames'] + report['settled']})
        if require_ack:
            receipts = [s['surface'].get('resizeAcknowledged') for s in report['settled']]
            report['resizeReceipts'] = receipts
            assert len(set(receipts)) == len(legs) + 1, 'Each settled size needs a fresh native receipt'
            assert report['maxExposedPixels'] <= 2, f'Exposed backing: {report["maxExposedPixels"]} px'
        report['passed'] = True
    except Exception as failure:
        report['error'] = repr(failure)
        raise
    finally:
        (out / 'film.json').write_text(json.dumps(report, indent=2))
        try: ask(do='ui', act='quit')
        except Exception: pass
        if proc.poll() is None:
            proc.terminate()
        try: proc.wait(timeout=10)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
    print(json.dumps({k: report.get(k) for k in ('margin', 'maxExposedPixels', 'framesWithExposure', 'captures')}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--require-ack', action='store_true')
    parser.add_argument('--split', action='store_true')
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try: run(args.app.resolve(), args.out.resolve(), 'http://127.0.0.1:' + str(server.server_port), args.require_ack, args.split)
    finally: server.shutdown(); server.server_close()
