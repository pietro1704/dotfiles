import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CompileConsent(unittest.TestCase):
    def run_update(self, args='', reply=None, source_rc=0, binary_rc=0, audit_rc=0):
        function = re.findall(r'^updateAll\(\) \{\n.*?^\}', (ROOT/'dot_zshrc.tmpl').read_text(), re.M|re.S)[-1]
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp)/'bin'
            bindir.mkdir()
            for name in ('curl', 'bash', 'claude'):
                path = bindir/name
                drain = '/bin/cat >/dev/null\n' if name == 'bash' else ''
                path.write_text('#!/bin/sh\n'+drain+'echo ordinary-'+name+'\nexit 0\n')
                path.chmod(0o755)
            script = f'updatePackagesAudit() {{ print audit-$*; return {audit_rc}; }}\nupdatePackagesBinaryOnly() {{ print binary-$*; return {binary_rc}; }}\nupdatePackagesFromSource() {{ print SOURCE-$*; return {source_rc}; }}\n' + function + f'\nupdateAll {args}\n'
            env = dict(os.environ, HOME=tmp, PATH=str(bindir), ZSH=tmp+'/absent')
            if reply is None:
                result = subprocess.run(['/bin/zsh', '-f', '-c', script], env=env, text=True, capture_output=True, timeout=10)
                return result.returncode, result.stdout+result.stderr
            master, slave = pty.openpty()
            process = subprocess.Popen(['/bin/zsh', '-f', '-c', script], env=env, stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            output = b''
            sent = False
            deadline = time.monotonic()+10
            try:
                while time.monotonic()<deadline:
                    if select.select([master], [], [], .1)[0]:
                        try:
                            chunk = os.read(master, 4096)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output += chunk
                        if b'[s/N]' in output and not sent:
                            self.assertNotIn(b'binary', output)
                            os.write(master, reply.encode())
                            sent = True
                    if process.poll() is not None:
                        break
                return process.wait(timeout=3), output.decode()
            finally:
                os.close(master)
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_noninteractive_defaults_no(self):
        rc, output = self.run_update()
        self.assertEqual(rc, 0, output)
        self.assertNotIn('SOURCE', output)
        self.assertNotIn('[s/N]', output)

    def test_terminal_default_no_and_explicit_yes(self):
        for reply, enabled in [('\n', False), ('n\n', False), ('s\n', True), ('sim\n', True)]:
            rc, output = self.run_update(reply=reply)
            self.assertEqual(rc, 0, output)
            self.assertIn('[s/N]', output)
            self.assertEqual('SOURCE' in output, enabled, output)

    def test_flag_compiles_last_even_when_binary_failed(self):
        for binary_rc in (0, 1):
            rc, output = self.run_update('--allow-compile', binary_rc=binary_rc)
            self.assertEqual(rc, binary_rc, output)
            self.assertNotIn('[s/N]', output)
            self.assertGreater(output.index('SOURCE'), output.index('ordinary-claude'))

    def test_failed_source_sets_final_status_and_cancel_is_preserved(self):
        for source_rc in (1, 130):
            rc, output = self.run_update('--allow-compile', source_rc=source_rc)
            self.assertEqual(rc, source_rc, output)

    def test_unknown_flag_does_not_run_updates(self):
        rc, output = self.run_update('--bad')
        self.assertEqual(rc, 2, output)
        self.assertNotIn('binary', output)

    def test_pending_final_audit_prevents_false_success(self):
        for args in ('', '--allow-compile'):
            rc, output = self.run_update(args, audit_rc=1)
            self.assertEqual(rc, 1, output)
            self.assertNotIn('✓ updateAll concluído', output)
            self.assertIn('audit-', output)

    def test_full_dry_run_never_runs_installers_and_forwards_flags(self):
        for args in ('--dry-run', '--dry-run --allow-compile', '--allow-compile --dry-run'):
            rc, output = self.run_update(args, audit_rc=1)
            self.assertEqual(rc, 1, output)
            self.assertIn('binary---dry-run', output)
            self.assertIn('audit---dry-run', output)
            self.assertNotIn('ordinary-', output)
            self.assertNotIn('[s/N]', output)
            self.assertEqual('SOURCE---dry-run' in output, '--allow-compile' in args)
            self.assertNotIn('✓ updateAll concluído', output)
