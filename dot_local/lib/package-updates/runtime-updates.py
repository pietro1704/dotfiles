#!/usr/bin/env python3
"""Exercise changed packages and the main updaters without launching GUI apps."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

MISE_COMMANDS = {
    "go": ("go", "version"),
    "neovim": ("nvim", "--version"),
    "python": ("python3", "--version"),
    "ripgrep": ("rg", "--version"),
    "rust": ("rustc", "--version"),
    "tlrc": ("tldr", "--version"),
    "zig": ("zig", "version"),
    "npm:@openai/codex": ("codex", "--version"),
}
UPDATERS = {"brew": "--version", "port": "version", "mise": "--version", "mo": "--version",
            "claude": "--version", "rustc": "--version", "tmux": "-V", "gh": "--version",
            "nvim": "--version"}


def run(args, timeout=90):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if result.returncode in (-2, 130):
        raise KeyboardInterrupt
    if result.returncode:
        details = (result.stderr or result.stdout).strip().splitlines()
        raise RuntimeError(f"{' '.join(args)} (código {result.returncode})" +
                           (f": {details[-1]}" if details else ""))
    return result.stdout


def inventory():
    brew = json.loads(run(["brew", "info", "--json=v2", "--installed"]))
    ports = run(["port", "-q", "installed", "active"]).splitlines() if shutil.which("port") else []
    mise = {}
    if shutil.which("mise"):
        mise = json.loads(run(["mise", "-C", str(Path.home()), "ls", "--installed", "--json"]))
    mas = run(["mas", "list"]).splitlines() if shutil.which("mas") else []
    return {
        "brew": {item["full_name"]: sorted(row["version"] for row in item["installed"])
                 for item in brew["formulae"]},
        "casks": {item["token"]: {"version": item["installed"], "artifacts": item["artifacts"]}
                  for item in brew["casks"]},
        "ports": sorted(ports),
        "mise": mise,
        "mas": sorted(mas),
        "updaters": {name: shutil.which(name) for name in UPDATERS},
    }


def app_bundle(path):
    with (path / "Contents/Info.plist").open("rb") as stream:
        executable = plistlib.load(stream)["CFBundleExecutable"]
    if not os.access(path / "Contents/MacOS" / executable, os.X_OK):
        raise RuntimeError(f"executável ausente no aplicativo {path}")


def cask_targets(item):
    for artifact in item["artifacts"]:
        target = artifact.get("target")
        if not target:
            continue
        path = Path(target).expanduser()
        if "app" in artifact and path.suffix == ".app":
            app_bundle(path)
        elif not path.exists() or ("binary" in artifact and not os.access(path, os.X_OK)):
            raise RuntimeError(f"destino inválido: {path}")


def mise_tool(home, name, row):
    tool = f"{name}@{row['version']}"
    command, flag = MISE_COMMANDS.get(name, (name.rsplit("/", 1)[-1], "--version"))
    if name.endswith("/dua-cli"):
        command = "dua"
    prefix = Path(row["install_path"]).resolve()
    base = ["mise", "-C", home]
    executable = Path(run([*base, "which", "--tool", tool, command]).strip())
    if not executable.resolve().is_relative_to(prefix):
        raise RuntimeError(f"{command} aponta para {executable}; esperado em {prefix}")
    run([*base, "exec", tool, "--", str(executable), flag])


def verify(before, after):
    failures = []

    def check(label, action):
        try:
            action()
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
            print(f"✗ {label}: {error}", flush=True)
            failures.append(label)
        else:
            print(f"✓ {label}", flush=True)

    formulas = [name for name, versions in after["brew"].items()
                if set(versions) - set(before["brew"].get(name, []))]
    if formulas:
        check("Brew: bibliotecas das fórmulas atualizadas",
              lambda: run(["brew", "linkage", "--test", *formulas], timeout=300))
    for name in formulas:
        check(f"Brew: teste de {name}", lambda: run(["brew", "test", name], timeout=300))
    for name, item in after["casks"].items():
        if item["version"] != before["casks"].get(name, {}).get("version"):
            check(f"Brew cask: {name}", lambda: cask_targets(item))
    if after["ports"] != before["ports"]:
        # MacPorts checks linkage during upgrades. The report-only audit repeats
        # the check after cleanup and may neither repair nor compile any port.
        def port_linkage():
            output = run(["sudo", "-n", "port", "-N", "-y", "rev-upgrade"], timeout=300)
            if not all(marker in output for marker in ("No broken files found.", "No broken ports found.")):
                raise RuntimeError(output.strip())
        check("MacPorts: integridade das bibliotecas", port_linkage)
    if after["mas"] != before["mas"]:
        installed = {line.split()[0] for line in before["mas"] if line.split()}
        for line in set(after["mas"]) - set(before["mas"]):
            app_id = line.split()[0]
            if app_id not in installed:
                continue
            def check_store_app():
                paths = run(["mdfind", f"kMDItemAppStoreAdamID == {int(app_id)}"]).splitlines()
                if not paths:
                    raise RuntimeError(f"aplicativo {app_id} ausente no Spotlight")
                app_bundle(Path(paths[0]))
            check(f"App Store: {app_id}", check_store_app)

    home = str(Path.home())
    for name, rows in after["mise"].items():
        old = {row["version"] for row in before["mise"].get(name, [])}
        for row in rows:
            version = row["version"]
            if version in old:
                continue
            check(f"mise: {name}@{version}", lambda: mise_tool(home, name, row))

    for name, flag in UPDATERS.items():
        path = after["updaters"].get(name)
        if path:
            check(name, lambda: run([path, flag]))
        elif before["updaters"].get(name) or name == "mo":
            print(f"✗ {name}: executável ausente após atualização", flush=True)
            failures.append(name)
    return int(bool(failures))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("snapshot", "verify"))
    args = parser.parse_args()
    os.environ.update(HOMEBREW_NO_AUTO_UPDATE="1", MISE_AUTO_INSTALL="0",
                      MISE_EXEC_AUTO_INSTALL="0", MISE_NOT_FOUND_AUTO_INSTALL="0")
    try:
        if args.mode == "snapshot":
            print(json.dumps(inventory()))
        else:
            raise SystemExit(verify(json.load(sys.stdin), inventory()))
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"Verificação de ferramentas: {error}\n")
