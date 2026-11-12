"""Exercise updateAll without allowing it to invoke the manual Herdr updater."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ManualHerdrUpdates(unittest.TestCase):
    def test_herdr_never_runs_even_inside_herdr(self):
        sources = []
        template = ROOT / 'dot_zshrc.tmpl'
        if template.exists():
            sources.append(template)
        active = os.environ.get('UPDATE_ALL_ACTIVE_ZSHRC')
        if active:
            sources.append(Path(active))
        if not sources:
            sources.append(Path.home() / '.zshrc')
        for source in sources:
            functions = re.findall(r'^updateAll\(\) \{\n.*?^\}', source.read_text(), re.M | re.S)
            self.assertTrue(functions)
            for herdr_rc in (None, 0, 1, 130):
                for package_rc in (0, 1, 130):
                    with self.subTest(source=source, herdr=herdr_rc, packages=package_rc), tempfile.TemporaryDirectory() as tmp:
                        home = Path(tmp)
                        bindir = home / '.local/bin'
                        bindir.mkdir(parents=True)
                        for name in ('curl', 'bash', 'claude'):
                            executable = bindir / name
                            executable.write_text('#!/bin/sh\nexit 0\n')
                            executable.chmod(0o755)
                        if herdr_rc is not None:
                            executable = bindir / 'herdr'
                            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$HOME/herdr-called"\n' + f'exit {herdr_rc}\n')
                            executable.chmod(0o755)
                        script = f'updatePackagesBinaryOnly() {{ print packages-ran; return {package_rc}; }}\n'
                        script += 'updatePackagesAudit() { return 0; }\nupdateCodex() { return 0; }\n' + functions[-1] + '\nupdateAll\n'
                        result = subprocess.run(['/bin/zsh', '-f', '-c', script],
                            env={'HOME': tmp, 'PATH': str(bindir), 'ZSH': str(home/'absent'), 'HERDR_ENV': 'nested-test'},
                            capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, int(bool(package_rc)), result.stdout+result.stderr)
                        self.assertIn('packages-ran', result.stdout)
                        self.assertFalse((home/'herdr-called').exists(), 'updateAll invoked Herdr')
                        self.assertNotIn('Atualizando Herdr', result.stdout)


if __name__ == '__main__':
    unittest.main()
