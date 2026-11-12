import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ai_tools_brew", ROOT / "dot_local/lib/package-updates/ai-tools-brew.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class AiToolsBrew(unittest.TestCase):
    def test_rejects_nonstable_and_untrusted_tags(self):
        for tag in ("v3.3.1;bad", "master", "v3.4.0-rc1"):
            with patch.object(updater, "fetch", return_value=json.dumps({"tag_name": tag, "assets": []})):
                with self.assertRaises(RuntimeError):
                    updater.latest("ai-jail")

    def test_dry_run_does_not_mutate_or_install(self):
        with patch.object(updater.platform, "system", return_value="Darwin"), patch.object(updater.platform, "machine", return_value="x86_64"), patch.object(updater, "latest", return_value=("3.3.1", set())), patch.object(updater, "run", return_value="/usr/local") as run:
            updater.update(dry_run=True)
            self.assertEqual(run.call_args_list, [unittest.mock.call("brew", "--prefix", capture=True)])

    def test_source_and_binary_formulas_use_correct_install_path(self):
        source = updater.formula("3.3.1", "https://example.invalid/source", "0"*64, True)
        self.assertIn('"--locked", "--jobs", "2"', source)
        self.assertIn('target/release/ai-jail', source)
        self.assertIn('HOMEBREW_PREFIX/"opt/rust/bin/cargo"', source)
        binary = updater.formula("3.3.1", "https://example.invalid/binary", "0"*64, False)
        self.assertNotIn('depends_on', binary)
        self.assertNotIn('cargo', binary)

    def test_migration_preserves_config_and_uses_stable_opt_link(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(updater, "run"):
            home = Path(tmp)
            old = home / '.local/bin/ai-memory'
            old.parent.mkdir(parents=True)
            old.write_text('old executable')
            config = home / '.config/ai-memory/config.toml'
            config.parent.mkdir(parents=True)
            config.write_text('keep this private configuration')
            updater.migrate('ai-memory', home/'brew', home)
            self.assertEqual(old.readlink(), home/'brew/opt/ai-memory/bin/ai-memory')
            self.assertEqual(config.read_text(), 'keep this private configuration')
            backups = list((home/'.local/state').glob('ai-tools-migration-*/ai-memory'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), 'old executable')
            updater.migrate('ai-memory', home/'brew', home)
            self.assertEqual(len(list((home/'.local/state').iterdir())), 1)

    def test_failed_binary_validation_keeps_original(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(updater, 'run', side_effect=subprocess.CalledProcessError(1, 'binary')):
            home = Path(tmp)
            old = home/'.local/bin/ai-jail'
            old.parent.mkdir(parents=True)
            old.write_text('original')
            with self.assertRaises(subprocess.CalledProcessError):
                updater.migrate('ai-jail', home/'brew', home)
            self.assertEqual(old.read_text(), 'original')

    def test_cancelled_atomic_replacement_keeps_original(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(updater, 'run'), patch.object(updater.os, 'replace', side_effect=KeyboardInterrupt):
            home = Path(tmp)
            old = home/'.local/bin/ai-jail'
            old.parent.mkdir(parents=True)
            old.write_text('original')
            with self.assertRaises(KeyboardInterrupt):
                updater.migrate('ai-jail', home/'brew', home)
            self.assertEqual(old.read_text(), 'original')
            self.assertEqual(list(old.parent.iterdir()), [old])

    def test_low_storage_refuses_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp)
            tap = prefix/'Homebrew/Library/Taps/pietro1704/homebrew-ai-tools-local'
            tap.mkdir(parents=True)
            def run(*args, **kwargs):
                if args == ('brew', '--prefix'):
                    return tmp
                if args[:2] == ('brew', 'info'):
                    return '{"formulae": []}'
                self.fail(f'Unexpected mutation: {args}')
            with patch.object(updater.platform, 'system', return_value='Darwin'), patch.object(updater.platform, 'machine', return_value='x86_64'), patch.object(updater, 'latest', return_value=('3.3.1', set())), patch.object(updater, 'run', side_effect=run), patch.object(updater.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1})()):
                with self.assertRaisesRegex(RuntimeError, '8 GiB'):
                    updater.update_jail(prefix, prefix, "3.3.1", set(), True, True)
                self.assertFalse((tap/'Formula/ai-jail.rb').exists())

    def test_no_opt_in_never_downloads_or_builds_source(self):
        with patch.object(updater, 'run', return_value='{"formulae": []}') as run:
            updater.update_jail(Path('/unused'), Path('/unused'), '3.3.1', set(), True, False)
            self.assertEqual(len(run.call_args_list), 1)

    def test_source_queue_cannot_run_without_permission(self):
        result = subprocess.run(['python3', str(ROOT/'dot_local/lib/package-updates/ai-tools-brew.py'), '--source-only'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
