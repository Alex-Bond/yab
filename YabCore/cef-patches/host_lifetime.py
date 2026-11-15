"""Natural AppKit exit of one original native pixel acceptance host."""
import json
import os
from pathlib import Path
import signal
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'evals/chromium-extensions'))
from owned_processes import DarwinProcesses


def exact_host_receipt(value, pid, token):
    return (value.get('pid') == pid and value.get('exitToken') == token and
            value.get('naturalAppKitTerminate') is True)


class NativeHostLifetime:
    def __init__(self, process, executable, out, *, reader=None):
        self.process, self.executable, self.out = process, Path(executable).resolve(), Path(out)
        self.reader = reader if reader is not None else DarwinProcesses()
        self.original = self.reader.read(process.pid)
        if self.original and Path(self.original.executable).resolve() != self.executable:
            self.original = None
        self.receipt = None

    def _current(self):
        current = self.reader.read(self.process.pid)
        return current if self.original and current and current.identity == self.original.identity else None

    def close(self):
        if self.receipt is not None:
            return self.receipt['passed']
        row = {'model': 'original-native-host-appkit-exit-v1', 'pid': self.process.pid,
               'birth': list(self.original.birth) if self.original else None,
               'executable': str(self.executable), 'passed': False, 'forced': [],
               'nativeQuitAccepted': False, 'observedGone': False, 'exitStatus': None}
        try:
            if self.original is None or self.process.poll() is not None or not self._current():
                raise RuntimeError('Original host identity unavailable or exited before native quit')
            value = json.loads((self.out / 'host-window.json').read_text())
            token = value.get('exitToken')
            if value.get('pid') != self.process.pid or not isinstance(token, str) or not 1 <= len(token) <= 128:
                raise RuntimeError('Missing original host quit authority')
            request = self.out / 'host-exit.json'
            temporary = request.with_suffix('.pending')
            temporary.write_text(json.dumps({'pid': self.process.pid, 'exitToken': token}))
            temporary.replace(request)
            row['exitStatus'] = self.process.wait(timeout=15)
            ack = json.loads((self.out / 'host-exit-result.json').read_text())
            row['nativeQuitAccepted'] = exact_host_receipt(ack, self.process.pid, token)
            row['observedGone'] = self.reader.read(self.process.pid) is None
            row['passed'] = row['nativeQuitAccepted'] and row['observedGone'] and row['exitStatus'] == 0
        except Exception as error:
            row['error'] = repr(error)
        finally:
            # Failure cleanup can touch only this exact recorded microsecond birth.
            # A signal is never admitted as natural host shutdown.
            if self.process.poll() is None:
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    if self._current():
                        os.kill(self.process.pid, sig)
                        row['forced'].append(int(sig))
                    try:
                        self.process.wait(timeout=3)
                        break
                    except Exception:
                        continue
            row['passed'] = row['passed'] and not row['forced'] and 'error' not in row
            self.receipt = row
            (self.out / 'host-cleanup.json').write_text(json.dumps(row, indent=2) + '\n')
        return row['passed']
