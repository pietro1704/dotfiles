import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

HELPER = Path(__file__).resolve().parents[1] / "dot_local/lib/package-updates/codex-updates.zsh"


class CodexRuntime(unittest.TestCase):
    def run_update(self, mode="", repairable=True):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            prefix = home / "node"
            manifest = prefix / "lib/node_modules/@openai/codex/package.json"
            manifest.parent.mkdir(parents=True)
            manifest.touch()
            shims = home / "shims"
            shims.mkdir()
            fake_mise = shims / "mise"
            fake_mise.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""
                import os, sys
                from pathlib import Path
                args = sys.argv[1:]
                home = Path(os.environ['HOME'])
                with (home / "calls").open("a") as stream:
                    print(" ".join(args), file=stream)
                if args[:1] == ["-C"]:
                    args = args[2:]
                if args[:2] == ["exec", "--"] and args[2:4] == ["npm", "view"]:
                    print("0.171.0")
                elif args[:2] == ["ls", "--installed"]:
                    print('[{"installed": true}]')
                elif args[:2] == ["where", "node"]:
                    print(home / "node")
                elif args[:2] == ["where", "npm:@openai/codex"]:
                    print(home / "0.171.0")
                elif args[:2] == ["cache", "clear"]:
                    pass
                elif args[:2] == ["install", "--force"]:
                    (home / "mise-ok").touch()
                elif args[:2] == ["exec", "npm:@openai/codex@0.171.0"]:
                    if not (home / "mise-ok").exists(): sys.exit(1)
                    print("codex-cli 0.171.0")
                elif args[:4] == ["exec", "--", "npm", "install"]:
                    if os.environ["REPAIRABLE"] != "1": sys.exit(22)
                    (home / "npm-ok").touch()
                elif args[:2] == ["exec", "--"] and args[-1:] == ["--version"]:
                    if not (home / "npm-ok").exists(): sys.exit(1)
                    print("codex-cli 0.171.0")
                else:
                    sys.exit(98)
            """))
            fake_mise.chmod(0o755)
            if mode == "--verify":
                (home / "mise-ok").touch()
            env = dict(os.environ, HOME=tmp, PATH=f"{shims}:/usr/bin:/bin",
                       REPAIRABLE=str(int(repairable)))
            result = subprocess.run(
                ["/bin/zsh", "-fc", 'source "$1"; updateAllCodex "$2"', "test", str(HELPER), mode],
                text=True, capture_output=True, env=env, timeout=20)
            return result, (home / "calls").read_text()

    def test_repairs_both_the_mise_package_and_npm_copy_then_checks_selected_command(self):
        result, calls = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("install --force --minimum-release-age 0 npm:@openai/codex@0.171.0", calls)
        self.assertIn("npm install --global --ignore-scripts --include=optional", calls)
        self.assertTrue(calls.rstrip().endswith("exec -- codex --version"))

    def test_verification_propagates_broken_npm_copy_without_installing(self):
        result, calls = self.run_update("--verify")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(" install ", calls)
        self.assertIn("Codex npm inválido", result.stderr)

    def test_a_failed_repair_cannot_report_success(self):
        result, _ = self.run_update(repairable=False)
        self.assertEqual(result.returncode, 22)
        self.assertNotIn("verificado", result.stdout)
