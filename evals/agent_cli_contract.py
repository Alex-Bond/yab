#!/usr/bin/env python3
"""Check CLI routing against a synthetic Unix socket, without starting agents."""
import argparse
import json
import socket
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bin', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    cases = [
        (['please', 'steer', 'this'], {'do': 'agent-run', 'prompt': 'please steer this'}),
        (['please', 'queue', 'this'], {'do': 'agent-run', 'prompt': 'please queue this'}),
        (['steer', 'fixture-session', 'change', 'plan'], {'do': 'agent-steer', 'session': 'fixture-session', 'text': 'change plan'}),
        (['queue', 'fixture-session', 'next', 'step'], {'do': 'agent-queue', 'session': 'fixture-session', 'text': 'next step'}),
    ]
    results = []
    with tempfile.TemporaryDirectory(prefix='yab-cli-') as scratch:
        path = str(Path(scratch) / 'bench.sock')
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(path)
            server.listen(1)
            server.settimeout(10)
            for words, expected in cases:
                proc = subprocess.Popen([args.bin, 'agent', '--socket', path, *words], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    with server.accept()[0] as connection:
                        connection.settimeout(5)
                        data = b''
                        while b'\n' not in data:
                            chunk = connection.recv(4096)
                            if not chunk:
                                raise RuntimeError('CLI closed before a complete request')
                            data += chunk
                        request = json.loads(data.split(b'\n')[0])
                        connection.sendall(b'{"error":"fixture stop"}\n')
                    stdout, stderr = proc.communicate(timeout=5)
                    passed = proc.returncode == 1 and all(request.get(k) == v for k, v in expected.items())
                    results.append(dict(words=words, expected=expected, request=request, passed=passed, exit=proc.returncode))
                finally:
                    if proc.poll() is None:
                        proc.kill()
                    proc.communicate(timeout=5)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2), flush=True)
    return int(not all(result['passed'] for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
