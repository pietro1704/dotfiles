import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch, call

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('macports_fallback', ROOT/'dot_local/lib/package-updates/macports-binary-fallback.py')
fallback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fallback)


class MacPortsFallback(unittest.TestCase):
    def test_both_archive_and_signature_must_exist(self):
        with patch.object(fallback, 'run', side_effect=['200', '404']):
            self.assertFalse(fallback.binary_available('https://packages.macports.org/test/archive'))
        with patch.object(fallback, 'run', side_effect=['200', '200']):
            self.assertTrue(fallback.binary_available('https://packages.macports.org/test/archive'))

    def test_binary_install_failure_never_removes_original(self):
        with patch.object(fallback, 'run', side_effect=['', subprocess.CalledProcessError(1, 'port')]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                fallback.migrate('gh','gh','gh','2.103.3',Path('/unneeded'))
            self.assertFalse(any('uninstall' in c.args[0] for c in run.call_args_list))

    def test_dependents_prevent_cross_manager_replacement(self):
        with patch.object(fallback, 'run', return_value='dependent') as run:
            with self.assertRaises(RuntimeError):
                fallback.migrate('gh','gh','gh','2.103.3',Path('/unneeded'))
            self.assertEqual(run.call_count, 1)

    def test_wrong_binary_version_preserves_original(self):
        with patch.object(fallback, 'run', side_effect=['', '', 'gh version 2.102.0']) as run:
            with self.assertRaises(RuntimeError):
                fallback.migrate('gh','gh','gh','2.103.3',Path('/unneeded'))
            self.assertFalse(any('uninstall' in c.args[0] for c in run.call_args_list))

    def test_dry_run_checks_archive_but_never_installs_or_removes(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix=Path(tmp)/'opt/gh'; prefix.mkdir(parents=True)
            executable=prefix/'bin/gh'; executable.parent.mkdir(); executable.write_text('original')
            def run(args):
                if args[:2]==['brew','outdated']:
                    return json.dumps({'formulae':[{'name':'gh','current_version':'2.103.3'}]})
                if args[:2]==['brew','ruby']: return '[]'
                if args[:2]==['brew','uses']: return ''
                if args[:2]==['brew','--prefix']: return str(prefix)
                if args[0].endswith('tclsh8.6'): return 'gh\t2.103.3\tgh-2.103.3_0.darwin_24.x86_64.tbz2'
                self.fail(str(args))
            with patch.object(fallback,'run',side_effect=run),patch.object(fallback.shutil,'which',side_effect=lambda name: str(executable) if name=='gh' else '/opt/local/bin/port'),patch.object(fallback,'binary_available',return_value=True):
                self.assertEqual(fallback.main(dry_run=True),0)
            self.assertEqual(executable.read_text(),'original')

    def test_success_keeps_rollback_copy_and_absolute_command_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp); prefix=home/'brew/opt/gh'; prefix.mkdir(parents=True)
            (prefix/'original').write_text('old bytes')
            (home/'brew/bin').mkdir()
            commands=[]
            def run(args):
                commands.append(args)
                return 'gh version 2.103.3' if args[0]=='/opt/local/bin/gh' else ''
            with patch.object(fallback,'run',side_effect=run),patch.object(fallback.Path,'home',return_value=home):
                fallback.migrate('gh','gh','gh','2.103.3',prefix)
            backups=list((home/'.local/state').glob('macports-migration-*/gh/original'))
            self.assertEqual(len(backups),1)
            self.assertEqual(backups[0].read_text(),'old bytes')
            self.assertEqual((home/'brew/bin/gh').readlink(),Path('/opt/local/bin/gh'))
            install=['sudo','port','-N','-b','install','gh']
            uninstall=['brew','uninstall','--formula','gh']
            self.assertLess(commands.index(install),commands.index(uninstall))
