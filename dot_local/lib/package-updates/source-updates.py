#!/usr/bin/env python3
"""Final, explicitly opted-in source queue. Each application fails independently."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import runpy
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


def outdated_ports():
    if not shutil.which("port"):
        return []
    lines = execute(["port", "-q", "outdated"], capture=True).splitlines()
    return [line.split()[0] for line in lines
            if "<" in line.split() and re.fullmatch(r"[A-Za-z0-9_.+-]+", line.split()[0])]


def preview_ports(base):
    names = outdated_ports()
    if not names:
        return
    probe = base / "macports-binary-probe.tcl"
    rows = execute(["/opt/local/libexec/macports/bin/tclsh8.6", str(probe), *names], capture=True)
    archives = {}
    for row in rows.splitlines():
        cols = row.split("\t")
        if len(cols) == 3 and cols[0] in names and re.fullmatch(r"[A-Za-z0-9_.+-]+", cols[2]):
            archives[cols[0]] = cols[1:]
    available = runpy.run_path(str(base / "macports-binary-fallback.py"))["binary_available"]

    def check(name):
        if name not in archives:
            return f"  MacPorts {name} (arquivo binário não identificado)"
        version, archive = archives[name]
        if not available(f"https://packages.macports.org/{name}/{archive}"):
            return f"  MacPorts {name} → {version} (arquivo oficial ou assinatura indisponível)"
        return None

    with ThreadPoolExecutor(max_workers=4) as pool:
        for message in pool.map(check, names):
            if message:
                print(message, flush=True)


def preview():
    base = Path(__file__).resolve().parent
    print("→ Atualizações que podem exigir compilação (catálogos locais)", flush=True)
    print("  Para permitir compilações e liberação de pins: updateAll --allow-compile", flush=True)
    failed = False
    try:
        os.environ.update(HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_BINARY_UPDATE_MODE="source-preview")
        execute(["brew", "ruby", str(base / "homebrew-binary-upgrade.rb")])
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"  Brew: não foi possível conferir a fila: {error}", flush=True)
        failed = True
    try:
        preview_ports(base)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
            raise KeyboardInterrupt from error
        print(f"  MacPorts: não foi possível conferir os arquivos: {error}", flush=True)
        failed = True
    try:
        latest = runpy.run_path(str(base / "ai-tools-brew.py"))["latest"]
        version, assets = latest("ai-jail")
        current = shutil.which("ai-jail")
        if "ai-jail-macos-x86_64.tar.gz" not in assets and os.uname().machine == "x86_64":
            if not current or execute([current, "--version"], capture=True).strip() != f"ai-jail {version}":
                print(f"  ai-jail → {version} (sem arquivo oficial para Mac Intel)", flush=True)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
            raise KeyboardInterrupt from error
        print(f"  ai-jail: não foi possível conferir a atualização: {error}", flush=True)
        failed = True
    return int(failed)


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
    try:
        for name in outdated_ports():
            queue.append((f"port:{name}", ["sudo", "port", "-N", "-s", "upgrade", name, "buildmakejobs=2"]))
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
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--allow-compile", action="store_true")
    mode.add_argument("--preview", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        raise SystemExit(preview() if args.preview else main(args.dry_run))
    except KeyboardInterrupt:
        raise SystemExit(130)
