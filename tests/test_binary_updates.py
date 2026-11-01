import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'dot_local/lib/package-updates'

class BinaryUpdates(unittest.TestCase):
    def run_update(self, command, rc=0, fail='', fail_mode=''):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            target = home / '.local/lib/package-updates'
            target.parent.mkdir(parents=True)
            target.symlink_to(LIB)
            bindir = home / 'bin'
            bindir.mkdir()
            for name in ('brew', 'port', 'sudo'):
                path = bindir / name
                path.write_text('#!/bin/zsh\nprint -r -- "${0:t} $* mode=${HOMEBREW_BINARY_UPDATE_MODE:-}" >> "$LOG"\n[[ "$*" == "$FAIL" ]] && exit "$RC"\n[[ -n "$FAIL_MODE" && "${HOMEBREW_BINARY_UPDATE_MODE:-}" == "$FAIL_MODE" ]] && exit "$RC"\nexit 0\n')
                path.chmod(0o755)
            env = dict(os.environ, HOME=tmp, PATH=str(bindir)+':/usr/bin:/bin',
                       LOG=str(home/'log'), FAIL=fail, FAIL_MODE=fail_mode, RC=str(rc))
            script = 'source "$HOME/.local/lib/package-updates/binary-updates.zsh"\n' + command
            result = subprocess.run(['/bin/zsh', '-f'], input=script, text=True,
                                    capture_output=True, env=env, timeout=10)
            log = (home/'log').read_text() if (home/'log').exists() else ''
            return result, log

    def test_dry_run_never_updates_or_cleans(self):
        result, log = self.run_update('updatePackagesBinaryOnly --dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('port -N -b -y upgrade outdated', log)
        self.assertIn('mode=dry-run', log)
        self.assertIn('mode=cask-dry-run', log)
        self.assertNotIn('brew update', log)
        self.assertNotIn('cleanup', log)
        self.assertNotIn('sudo', log)

    def test_update_failure_and_cancellation_stop_brew(self):
        for rc in (1, 130):
            result, log = self.run_update('updateBrewBinaryOnly', rc, 'update')
            self.assertEqual(result.returncode, rc)
            self.assertNotIn('brew ruby', log)
            self.assertNotIn('cleanup', log)

    def test_apply_uses_guard_and_no_source_selfupdate(self):
        result, log = self.run_update('updatePackagesBinaryOnly')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('sudo port -N sync', log)
        self.assertIn('sudo port -N -b upgrade outdated', log)
        self.assertIn('mode=apply', log)
        self.assertIn('mode=cask-apply', log)
        self.assertNotIn('selfupdate', log)
        self.assertNotIn('brew upgrade', log)

    def test_guard_failure_prevents_cleanup_and_cancel_stops_casks(self):
        for rc in (1, 130):
            result, log = self.run_update('updateBrewBinaryOnly', rc, fail_mode='apply')
            self.assertEqual(result.returncode, rc)
            self.assertNotIn('cleanup', log)
            if rc == 130:
                self.assertNotIn('mode=cask-apply', log)

    def test_unknown_argument_does_nothing(self):
        result, log = self.run_update('updatePackagesBinaryOnly --oops')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(log, '')

    def test_legacy_entrypoint_only_updates_brew_and_forwards_args(self):
        result, log = self.run_update(f'/bin/zsh "{ROOT / "dot_updateBrew.sh"}" --dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mode=dry-run', log)
        self.assertNotIn('port ', log)
        self.assertNotIn('brew upgrade', log)

if __name__ == '__main__':
    unittest.main()
