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
CLEAR_SCREEN = '\x1b[H\x1b[J'


class CompileConsent(unittest.TestCase):
    def run_update(self, args='', reply=None, source_rc=0, binary_rc=0, audit_rc=0,
                   metadata_failed=0, term='xterm-256color', runtime_rc=0, preview_rc=0,
                   macports_only_failed=0, macports_audit_rc=0, late_brew_rc=0):
        function = re.findall(r'^updateAll\(\) \{\n.*?^\}', (ROOT/'dot_zshrc.tmpl').read_text(), re.M|re.S)[-1]
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp)/'bin'
            bindir.mkdir()
            for name in ('curl', 'bash', 'claude'):
                path = bindir/name
                drain = '/bin/cat >/dev/null\n' if name == 'bash' else ''
                path.write_text('#!/bin/sh\n'+drain+'echo ordinary-'+name+'\nexit 0\n')
                path.chmod(0o755)
            (bindir/'tput').symlink_to('/usr/bin/tput')
            script = f'''
source "{ROOT / 'dot_local/lib/package-updates/binary-updates.zsh'}"
updatePackagesPreview() {{ print PREVIEW; return {preview_rc}; }}
updateRubyFromSource() {{ return 0; }}
updatePackagesAudit() {{
    print audit-$*
    [[ $1 != --macports-only ]] || return {macports_audit_rc}
    return {audit_rc}
}}
updatePackagesBinaryOnly() {{
    print binary-$*
    UPDATE_PACKAGES_METADATA_FAILED={metadata_failed}
    UPDATE_PACKAGES_MACPORTS_ONLY_FAILED={macports_only_failed}
    return {binary_rc}
}}
updatePackagesBrewSourcePlan() {{ print '[{{"name":"llvm","pinned":false}}]'; }}
updatePackagesFromSource() {{
    print SOURCE-$*
    [[ $1 != --late-brew ]] || return {late_brew_rc}
    return {source_rc}
}}
updateAllCodex() {{ print Codex-$*; }}
updatePackagesRuntime() {{
    if [[ $1 == snapshot ]]; then print snapshot-token; return 0; fi
    read -r baseline
    [[ $baseline == snapshot-token ]] || return 99
    print RUNTIME
    return {runtime_rc}
}}
''' + function + f'\nupdateAll {args}\n'
            env = dict(os.environ, HOME=tmp, PATH=str(bindir), ZSH=tmp+'/absent', TERM=term)
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
        self.assertNotIn(CLEAR_SCREEN, output)
        self.assertLess(output.index('PREVIEW'), output.index('binary-'))

    def test_clears_terminal_once_before_prompt(self):
        rc, output = self.run_update(reply='\n')
        self.assertEqual(rc, 0, output)
        self.assertEqual(output.count(CLEAR_SCREEN), 1, output)
        self.assertLess(output.index(CLEAR_SCREEN), output.index('[s/N]'))
        self.assertLess(output.index('PREVIEW'), output.index('[s/N]'))
        self.assertNotIn('\x1b[3J', output)

    def test_runs_when_terminal_cannot_be_cleared(self):
        for term in ('dumb', 'invalid-test-terminal'):
            with self.subTest(term=term):
                rc, output = self.run_update(reply='\n', term=term)
                self.assertEqual(rc, 0, output)
                self.assertNotIn(CLEAR_SCREEN, output)

    def test_terminal_default_no_and_explicit_yes(self):
        for reply, enabled in [('\n', False), ('n\n', False), ('s\n', True), ('sim\n', True)]:
            rc, output = self.run_update(reply=reply)
            self.assertEqual(rc, 0, output)
            self.assertIn('[s/N]', output)
            self.assertEqual('SOURCE' in output, enabled, output)

    def test_flag_compiles_last_even_when_binary_failed(self):
        for binary_rc in (0, 1):
            rc, output = self.run_update('--allow-compile', binary_rc=binary_rc)
            self.assertEqual(rc, 0, output)
            self.assertNotIn('[s/N]', output)
            self.assertNotIn('PREVIEW', output)
            self.assertGreater(output.index('SOURCE'), output.index('ordinary-claude'))
            self.assertGreater(output.index('RUNTIME'), output.index('SOURCE'))
            if binary_rc:
                self.assertIn('Falha binária recuperada', output)

    def test_binary_failure_without_compile_remains_failure(self):
        rc, output = self.run_update(binary_rc=1)
        self.assertEqual(rc, 1, output)

    def test_failed_metadata_sync_cannot_be_cleared_by_final_inventory(self):
        rc, output = self.run_update('--allow-compile', binary_rc=1, metadata_failed=1)
        self.assertEqual(rc, 1, output)
        self.assertNotIn('Falha binária recuperada', output)

    def test_macports_recovery_is_reported_even_with_unrelated_audit_pending(self):
        rc, output = self.run_update('--allow-compile', binary_rc=1, audit_rc=1,
                                     macports_only_failed=1)
        self.assertEqual(rc, 1, output)
        self.assertIn('audit---macports-only', output)
        self.assertIn('Falha binária do MacPorts recuperada', output)

    def test_macports_only_recheck_failure_and_cancellation(self):
        for macports_audit_rc in (1, 130):
            with self.subTest(macports_audit_rc=macports_audit_rc):
                rc, output = self.run_update('--allow-compile', binary_rc=1, audit_rc=1,
                                             macports_only_failed=1, macports_audit_rc=macports_audit_rc)
                self.assertEqual(rc, macports_audit_rc, output)
                self.assertIn('audit---macports-only', output)
                self.assertNotIn('Falha binária do MacPorts recuperada', output)

    def test_unrelated_source_failure_is_retained_after_macports_recovers(self):
        rc, output = self.run_update('--allow-compile', binary_rc=1, source_rc=1, audit_rc=1,
                                     macports_only_failed=1)
        self.assertEqual(rc, 1, output)
        self.assertIn('Falha binária do MacPorts recuperada', output)

    def test_unconfirmed_binary_or_stale_metadata_skips_macports_only_recheck(self):
        for macports_only_failed, metadata_failed in ((0, 0), (1, 1)):
            with self.subTest(macports_only_failed=macports_only_failed, metadata_failed=metadata_failed):
                rc, output = self.run_update('--allow-compile', binary_rc=1, audit_rc=1,
                                             macports_only_failed=macports_only_failed, metadata_failed=metadata_failed)
                self.assertEqual(rc, 1, output)
                self.assertNotIn('audit---macports-only', output)
                self.assertNotIn('Falha binária do MacPorts recuperada', output)

    def test_failed_source_sets_final_status_and_cancel_is_preserved(self):
        for source_rc in (1, 130):
            rc, output = self.run_update('--allow-compile', source_rc=source_rc)
            self.assertEqual(rc, source_rc, output)

    def test_new_brew_plan_is_applied_at_most_once_before_validation(self):
        for late_rc in (0, 1, 130):
            with self.subTest(late_rc=late_rc):
                rc, output = self.run_update('--allow-compile', late_brew_rc=late_rc)
                self.assertEqual(rc, late_rc, output)
                self.assertEqual(output.count('SOURCE---late-brew '), 1, output)
                self.assertIn('SOURCE---planned-brew [{"name":"llvm","pinned":false}]', output)
                if late_rc == 130:
                    self.assertNotIn('Codex---verify', output)
                else:
                    self.assertLess(output.index('SOURCE---late-brew'), output.index('RUNTIME'))

    def test_unknown_flag_does_not_run_updates(self):
        rc, output = self.run_update('--bad')
        self.assertEqual(rc, 2, output)
        self.assertNotIn('binary', output)

    def test_bad_executable_prevents_success_even_if_inventory_is_current(self):
        for runtime_rc in (1, 130):
            rc, output = self.run_update('--allow-compile', runtime_rc=runtime_rc)
            self.assertEqual(rc, runtime_rc, output)
            self.assertNotIn('✓ updateAll concluído', output)

    def test_canceled_preview_does_not_start_updates(self):
        rc, output = self.run_update(preview_rc=130)
        self.assertEqual(rc, 130, output)
        self.assertNotIn('binary-', output)

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
            self.assertNotIn('RUNTIME', output)
            self.assertNotIn('Codex-', output)
            self.assertNotIn('[s/N]', output)
            self.assertEqual('SOURCE---dry-run' in output, '--allow-compile' in args)
            self.assertNotIn('✓ updateAll concluído', output)
