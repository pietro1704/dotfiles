"""Launcher regressions with isolated homes; no real agent or memory server."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'dot_local/bin'


class Launchers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.env = {**os.environ, 'HOME': str(self.home)}
        self.bin = self.home / '.local/bin'
        self.bin.mkdir(parents=True)
        self.workspace = self.home / 'workspace/homelab'
        self.workspace.mkdir(parents=True)
        for tool, version in [('ai-memory', '3.4.5'), ('ai-jail', '3.3.1')]:
            target = self.home / f'.local/lib/ai-tools/releases/{tool}-{version}/{tool}'
            target.parent.mkdir(parents=True)
            self.executable(target, '''#!/usr/bin/env python3
import json, os, sys
print(json.dumps({'cwd': os.getcwd(), 'argv': sys.argv[1:]}))
sys.exit(int(os.environ.get('PROBE_EXIT', '0')))
''')
            self.executable(self.bin / tool, (SOURCE / ('executable_' + tool)).read_text())
        self.executable(self.bin / 'agent-guard', '#!/bin/bash\nexec "$@"\n')
        for name in ['codex', 'codex-code-mode-host', 'codex-exec-server']:
            self.executable(self.bin / name, '#!/bin/bash\nexit 0\n')

    def executable(self, path, body):
        path.write_text(body)
        path.chmod(0o755)

    def run_tool(self, tool, *args, cwd=None):
        return subprocess.run([str(self.bin / tool), *args], cwd=cwd or self.home,
                              env=self.env, capture_output=True, text=True)

    def test_home_jail_preserves_native_arguments_and_changes_only_child_cwd(self):
        args = ['run', 'codex', '--yolo', '--jail', 'a space', '$(literal)']
        r = self.run_tool('ai-memory', *args)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), {'cwd': str(self.workspace), 'argv': args})
        self.assertIn('home não é montada inteira', r.stderr)

    def test_project_jail_keeps_project_identity(self):
        project = self.home / 'epub'
        project.mkdir()
        r = self.run_tool('ai-memory', 'run', 'codex', '--jail', cwd=project)
        self.assertEqual(json.loads(r.stdout)['cwd'], str(project))

    def test_no_jail_and_native_separator_keep_home(self):
        for args in [('run', 'codex', '--jail', '--no-jail'),
                     ('run', 'codex', '--', '--jail'), ('status',)]:
            with self.subTest(args=args):
                r = self.run_tool('ai-memory', *args)
                self.assertEqual(json.loads(r.stdout)['cwd'], str(self.home))

    def test_missing_home_workspace_fails_closed(self):
        self.workspace.rmdir()
        r = self.run_tool('ai-memory', 'run', 'codex', '--jail')
        self.assertEqual(r.returncode, 72)
        self.assertEqual(r.stdout, '')

    def test_codex_maps_are_read_only_and_arguments_are_preserved(self):
        r = self.run_tool('ai-jail', '--harness', 'codex', '--', '/bin/true')
        argv = json.loads(r.stdout)['argv']
        expected = []
        for name in ['codex', 'codex-code-mode-host', 'codex-exec-server']:
            expected += ['--map', str(self.bin / name)]
        self.assertEqual(argv, expected + ['--harness', 'codex', '--', '/bin/true'])

    def test_missing_native_codex_fails_without_starting_jail(self):
        (self.bin / 'codex').unlink()
        r = self.run_tool('ai-jail', '--harness', 'codex', '--', '/bin/true')
        self.assertEqual(r.returncode, 127)
        self.assertEqual(r.stdout, '')

    def test_native_arguments_cannot_impersonate_a_harness(self):
        r = self.run_tool('ai-jail', '--', '/bin/echo', '--harness', 'codex')
        self.assertEqual(json.loads(r.stdout)['argv'], ['--', '/bin/echo', '--harness', 'codex'])

    def test_failure_and_cancellation_exit_codes_are_preserved(self):
        for tool, args in [('ai-memory', ['run', 'codex', '--jail']),
                           ('ai-jail', ['--harness', 'codex', '--', '/bin/true'])]:
            for code in [7, 130]:
                with self.subTest(tool=tool, code=code):
                    self.env['PROBE_EXIT'] = str(code)
                    r = self.run_tool(tool, *args)
                    self.assertEqual(r.returncode, code, r.stderr)


if __name__ == '__main__':
    unittest.main()
