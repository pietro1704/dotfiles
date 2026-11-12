#!/usr/bin/env python3
"""Prefer verified MacPorts archives for independent CLI apps before compiling."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

# Limit automatic cross-manager migration to CLI applications with shared user config conventions.
COMMANDS = {name: name for name in (
    "bat", "btop", "chafa", "eza", "fastfetch", "fd", "fzf", "gh", "git-delta",
    "lazygit", "neovim", "ripgrep", "shellcheck", "shfmt", "starship", "tree-sitter")}
COMMANDS.update({"git-delta": "delta", "neovim": "nvim", "ripgrep": "rg"})


def run(args):
    result = subprocess.run(args, check=True, text=True, capture_output=True)
    return result.stdout.strip()


def binary_available(url):
    for suffix in ("", ".rmd160"):
        result = run(["curl", "--silent", "--show-error", "--head", "--max-time", "15",
                      "--proto", "=https", "--output", "/dev/null", "--write-out", "%{http_code}", url + suffix])
        if result != "200":
            return False
    return True


def migrate(name, command, port, expected, prefix):
    # Recheck users before and after installing: never break another Brew formula.
    if run(["brew", "uses", "--installed", "--include-build", "--include-test", name]):
        raise RuntimeError("Homebrew dependents appeared; migration refused")
    run(["sudo", "port", "-N", "-b", "install", port])
    target = Path("/opt/local/bin") / command
    output = run([str(target), "--version"])
    if not re.search(r"(?<![0-9.])" + re.escape(expected) + r"(?![0-9.])", output):
        raise RuntimeError("MacPorts command version did not match; original Brew package preserved")
    if run(["brew", "uses", "--installed", "--include-build", "--include-test", name]):
        raise RuntimeError("Homebrew dependents appeared; original package preserved")
    state = Path.home() / ".local/state"
    state.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="macports-migration-", dir=state))
    shutil.copytree(prefix.resolve(), backup/name, symlinks=True)
    run(["brew", "uninstall", "--formula", name])
    # Keep absolute command paths working, without leaving an obsolete Brew registration.
    old_command = prefix.parents[1] / "bin" / command
    if not old_command.exists() and not old_command.is_symlink():
        old_command.symlink_to(target)
    print(f"Migrado {name}: binário MacPorts {expected}; recuperação: {backup}", flush=True)


def main(dry_run=False):
    if not shutil.which("port"):
        return 0
    failed = False
    data = json.loads(run(["brew", "outdated", "--json=v2"]))
    for item in data["formulae"]:
        name = item["name"]
        command = COMMANDS.get(name)
        if not command:
            continue
        try:
            if run(["brew", "uses", "--installed", "--include-build", "--include-test", name]):
                print(f"MacPorts {name}: mantido no Brew por dependências", flush=True)
                continue
            prefix = Path(run(["brew", "--prefix", name]))
            executable = shutil.which(command)
            if not executable or not Path(executable).resolve().is_relative_to(prefix.resolve()):
                print(f"MacPorts {name}: preservada instalação ativa fora deste pacote Brew", flush=True)
                continue
            probe = Path(__file__).with_name("macports-binary-probe.tcl")
            raw = run(["/opt/local/libexec/macports/bin/tclsh8.6", str(probe), name])
            columns = raw.splitlines()[-1].split("\t")
            if len(columns) != 3:
                continue
            port, version, archive = columns
            if version != item["current_version"].split("_")[0]:
                continue
            if not re.fullmatch(r"[A-Za-z0-9_.+-]+", archive):
                raise RuntimeError("Invalid archive name")
            url = f"https://packages.macports.org/{port}/{archive}"
            if not binary_available(url):
                continue
            print(f"{'Planejado' if dry_run else 'Preferindo'}: {name} → binário oficial MacPorts {version} (arquivo e assinatura disponíveis)", flush=True)
            if not dry_run:
                migrate(name, command, port, version, prefix)
        except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
            if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
                raise KeyboardInterrupt from error
            failed = True
            print(f"Alternativa MacPorts falhou para {name}: {error}; seguindo", flush=True)
    return int(failed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        raise SystemExit(main(args.dry_run))
    except KeyboardInterrupt:
        raise SystemExit(130)
