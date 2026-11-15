"""Window-evidence regressions without native frameworks or a GUI."""
import argparse
import ast
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


source = Path(__file__).with_name('fullscreen.py')
names = {'same', 'inside', 'on_display', 'space_losses', 'main'}
tree = ast.parse(source.read_text())
helpers = ast.Module(body=[node for node in tree.body if isinstance(node, ast.FunctionDef)
                          and node.name in names or isinstance(node, ast.ClassDef)
                          and node.name == 'TextEdit'], type_ignores=[])
scope = {}
exec(compile(helpers, str(source), 'exec'), scope)


def row(number, frame, pid=20, alpha=1):
    return {'number': number, 'pid': pid, 'frame': frame, 'alpha': alpha, 'layer': 0}


class WindowEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.left = [-1440, 0, 1440, 900]
        self.right = [0, 0, 1920, 1080]
        self.fixture = {'number': 10, 'pid': 20, 'screen': self.left}
        self.text = row(10, self.left)

    def losses(self, *frames):
        return scope['space_losses']([{'windows': rows} for rows in frames], [self.fixture], 30)

    def test_other_display_order_does_not_affect_target(self):
        small = row(11, [-1400, 40, 800, 600], pid=40)
        other = row(12, self.right, pid=21)
        local = scope['on_display']([other, small, self.text], self.left)
        self.assertEqual([w['number'] for w in local], [11, 10])
        self.assertFalse(self.losses([other, small, self.text]))

    def test_adjacent_display_does_not_intersect(self):
        self.assertEqual(scope['on_display']([row(12, self.right)], self.left), [])

    def test_missing_source_is_not_called_yab_desktop(self):
        losses = self.losses([])
        self.assertTrue(losses[0]['full_screen_missing'])
        self.assertFalse(losses[0]['main_visible'])

    def test_single_transient_space_departure_is_retained(self):
        losses = self.losses([self.text], [], [self.text])
        self.assertEqual([loss['sample'] for loss in losses], [1])

    def test_main_window_exposure_identifies_desktop(self):
        losses = self.losses([row(30, [-1300, 100, 900, 600], pid=40)])
        self.assertTrue(losses[0]['main_visible'])

    def test_main_on_other_display_is_not_target_desktop(self):
        self.assertFalse(self.losses([self.text, row(30, [50, 50, 900, 600], pid=40)]))

    def test_hidden_or_moved_full_screen_window_does_not_count(self):
        self.assertTrue(self.losses([row(10, self.left, alpha=0)]))
        self.assertTrue(self.losses([row(10, [-1440, 20, 1440, 880])]))
        self.assertTrue(self.losses([row(10, self.left, pid=21)]))

    def test_geometry_handles_display_above_primary(self):
        above = [0, -1080, 1920, 1080]
        self.assertTrue(scope['inside']([50, -1000, 800, 600], above))
        self.assertFalse(scope['inside']([50, -1000, 800, 1100], above))

    def test_full_screen_fixture_is_not_resized_on_reentry(self):
        fixture = scope['TextEdit'](Path('unused-fixture.txt'), self.left)
        fixture.front = lambda: None
        fixture.listed = lambda: self.text
        scope['attribute'] = lambda *_: True
        scope['stable'] = lambda test, *_: test()
        scope['set_attribute'] = lambda *_: self.fail('Resized an already full-screen fixture')
        fixture.fullscreen(True)
        self.assertEqual(fixture.number, 10)


class ConfigurationTests(unittest.TestCase):
    def run_configuration(self, count, configuration='all', result=0):
        screens = [[index * 1920, 0, 1920, 1080] for index in range(count)]
        run = Mock(return_value=result)
        native = Mock()
        native.AXIsProcessTrusted.return_value = True
        with tempfile.TemporaryDirectory(dir=source.parent) as temporary:
            argv = ['fullscreen.py', '--app', 'prepared.app', '--out', temporary,
                    '--configuration', configuration]
            output = io.StringIO()
            with patch('sys.argv', argv), redirect_stdout(output), patch.dict(scope, {
                'argparse': argparse, 'Path': Path, 'os': os, 'json': json,
                'AX': native, 'screen_frames': lambda: screens, 'run': run,
            }), patch.dict(os.environ, {
                'YAB_FARM_WORKER': '1', 'WHERE': 'm4', 'YAB_FARM_HOST': 'm4',
            }):
                code = scope['main']()
            summary = json.loads((Path(temporary) / 'summary.json').read_text())
        return code, summary, output.getvalue(), run

    def test_one_display_runs_only_single_screen_scenarios(self):
        code, summary, output, run = self.run_configuration(1)
        self.assertEqual(code, 0)
        self.assertEqual(summary['results'], {'single': 0})
        self.assertEqual(run.call_count, 1)
        self.assertIn('SKIP multiple screens: Only one display is attached.', output)

    def test_multiple_displays_skip_single_and_keep_multi_screen_scenarios(self):
        for count in (2, 3):
            with self.subTest(displays=count):
                code, summary, output, run = self.run_configuration(count)
                self.assertEqual(code, 0)
                self.assertEqual(summary['results'], {'multi': 0})
                self.assertEqual(run.call_count, 1)
                self.assertEqual(summary['skips'][0]['name'], 'single-screen scenarios')
                self.assertIn('use a host with exactly one display', output)
                self.assertEqual(summary['original_screens'], summary['final_screens'])

    def test_single_only_on_multiple_displays_is_skipped_without_launching(self):
        code, summary, output, run = self.run_configuration(3, 'single')
        self.assertEqual(code, 0)
        self.assertIsNone(summary['passed'])
        self.assertEqual(summary['results'], {})
        run.assert_not_called()
        self.assertIn('SKIP all requested full-screen configurations', output)

    def test_multi_only_on_one_display_is_skipped_without_launching(self):
        code, summary, output, run = self.run_configuration(1, 'multi')
        self.assertEqual(code, 0)
        self.assertIsNone(summary['passed'])
        run.assert_not_called()
        self.assertIn('SKIP multiple screens', output)

    def test_no_displays_fails_without_launching(self):
        code, summary, output, run = self.run_configuration(0)
        self.assertEqual(code, 1)
        self.assertFalse(summary['passed'])
        run.assert_not_called()
        self.assertIn('No display is attached', output)

    def test_skipped_single_screen_does_not_hide_multi_screen_failure(self):
        code, summary, output, run = self.run_configuration(3, result=1)
        self.assertEqual(code, 1)
        self.assertFalse(summary['passed'])
        self.assertEqual(summary['results'], {'multi': 1})
        self.assertEqual(run.call_count, 1)
        self.assertIn('FAIL all requested full-screen configurations', output)


if __name__ == '__main__':
    unittest.main()
