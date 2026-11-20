import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('update_audit', ROOT/'dot_local/lib/package-updates/audit-updates.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class CompletionAudit(unittest.TestCase):
    def run_audit(self, formulas=None, brew_error=False, ai_version='3.3.1', newer=None):
        formulas = formulas or []
        def run(args, **kwargs):
            if args[:2] == ['brew', 'outdated']:
                if brew_error:
                    raise subprocess.CalledProcessError(1, args)
                output = json.dumps({'formulae': formulas, 'casks': []})
            elif args[:2] == ['brew', 'ruby']:
                output = json.dumps(newer or [])
            elif args[0] == 'curl':
                version = '3.3.1' if 'ai-jail' in args[-1] else '3.4.5'
                output = json.dumps({'tag_name': 'v'+version, 'assets': []})
            elif args[0] == '/fake/ai-jail':
                output = 'ai-jail '+ai_version
            elif args[0] == '/fake/ai-memory':
                output = 'ai-memory 3.4.5'
            else:
                self.fail(f'Unexpected command: {args}')
            return subprocess.CompletedProcess(args, 0, output)
        def which(name):
            return '/fake/'+name if name in ('ai-jail','ai-memory') else None
        with patch.object(audit.subprocess, 'run', side_effect=run) as runner, patch.object(audit.shutil, 'which', side_effect=which):
            result = audit.audit(dry_run=True)
            for c in runner.call_args_list:
                self.assertNotIn(c.args[0][0], ('sudo', 'port', 'rm'))
                self.assertNotIn('upgrade', c.args[0])
                self.assertNotIn('unpin', c.args[0])
            return result

    def test_up_to_date_succeeds(self):
        self.assertEqual(self.run_audit(), 0)

    def test_pinned_and_unpinned_pending_fail(self):
        for pinned in (True,False):
            item = {'name':'rust', 'installed_versions':['1.99.0'], 'current_version':'1.99.1', 'pinned':pinned}
            self.assertEqual(self.run_audit([item]), 1)

    def test_inventory_failure_cannot_report_success(self):
        self.assertEqual(self.run_audit(brew_error=True), 1)

    def test_local_tap_cannot_hide_new_ai_release(self):
        self.assertEqual(self.run_audit(ai_version='3.2.0'), 1)

    def test_newer_installed_version_is_not_a_pending_downgrade(self):
        item = {'name':'openssl@3', 'installed_versions':['3.6.5'], 'current_version':'3.5.9', 'pinned':False}
        self.assertEqual(self.run_audit([item], newer=['openssl@3']), 0)

    def test_macports_only_status_without_other_package_managers(self):
        with tempfile.TemporaryDirectory() as tmp:
            port = Path(tmp) / 'port'
            for output, port_rc, audit_rc in (('No installed ports are outdated.', 0, 0),
                                              ('aom @3.15.1_0 < 3.15.3_0', 0, 1),
                                              ('', 1, 1), ('', 130, 130)):
                with self.subTest(output=output, port_rc=port_rc):
                    port.write_text(f"#!/bin/sh\n[ \"$*\" = '-q outdated' ] || exit 2\n"
                                    f"printf '%s\\n' '{output}'\nexit {port_rc}\n")
                    port.chmod(0o755)
                    result = subprocess.run([sys.executable, audit.__file__, '--macports-only'],
                                            env=dict(os.environ, PATH=tmp), text=True,
                                            capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, audit_rc, result.stdout + result.stderr)
                    self.assertNotIn('Brew', result.stdout)
