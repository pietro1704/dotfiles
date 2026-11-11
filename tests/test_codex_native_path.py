"""Resolve the selected installation, including optional npm platform packages."""
import os
from pathlib import Path
import runpy
import tempfile
import unittest

RESOLVE = runpy.run_path(str(Path(__file__).resolve().parents[1] /
    'dot_local/bin/executable_codex-native-path'))['resolve_native']


class NativeSelection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.installs = self.home / '.local/share/mise/installs'
        (self.home / '.local/bin').mkdir(parents=True)
        self.installs.mkdir(parents=True)

    def executable(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755)
        return path

    def select(self, path):
        self.executable(self.home / '.local/bin/mise',
                        f'#!/bin/sh\nprintf "%s\\n" "{path}"\n'.encode())

    def test_native_global_and_npm_project_select_distinct_versions(self):
        native = self.executable(self.installs / 'codex/0.166.0/bin/codex', b'\x7fELFfixture')
        self.select(native)
        self.assertEqual(RESOLVE(self.home), native.parent)
        npm = self.installs / 'npm-openai-codex/0.167.0'
        shim = self.executable(npm / 'node_modules/.bin/codex', b'#!/bin/sh\nexit 1\n')
        platform = self.executable(npm / 'node_modules/.mise/platform/vendor/linux/bin/codex', b'\x7fELFfixture')
        self.select(shim)
        self.assertEqual(RESOLVE(self.home), platform.parent)

    def test_missing_platform_package_refuses_instead_of_using_global_version(self):
        self.executable(self.installs / 'codex/0.166.0/bin/codex', b'\x7fELFfixture')
        shim = self.executable(self.installs / 'npm-openai-codex/0.167.0/node_modules/.bin/codex', b'#!/bin/sh\n')
        self.select(shim)
        with self.assertRaises(ValueError):
            RESOLVE(self.home)

    def test_external_native_path_is_refused(self):
        external = self.executable(self.home / 'external/codex', b'\x7fELFfixture')
        self.select(external)
        with self.assertRaises(ValueError):
            RESOLVE(self.home)

    def test_platform_symlink_cannot_escape_installation(self):
        root = self.installs / 'npm-openai-codex/0.167.0'
        shim = self.executable(root / 'node_modules/.bin/codex', b'#!/bin/sh\n')
        outside = self.executable(self.home / 'external/codex', b'\x7fELFfixture')
        vendor = root / 'vendor/linux/bin/codex'
        vendor.parent.mkdir(parents=True)
        vendor.symlink_to(outside)
        self.select(shim)
        with self.assertRaises(ValueError):
            RESOLVE(self.home)
