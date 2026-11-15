#!/usr/bin/env python3
"""Supply a local document for the windowless native header diagnostic."""
import argparse
import http.server
import json
from pathlib import Path
import subprocess
import threading


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Synthetic navigation headers</title>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([args.probe, f'http://127.0.0.1:{server.server_port}/eme'],
                                capture_output=True, text=True, timeout=40)
        report = json.loads(result.stdout) if result.stdout.strip() else {}
        report['exit'] = result.returncode
        args.out.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
        if result.stderr:
            args.out.with_suffix('.stderr.log').write_text(result.stderr)
        raise SystemExit(result.returncode)
    finally:
        server.shutdown()
