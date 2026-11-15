"""Contracts preventing overnight runs from silently losing failures."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('overnight', Path(__file__).with_name('overnight.py'))
night = importlib.util.module_from_spec(spec)
spec.loader.exec_module(night)


class OvernightTests(unittest.TestCase):
    def test_failure_is_durable_and_later_stage_still_runs(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, {'farm': types.SimpleNamespace(guard=lambda display: None)}):
            out, state = Path(directory), {'stages': []}
            self.assertFalse(night.run_stage(out, state, 'failure', [sys.executable, '-c', 'raise SystemExit(7)']))
            self.assertTrue(night.run_stage(out, state, 'next', [sys.executable, '-c', 'pass']))
            persisted = night.json.loads((out / 'status.json').read_text())
            self.assertEqual([7, 0], [s['returncode'] for s in persisted['stages']])

    def test_appending_a_failure_replaces_an_old_success_summary(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, {'farm': types.SimpleNamespace(guard=lambda display: None)}):
            out = Path(directory)
            state = {'stages': [], 'status': 'completed_pending_coverage_review'}
            self.assertFalse(night.run_stage(out, state, 'late-regression', [sys.executable, '-c', 'raise SystemExit(1)']))
            persisted = night.json.loads((out / 'status.json').read_text())
            self.assertEqual('stages_completed_with_failures', persisted['status'])

    def test_timeout_is_durable_and_stops_batch(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, {'farm': types.SimpleNamespace(guard=lambda display: None)}):
            out, state = Path(directory), {'stages': []}
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                night.run_stage(out, state, 'timeout', [sys.executable, '-c', 'import time; time.sleep(60)'], timeout=.1)
            self.assertEqual('timeout', night.json.loads((out / 'status.json').read_text())['stages'][0]['status'])

    def test_skips_stay_visible(self):
        self.assertEqual(['SKIP accessibility missing', '1 gap'], night.notices('22 pass, 0 fail, 0 gap\nSKIP accessibility missing\n1 gap'))

    def test_refuses_local_execution(self):
        with patch.dict(night.os.environ, {}, clear=True), patch.object(sys, 'argv', ['overnight.py', 'profiles']):
            with self.assertRaises(SystemExit) as stopped:
                night.main()
            self.assertEqual(2, stopped.exception.code)


if __name__ == '__main__':
    unittest.main()
