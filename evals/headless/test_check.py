import importlib.util
from pathlib import Path
import subprocess
import sys
import time
import unittest

spec = importlib.util.spec_from_file_location('headless_check', Path(__file__).with_name('check.py'))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class McpReadTests(unittest.TestCase):
    def client(self, source):
        client = check.Mcp.__new__(check.Mcp)
        client.n, client.pending = 0, b''
        client.p = subprocess.Popen([sys.executable, '-u', '-c', source], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(client.end, kill=True)
        return client

    def test_notification_and_reply_in_one_read(self):
        client = self.client('import sys; sys.stdin.readline(); print(\'{"method":"notice"}\\n{"id":1,"result":{"ok":true}}\')')
        self.assertEqual({'ok': True}, client.call('initialize', {}, timeout=2))

    def test_partial_line_has_a_deadline(self):
        client = self.client('import sys,time; sys.stdin.readline(); sys.stdout.write(\'{"id":\'); sys.stdout.flush(); time.sleep(60)')
        start = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            client.call('initialize', {}, timeout=.2)
        self.assertLess(time.monotonic() - start, 2)

    def test_closed_pipe_is_a_failure(self):
        client = self.client('import sys; sys.stdin.readline()')
        with self.assertRaisesRegex(ValueError, 'closed stdout'):
            client.call('initialize', {}, timeout=2)

    def test_cleanup_reaps_client_and_is_repeatable(self):
        client = self.client('import time; time.sleep(60)')
        client.end(kill=True)
        client.end(kill=True)
        self.assertIsNotNone(client.p.returncode)


browser_spec = importlib.util.spec_from_file_location('browser_prims', Path(__file__).parents[1] / 'browse' / 'prims.py')
prims = importlib.util.module_from_spec(browser_spec)
browser_spec.loader.exec_module(prims)


class BrowserMcpReadTests(McpReadTests):
    def client(self, source):
        client = prims.Mcp.__new__(prims.Mcp)
        client.n, client.pending = 0, b''
        client.p = subprocess.Popen([sys.executable, '-u', '-c', source], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        client.call = client.call_raw
        client.end = lambda kill=False: client.close()
        self.addCleanup(client.close)
        return client

    def test_closed_pipe_is_a_failure(self):
        client = self.client('import sys; sys.stdin.readline()')
        with self.assertRaisesRegex(RuntimeError, 'closed stdout'):
            client.call('initialize', {}, timeout=2)


class CliReadTests(unittest.TestCase):
    def child(self, source):
        proc = subprocess.Popen([sys.executable, '-u', '-c', source], stdout=subprocess.PIPE)
        def cleanup():
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            proc.stdout.close()
        self.addCleanup(cleanup)
        return proc

    def test_silent_process_has_a_deadline(self):
        proc = self.child('import time; time.sleep(60)')
        with self.assertRaises(subprocess.TimeoutExpired):
            list(check.bounded_lines(proc, .2))

    def test_partial_line_has_a_deadline(self):
        proc = self.child('import sys,time; sys.stdout.write("partial"); sys.stdout.flush(); time.sleep(60)')
        with self.assertRaises(subprocess.TimeoutExpired) as raised:
            list(check.bounded_lines(proc, .2))
        self.assertEqual(b'partial', raised.exception.output)

    def test_multiple_lines_and_unterminated_eof(self):
        proc = self.child('import sys; sys.stdout.write("one\\ntwo\\nlast")')
        self.assertEqual(['one\n', 'two\n', 'last'], list(check.bounded_lines(proc, 2)))


if __name__ == '__main__':
    unittest.main()
