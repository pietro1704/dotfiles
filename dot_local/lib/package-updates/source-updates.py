#!/usr/bin/env python3
"""Final, explicitly opted-in source queue. Each application fails independently."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def execute(args, capture=False):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE if capture else None)
    if result.returncode in (-2, 130):
        raise KeyboardInterrupt
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, args)
    return result.stdout


def compile_queue(queue, dry_run=False):
    failed = []
    for name, command in queue:
        print(f"Compilation queue (se ainda pendente após binários): {name}", flush=True)
        if dry_run:
            continue
        try:
            if shutil.disk_usage(Path.home()).free < 8 * 1024**3:
                raise RuntimeError("storage preflight: need 8 GiB free")
            execute(command)
        except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
            failed.append(name)
            print(f"Compilation failed: {name}: {error}; continuing with next app", flush=True)
    return failed


def release_pins(names, dry_run=False):
    failed = []
    for name in names:
        print(f"{'Planejado liberar pin' if dry_run else 'Liberando pin'}: {name}", flush=True)
        if dry_run:
            continue
        try:
            execute(["brew", "unpin", name])
        except (OSError, subprocess.CalledProcessError) as error:
            failed.append(name)
            print(f"Failed to release pin: {name}: {error}; continuing", flush=True)
    return failed


def main(dry_run=False):
    base = Path(__file__).resolve().parent
    os.environ.update(HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_INSTALL_CLEANUP="1",
                      HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK="1", HOMEBREW_MAKE_JOBS="2")
    queue, failed, pinned = [], [], []
    try:
        names = json.loads(execute(["brew", "ruby", str(base / "homebrew-source-plan.rb")], capture=True))
        for item in names:
            name = item["name"]
            if item["pinned"]:
                pinned.append(name)
            if not re.fullmatch(r"[A-Za-z0-9_@.+/-]+", name):
                raise RuntimeError("Invalid Brew formula name")
            queue.append((f"brew:{name}", ["brew", "upgrade", "--formula", name]))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.CalledProcessError) as error:
        failed.append("Brew source inventory")
        print(f"Source inventory failed: {error}; continuing", flush=True)
    if shutil.which("port"):
        try:
            outdated = execute(["port", "-q", "outdated"], capture=True)
            for line in outdated.splitlines():
                columns = line.split()
                if columns and re.fullmatch(r"[A-Za-z0-9_.+-]+", columns[0]) and "<" in columns:
                    name = columns[0]
                    queue.append((f"port:{name}", ["sudo", "port", "-N", "upgrade", name, "buildmakejobs=2"]))
        except (OSError, subprocess.CalledProcessError) as error:
            failed.append("MacPorts source inventory")
            print(f"Source inventory failed: {error}; continuing", flush=True)
    # ai-jail is also independent from failures of either package manager.
    ai = ["python3", str(base / "ai-tools-brew.py"), "--allow-compile", "--source-only"]
    if dry_run:
        ai.append("--dry-run")
    queue.append(("ai-jail stable Intel fallback", ai))
    # Release the whole dependency queue before builds, avoiding failures caused by pinned dependencies.
    pin_failures = release_pins(pinned, dry_run)
    failed.extend("pin:" + name for name in pin_failures)
    queue = [(name, command) for name, command in queue if name.removeprefix("brew:") not in pin_failures]
    failed.extend(compile_queue(queue, dry_run))
    if failed:
        print("Failed compilations: " + ", ".join(failed), flush=True)
        return 1
    print("Compilation queue completed" if not dry_run else "Dry run: no compilations executed")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-compile", action="store_true", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        raise SystemExit(main(args.dry_run))
    except KeyboardInterrupt:
        raise SystemExit(130)
