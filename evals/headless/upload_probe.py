#!/usr/bin/env python3
"""Isolate headless upload and preserve blocked-process diagnostics on a farm host."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

from check import Probe, BROWSE, WORLD

sys.path.insert(0, BROWSE)
import prims
import server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin', required=True)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--temp-fixture', action='store_true')
    args = parser.parse_args()
    if os.environ.get('YAB_FARM_WORKER') != '1' or os.environ.get('WHERE') not in ('adhd', 'renderer-2', 'main'):
        parser.error('run through farm on an authorized remote host')
    args.out.mkdir(parents=True, exist_ok=True)
    scratch = os.path.realpath(tempfile.mkdtemp(prefix='yab-upload-probe-'))
    probe = Probe(os.path.abspath(args.bin), scratch, False)
    client = None
    finished = threading.Event()
    watcher = None
    try:
        try:
            servers = server.serve()
            threading.Thread(target=servers[0].serve_forever, daemon=True).start()
        except OSError:
            pass
        probe.start('--headless')
        client = prims.Mcp(probe.bin, WORLD, HOME=probe.home)
        prims.reset('upload')
        snapshot = client('open', url=prims.BASE + '/upload.html?task=prim-upload')
        tab = prims.tab_of(snapshot)
        fixture = Path(BROWSE) / 'files' / 'receipt-taxi.txt'
        if args.temp_fixture:
            fixture = Path(shutil.copy(fixture, Path(scratch) / fixture.name))
        (args.out / 'input.json').write_text(json.dumps({'binary':args.bin, 'file':str(fixture), 'pid':probe.pid(), 'mcp_pid':client.p.pid}))
        def sample_if_waiting():
            if finished.wait(10):
                return
            for name, pid in [('browser', probe.pid()), ('mcp', client.p.pid)]:
                if pid:
                    subprocess.run(['sample', str(pid), '2', '-file', str(args.out / (name + '.sample.txt'))], capture_output=True, timeout=15)
        watcher = threading.Thread(target=sample_if_waiting, daemon=True)
        watcher.start()
        client('upload', tab=tab, ref=prims.ref(snapshot, r'Receipt|file'), files=[str(fixture)])
        snapshot = client('snapshot', tab=tab)
        client('click', tab=tab, ref=prims.ref(snapshot, r'button "Attach"'))
        result = prims.settle('upload', 'file')
        (args.out / 'result.json').write_text(json.dumps(result))
        assert result.get('file') == {'name':'receipt-taxi.txt', 'size':39}, result
        print('PASS: headless upload reached the fixture with the expected name and bytes')
    finally:
        finished.set()
        if watcher:
            watcher.join(timeout=35)
        if client:
            client.close()
        probe.stop()
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == '__main__':
    main()
