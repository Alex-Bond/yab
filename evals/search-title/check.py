"""A new search in a new tab never wears the last search's title.

History keys a page by host and path, so every search on one engine is
one row. Before 967f17533 a tab loading "new" read "old - Search" in the
column until its page named itself (the user's recording, 2026-11-11:
"cmux next - Google Search" for five seconds while "cmux" loaded).

A local search page stands in for Google: /search?q=old answers at once,
/search?q=new after four seconds. The new tab's row is read every 100 ms
while it loads. Isolated world, no signed-in data.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import sys
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'evals/extensions')]
from release_matrix import Probe

SLOW = 4.0


class Pages(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get('q', [''])[0]
        if query == 'new':
            time.sleep(SLOW)
        body = (f'<!doctype html><meta charset=utf-8><title>{query} - Search</title>'
                f'<body style="font:32px system-ui">Results for {query}').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def wait(read, accept, seconds=20):
    end = time.monotonic() + seconds
    value = None
    while time.monotonic() < end:
        value = read()
        if accept(value): return value
        time.sleep(.1)
    raise RuntimeError('condition did not settle: ' + repr(value))


def run(app, out, label, base):
    out.mkdir(parents=True, exist_ok=True)
    world = Probe(app, 'searchtitle-' + label, out,
                  os.environ.get('YAB_TASK_NAME', 'Search title') + (' A' if label == 'before' else ' B'))
    ask = world.bench
    report = {'label': label, 'app': str(app)}
    try:
        def row(ident):
            return next((t for t in world.tabs() if t['id'] == ident), None)
        old = ask('usage-open', url=base + '/search?q=old', foreground=True)['id']
        wait(lambda: row(old), lambda t: t and t['title'] == 'old - Search' and not t['loading'])
        time.sleep(1.5)  # history writes the title after the commit
        new = ask('usage-open', url=base + '/search?q=new', foreground=True)['id']
        seen = []
        end = time.monotonic() + SLOW + 6
        while time.monotonic() < end:
            t = row(new)
            if t:
                seen.append({'at': round(time.monotonic() - (end - SLOW - 6), 2), 'row': t['row'], 'loading': t['loading']})
                if t['title'] == 'new - Search' and not t['loading']:
                    break
            time.sleep(.1)
        rows = [s['row'] for s in seen]
        report['rows'] = sorted(set(rows), key=rows.index)
        report['samples'] = seen
        report['old_title_shown'] = sum(1 for r in rows if r == 'old - Search')
        report['settled'] = bool(rows) and rows[-1] == 'new - Search'
    finally:
        world.quit()
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-app')
    parser.add_argument('--app', required=True)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    out = Path(os.environ.get('YAB_FARM_OUT', '/tmp/search-title'))
    results = {}
    if args.base_app:
        results['before'] = run(Path(args.base_app), out / 'before', 'before', base)
    results['after'] = run(Path(args.app), out / 'after', 'after', base)
    for name, r in results.items():
        print(f"{name}: rows {r['rows']}; old title shown in {r['old_title_shown']} samples; settled {r['settled']}")
    after = results['after']
    ok = after['old_title_shown'] == 0 and after['settled']
    if 'before' in results:
        ok = ok and results['before']['old_title_shown'] > 0
    (out / 'summary.json').write_text(json.dumps({'ok': ok, **{k: {x: v[x] for x in ('rows', 'old_title_shown', 'settled')} for k, v in results.items()}}, indent=2))
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
