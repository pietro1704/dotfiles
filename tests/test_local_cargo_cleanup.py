import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'dot_local/lib/package-updates/binary-updates.zsh'


class LocalCargoCleanup(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.home = Path(work.name).resolve()
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.stub('lsof', 'exit 1')
        self.stub('cargo', "printf '%s\\n' \"$PWD:$*\" >> \"$HOME/calls\"")

    def stub(self, name, script):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + script + '\n')
        path.chmod(0o755)

    def make_cache(self, name):
        repo = self.home / name
        target = repo / 'target'
        target.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / '.gitignore').write_text('/target/\n')
        (target / 'CACHEDIR.TAG').write_text('Signature: 8a477f597d28d172789f06886806bc55\n')
        return target

    def invoke(self, *args):
        return subprocess.run(
            ['/bin/zsh', '-fc', 'source "$1"; shift; updateLocalCargoCleanup "$@"',
             'test', str(HELPER), *args],
            env=dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:/usr/bin:/bin'),
            text=True, capture_output=True, timeout=10,
        )

    def test_dry_run_and_apply_are_restricted_to_the_two_caches(self):
        targets = [self.make_cache(name) for name in ('ai-memory', 'Developer/ai-jail-pasteboard')]
        self.make_cache('other')
        for args in [('--dry-run',), ()]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.home / 'calls'
                options = '--offline --dry-run' if args else '--offline'
                self.assertEqual(calls.read_text().splitlines(), [
                    f'{target.parent}:clean {options} --target-dir {target}' for target in targets
                ])
                calls.unlink()

    def test_skips_symlink_tracked_and_open_targets(self):
        target = self.make_cache('ai-memory')
        other = target.rename(target.with_name('other'))
        target.symlink_to(other, target_is_directory=True)
        tracked = self.make_cache('Developer/ai-jail-pasteboard')
        subprocess.run(['git', '-C', str(tracked.parent), 'add', '-f', 'target/CACHEDIR.TAG'],
                       check=True)
        self.assertEqual(self.invoke().returncode, 0)
        self.assertFalse((self.home / 'calls').exists())
        target.unlink()
        other.rename(target)
        self.stub('lsof', 'echo open; exit 0')
        self.assertIn('cache em uso', self.invoke().stdout)
        self.assertFalse((self.home / 'calls').exists())

    def test_cargo_failure_continues_and_cancel_stops(self):
        self.make_cache('ai-memory')
        self.make_cache('Developer/ai-jail-pasteboard')
        for rc, count in ((1, 2), (130, 1)):
            self.stub('cargo', f'echo called >> "$HOME/calls"; exit {rc}')
            self.assertEqual(self.invoke().returncode, rc)
            calls = self.home / 'calls'
            self.assertEqual(len(calls.read_text().splitlines()), count)
            calls.unlink()
