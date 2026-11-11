"""Shell entry points select mise and preserve explicit virtual environments."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('zsh'), 'zsh is required')
class MiseShell(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.bin = self.home / '.local/bin'
        self.shims = self.home / '.local/share/mise/shims'
        self.bin.mkdir(parents=True)
        self.shims.mkdir(parents=True)
        self.env = {**os.environ, 'HOME': str(self.home), 'PATH': '/usr/bin:/bin'}
        source = (ROOT / 'dot_zshenv.tmpl').read_text()
        fragment = source[source.index('# Stable entry points'):source.rindex('{{ end -}}')]
        self.fragment = self.home / 'path.zsh'
        self.fragment.write_text(fragment)

    def run_shell(self, code):
        r = subprocess.run(['zsh', '-dfc', code], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip().splitlines()

    def test_inherited_version_paths_are_removed_and_shims_have_priority(self):
        old = str(self.home / '.local/share/mise/installs/node/old/bin')
        code = f'path=("{old}" /usr/bin /bin); source "{self.fragment}"; source "{self.fragment}"; print -l $path'
        paths = self.run_shell(code)
        self.assertEqual(paths[:2], [str(self.shims), str(self.bin)])
        self.assertNotIn(old, paths)
        self.assertEqual(len(paths), len(set(paths)))

    def test_active_virtual_environment_keeps_priority(self):
        venv = self.home / 'venv'
        (venv / 'bin').mkdir(parents=True)
        self.env['VIRTUAL_ENV'] = str(venv)
        self.assertEqual(self.run_shell(f'source "{self.fragment}"; print $path[1]'), [str(venv / 'bin')])

    def test_reload_removes_old_nvm_functions_and_does_not_recreate_them(self):
        for name in ['mise', 'rbenv']:
            p = self.bin / name
            p.write_text('#!/bin/sh\nexit 0\n')
            p.chmod(0o755)
        (self.home / '.nvm').mkdir()
        (self.home / '.nvm/nvm.sh').write_text('node() { echo wrong-manager; }\n')
        source = (ROOT / 'dot_zshrc.tmpl').read_text()
        fragment = source[source.index('# Mise owns runtimes'):source.index('# ── Thefuck')]
        manager = self.home / 'manager.zsh'
        manager.write_text(fragment)
        code = f'''source "{self.fragment}"
node() {{ echo old-nvm; }}
npm() {{ echo old-nvm; }}
source "{manager}"
(( $+functions[node] == 0 && $+functions[npm] == 0 && $+functions[nvm] == 0 ))
'''
        self.assertEqual(self.run_shell(code), [])
