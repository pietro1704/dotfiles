#!/usr/bin/env python3
"""Update stable AI tools with Brew; only ai-jail may build from source on Intel Macs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import uuid

TAP = "pietro1704/ai-tools-local"


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def fetch(url):
    return run("curl", "--fail", "--silent", "--show-error", "--location",
               "--proto", "=https", "--proto-redir", "=https", "--max-time", "180", url, capture=True)


def latest(tool):
    release = json.loads(fetch(f"https://api.github.com/repos/akitaonrails/{tool}/releases/latest"))
    tag = release["tag_name"]
    if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise RuntimeError(f"Refusing non-stable release: {tag!r}")
    return tag[1:], {asset["name"] for asset in release["assets"]}


def formula(version, url, digest, source):
    build = ('    ENV["RUSTC"] = HOMEBREW_PREFIX/"opt/rust/bin/rustc"\n'
             '    system HOMEBREW_PREFIX/"opt/rust/bin/cargo", "build", "--release", "--locked", "--jobs", "2"\n'
             '    bin.install "target/release/ai-jail"') if source else '    bin.install "ai-jail"'
    # Host Rust is preflighted; declaring a dependency would upgrade pinned toolchains.
    dependency = ""
    return f'''class AiJail < Formula
  desc "Sandbox wrapper for AI coding agents (stable release, Intel source fallback)"
  homepage "https://github.com/akitaonrails/ai-jail"
  url "{url}"
  version "{version}"
  sha256 "{digest}"
  license "GPL-3.0-only"
{dependency}
  def install
{build}
  end

  test do
    assert_match version.to_s, shell_output("#{{bin}}/ai-jail --version")
  end
end
'''


def migrate(tool, prefix, home):
    target = prefix / "opt" / tool / "bin" / tool
    # Validate before replacing anything, including a broken or customized executable.
    run(str(target), "--version")
    link = home / ".local/bin" / tool
    if link.is_symlink() and link.readlink() == target:
        return
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.exists() or link.is_symlink():
        backup = Path(tempfile.mkdtemp(prefix="ai-tools-migration-", dir=state_dir(home)))
        shutil.copy2(link, backup / tool, follow_symlinks=False)
        print(f"Rollback executable: {backup / tool}", flush=True)
    temporary = link.with_name(link.name + ".brew-" + uuid.uuid4().hex)
    try:
        temporary.symlink_to(target)
        os.replace(temporary, link)
    finally:
        temporary.unlink(missing_ok=True)


def state_dir(home):
    state = home / ".local/state"
    state.mkdir(parents=True, exist_ok=True)
    return state


def update_jail(prefix, home, version, assets, source, allow_compile):
    arch = "x86_64" if platform.machine() == "x86_64" else "aarch64"
    asset = f"ai-jail-macos-{arch}.tar.gz"
    tapdir = prefix / "Homebrew/Library/Taps/pietro1704/homebrew-ai-tools-local"
    path = tapdir / "Formula/ai-jail.rb"
    info = json.loads(run("brew", "info", "--json=v2", "--installed", capture=True))
    installed = {item["name"]: item for item in info["formulae"]}
    current = installed.get("ai-jail", {})
    current_versions = {item["version"] for item in current.get("installed", [])}
    if version not in current_versions or current.get("tap") != TAP:
        if source and not allow_compile:
            print("ai-jail compilation deferred; use updateAll --allow-compile", flush=True)
            return
        if not tapdir.exists():
            run("brew", "tap-new", "--no-git", TAP)
        if source:
            free = shutil.disk_usage(home).free
            if free < 8 * 1024**3:
                raise RuntimeError("Source build needs at least 8 GiB free; no files were deleted")
            rust = prefix / "opt/rust/bin/rustc"
            found = run(str(rust), "--version", capture=True)
            numbers = tuple(map(int, re.search(r"rustc (\d+)\.(\d+)\.(\d+)", found).groups()))
            if numbers < (1, 97, 1):
                raise RuntimeError("Install a compatible prebuilt Rust >= 1.97.1 before building")
            print(f"Storage preflight: {free // 1024**3} GiB free (minimum 8); existing Homebrew Rust", flush=True)
            url = f"https://github.com/akitaonrails/ai-jail/archive/refs/tags/v{version}.tar.gz"
            with tempfile.TemporaryDirectory(prefix="ai-jail-source-") as tmp:
                archive = Path(tmp) / "source.tar.gz"
                run("curl", "-fL", "--proto", "=https", "--proto-redir", "=https", "--max-time", "180", url, "-o", str(archive))
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        else:
            url = f"https://github.com/akitaonrails/ai-jail/releases/download/v{version}/{asset}"
            digest = fetch(url + ".sha256").split()[0]
            if not re.fullmatch(r"[a-f0-9]{64}", digest):
                raise RuntimeError("Invalid official archive checksum")
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".rb.new")
        temporary.write_text(formula(version, url, digest, source))
        os.replace(temporary, path)
        if current and current.get("tap") != TAP:
            raise RuntimeError("ai-jail already belongs to another tap; refusing to uninstall automatically")
        run("brew", "upgrade" if current else "install", f"{TAP}/ai-jail")
    else:
        print(f"ai-jail {version} already installed", flush=True)
    run("brew", "test", f"{TAP}/ai-jail")
    migrate("ai-jail", prefix, home)


def update(dry_run=False, allow_compile=False, source_only=False):
    if platform.system() != "Darwin":
        raise RuntimeError("This updater is for macOS only")
    home = Path.home()
    prefix = Path(run("brew", "--prefix", capture=True).strip())
    version, assets = latest("ai-jail")
    arch = {"x86_64": "x86_64", "arm64": "aarch64"}.get(platform.machine())
    if not arch:
        raise RuntimeError("Unsupported Mac architecture")
    source = f"ai-jail-macos-{arch}.tar.gz" not in assets
    if source and arch != "x86_64":
        raise RuntimeError("Official ARM archive missing; refusing unexpected source build")
    print(f"ai-jail {version}: {'source build (2 jobs)' if source else 'official binary'}; ai-memory: official Brew archive", flush=True)
    if dry_run:
        print(f"Dry run: compile permission={allow_compile}; no changes")
        return
    os.environ.update(HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_INSTALL_CLEANUP="1",
                      HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK="1", HOMEBREW_MAKE_JOBS="2")
    failed = []
    if not source_only:
        try:
            info = json.loads(run("brew", "info", "--json=v2", "--installed", capture=True))
            installed = {item["name"] for item in info["formulae"]}
            run("brew", "upgrade" if "ai-memory" in installed else "install", "akitaonrails/tap/ai-memory")
            run("brew", "test", "akitaonrails/tap/ai-memory")
            migrate("ai-memory", prefix, home)
        except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
            if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
                raise KeyboardInterrupt from error
            failed.append("ai-memory")
            print(f"ai-memory update failed: {error}; continuing", flush=True)
    if not source_only or source:
        try:
            update_jail(prefix, home, version, assets, source, allow_compile)
        except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
            if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
                raise KeyboardInterrupt from error
            failed.append("ai-jail")
            print(f"ai-jail update failed: {error}; continuing", flush=True)
    if failed:
        raise RuntimeError("Updates failed: " + ", ".join(failed))
    print("AI tools checked. Configurations, data, hooks and services preserved.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-compile", action="store_true")
    parser.add_argument("--source-only", action="store_true")
    args = parser.parse_args()
    if args.source_only and not args.allow_compile:
        parser.error("--source-only requires --allow-compile")
    try:
        update(args.dry_run, args.allow_compile, args.source_only)
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"AI tools update failed: {error}\n")
