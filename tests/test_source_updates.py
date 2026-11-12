import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch, call

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('source_updates', ROOT/'dot_local/lib/package-updates/source-updates.py')
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class SourceUpdates(unittest.TestCase):
    def test_failed_app_does_not_stop_next(self):
        queue = [('one', ['compile', 'one']), ('two', ['compile', 'two'])]
        with patch.object(source, 'execute', side_effect=[subprocess.CalledProcessError(1, 'one'), None]) as execute, patch.object(source.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 20*1024**3})()):
            self.assertEqual(source.compile_queue(queue), ['one'])
            self.assertEqual(execute.call_args_list, [call(['compile', 'one']), call(['compile', 'two'])])

    def test_cancel_stops_queue(self):
        with patch.object(source, 'execute', side_effect=KeyboardInterrupt) as execute, patch.object(source.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 20*1024**3})()):
            with self.assertRaises(KeyboardInterrupt):
                source.compile_queue([('one', ['one']), ('two', ['two'])])
            self.assertEqual(execute.call_count, 1)

    def test_dry_run_executes_nothing(self):
        with patch.object(source, 'execute') as execute:
            self.assertEqual(source.compile_queue([('one', ['one'])], dry_run=True), [])
            execute.assert_not_called()

    def test_low_storage_blocks_every_build_and_reports_all(self):
        with patch.object(source, 'execute') as execute, patch.object(source.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1})()):
            self.assertEqual(source.compile_queue([('one', ['one']), ('two', ['two'])]), ['one', 'two'])
            execute.assert_not_called()

    def test_entrypoint_requires_opt_in_before_inventory(self):
        result = subprocess.run(['python3', str(ROOT/'dot_local/lib/package-updates/source-updates.py')], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_pin_release_dry_run_is_read_only(self):
        with patch.object(source, 'execute') as execute:
            self.assertEqual(source.release_pins(['rust', 'git'], dry_run=True), [])
            execute.assert_not_called()

    def test_pin_release_continues_after_one_failure(self):
        with patch.object(source, 'execute', side_effect=[subprocess.CalledProcessError(1, 'unpin'), None]) as execute:
            self.assertEqual(source.release_pins(['rust', 'git']), ['rust'])
            self.assertEqual(execute.call_args_list, [call(['brew', 'unpin', 'rust']), call(['brew', 'unpin', 'git'])])

    def test_pin_release_is_before_first_build(self):
        def execute(args, capture=False):
            if args[:2] == ['brew', 'ruby']:
                return '[{"name":"rust","pinned":true},{"name":"fd","pinned":false}]'
            return ''
        with patch.object(source, 'execute', side_effect=execute) as runner, patch.object(source.shutil, 'which', return_value=None), patch.object(source.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 20*1024**3})()):
            self.assertEqual(source.main(), 0)
            commands = [c.args[0] for c in runner.call_args_list]
            self.assertLess(commands.index(['brew','unpin','rust']), commands.index(['brew','upgrade','--formula','rust']))
