import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "runtime_updates", ROOT / "dot_local/lib/package-updates/runtime-updates.py")
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class RuntimeUpdates(unittest.TestCase):
    def inventory(self, version):
        return {
            "brew": {"gh": [version], "zlib": ["1.0"]},
            "ports": [],
            "casks": {},
            "mise": {"gh": [{"version": version, "install_path": f"/mise/gh/{version}"}]},
            "mas": [],
            "updaters": {"mo": "/mole"},
        }

    def test_runs_the_updated_keg_and_exact_mise_executable(self):
        def run(args, **kwargs):
            if args[3:5] == ["which", "--tool"]:
                return "/mise/gh/2.0/bin/gh\n"
            return ""

        with patch.object(runtime, "run", side_effect=run) as runner:
            self.assertEqual(runtime.verify(self.inventory("1.0"), self.inventory("2.0")), 0)
        commands = [call.args[0] for call in runner.call_args_list]
        self.assertIn(["brew", "linkage", "--test", "gh"], commands)
        self.assertIn(["brew", "test", "gh"], commands)
        self.assertTrue(any(command[-2:] == ["/mise/gh/2.0/bin/gh", "--version"] for command in commands))
        self.assertFalse(any("zlib" in command for command in commands))

    def test_healthy_executable_from_another_installation_does_not_mask_failure(self):
        def run(args, **kwargs):
            if args[3:5] == ["which", "--tool"]:
                return "/usr/local/bin/gh\n"
            return ""

        with patch.object(runtime, "run", side_effect=run) as runner:
            self.assertEqual(runtime.verify(self.inventory("1.0"), self.inventory("2.0")), 1)
        self.assertFalse(any("/usr/local/bin/gh" in call.args[0] for call in runner.call_args_list))

    def test_macports_clean_report_is_successful(self):
        before, after = self.inventory("1.0"), self.inventory("1.0")
        after["ports"] = ["aom @3.15.3_0 (active)"]
        for report, status in (
            ("No broken files found.\nNo broken ports found.", 0),
            ("Found 1 broken file, matching files to ports\nFound 1 broken port:", 1),
        ):
            with self.subTest(report=report), patch.object(
                runtime, "run", side_effect=lambda args, **kw: report if args[0] == "sudo" else ""
            ) as runner:
                self.assertEqual(runtime.verify(before, after), status)
                self.assertEqual(runner.call_args_list[0].args[0],
                                 ["sudo", "-n", "port", "-N", "-y", "rev-upgrade"])
