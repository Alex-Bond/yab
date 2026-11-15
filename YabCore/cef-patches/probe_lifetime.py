"""Prepared native helper and pixel host lifetime for the original R1 probes."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'evals/chromium-extensions'))
from prepared_lifetime import PreparedHelperLifetime
from host_lifetime import NativeHostLifetime


def finish_helper(lifetime, report):
    detail = {'ok': True, 'checks': {}}
    natural = lifetime.finish(detail)
    report['naturalHelperExit'] = natural
    report['helperShutdownReceipt'] = lifetime.receipt
    report['passed'] = report.get('passed') is True and natural
    if not natural:
        raise RuntimeError('Original native helper or its children required forced/unknown cleanup')


def finish_host(lifetime, report):
    natural = lifetime.close()
    report['naturalHostExit'] = natural
    report['passed'] = report.get('passed') is True and natural
    if not natural:
        raise RuntimeError('Original native pixel host did not acknowledge natural AppKit termination')
