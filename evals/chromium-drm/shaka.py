#!/usr/bin/env python3
"""What a real player does on Chromium without Widevine: Shaka's demo, a Widevine
asset. Says how far the refusal got, for when the page stays on Chromium."""
import argparse
import http.server
import json
from pathlib import Path
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/cef'))
import importlib.util
spec = importlib.util.spec_from_file_location('r1s', ROOT / 'scripts/cef/r1-scenarios.py')
r1s = importlib.util.module_from_spec(spec)
sys.modules['r1s'] = r1s
spec.loader.exec_module(r1s)

SHAKA = 'https://shaka-player-demo.appspot.com/demo/#audiolang=en-US;textlang=en-US;uilang=en-US;asset=https://storage.googleapis.com/shaka-demo-assets/angel-one-widevine/dash.mpd;panel=HOME;build=compiled'
SPY = """
const c=navigator.mediaCapabilities,a=navigator.requestMediaKeySystemAccess;
return {href:location.href,capabilities:(c.decodingInfo+'').slice(0,60),access:(a+'').slice(0,60)}"""


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), r1s.Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    w = r1s.World(a.app.resolve(), a.out, f'http://127.0.0.1:{server.server_port}')
    report = {}
    try:
        tab = w.open(SHAKA)
        for second in range(30):
            state = w.ask(do='page-engine', id=tab)
            if state['engine'] == 'webKit':
                break
            time.sleep(1)
        report['engine'] = state
        report['seconds'] = second
        if state['engine'] != 'webKit':
            report['page'] = w.js(tab, SPY)
            report['native'] = {k: v for k, v in w.cr(tab).items() if k in ('url', 'lastEngineError', 'failure', 'remote')}
            # The same refusal asked again, now that the page has settled.
            report['asked'] = w.js(tab, "try{await navigator.requestMediaKeySystemAccess('com.widevine.alpha',[{initDataTypes:['cenc'],videoCapabilities:[{contentType:'video/mp4; codecs=\"avc1.42E01E\"'}]}]);return 'granted'}catch(e){return e.name}")
            time.sleep(4)
            report['after'] = w.ask(do='page-engine', id=tab)
    finally:
        (a.out / 'summary.json').write_text(json.dumps(report, indent=2, default=str) + '\n')
        print(json.dumps(report, default=str)[:3000], flush=True)
        try:
            w.ask(do='quit-ask', yes=True, timeout=8)
        except (OSError, ValueError):
            pass  # Nothing to ask, and the app was gone before it could answer.
        server.shutdown()
    return 0 if report.get('engine', {}).get('engine') == 'webKit' else 1


if __name__ == '__main__':
    raise SystemExit(main())
