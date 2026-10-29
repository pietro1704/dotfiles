#!/usr/bin/env python3
"""Run the actual updateAll function with isolated, fake update commands."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'dot_zshrc.tmpl'


class UpdateAllMole(unittest.TestCase):
    def run_case(self, source, curl_rc=0, installer_rc=0, packages_rc=0):
        functions = re.findall(r'^updateAll\(\) \{\n.*?^\}', source, re.M | re.S)
        self.assertTrue(functions, 'updateAll not found')
        with tempfile.TemporaryDirectory(prefix='updateall-mole-test-') as home:
            script = r'''
export HOME="$TEST_HOME" ZSH="$TEST_HOME/no-zsh"
set +o pipefail
updatePackagesBinaryOnly() { return "$PACKAGES_RC"; }
updateCodex() { return 0; }
brew() { return "$PACKAGES_RC"; }
port() { return 0; }
sudo() { return 0; }
claude() { return 0; }
mole() { print -u2 'Legacy mole update called'; return 99; }
mo() { print -u2 'Legacy mo update called'; return 99; }
curl() {
  [[ "$*" == '-fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh' ]] || return 98
  print '# MOLE_DOWNLOAD_REQUESTED'
  print -r -- 'printf "%s\n" MOLE_INSTALLER_RAN'
  print -r -- "exit $INSTALLER_RC"
  return "$CURL_RC"
}
'''
            script += functions[-1] + r'''
updateAll
rc=$?
[[ -o pipefail ]] && { print -u2 'pipefail leaked'; exit 97; }
exit "$rc"
'''
            env = dict(os.environ, TEST_HOME=home, CURL_RC=str(curl_rc),
                       INSTALLER_RC=str(installer_rc), PACKAGES_RC=str(packages_rc))
            return subprocess.run(['/bin/zsh', '-f'], input=script, text=True,
                                  capture_output=True, env=env, timeout=10)

    def test_installer_and_failures(self):
        sources = [('chezmoi', SOURCE.read_text())]
        active = os.environ.get('UPDATE_ALL_ACTIVE_ZSHRC')
        if active:
            sources.append(('active', Path(active).read_text()))
        for label, source in sources:
            for curl_rc, installer_rc, packages_rc in [(0, 0, 0), (22, 0, 0),
                    (28, 0, 0), (130, 0, 0), (0, 1, 0), (0, 130, 0), (0, 0, 1)]:
                with self.subTest(source=label, curl=curl_rc, installer=installer_rc,
                                  packages=packages_rc):
                    result = self.run_case(source, curl_rc, installer_rc, packages_rc)
                    self.assertEqual(result.returncode, int(bool(curl_rc or installer_rc or packages_rc)),
                                     result.stdout + result.stderr)
                    self.assertIn('MOLE_INSTALLER_RAN', result.stdout)
                    self.assertNotIn('Legacy', result.stderr)
                    self.assertEqual('✓ updateAll concluído' in result.stdout,
                                     not bool(curl_rc or installer_rc or packages_rc))


if __name__ == '__main__':
    unittest.main()
