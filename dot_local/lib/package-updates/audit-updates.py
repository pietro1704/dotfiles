#!/usr/bin/env python3
"""Read-only final inventory; pending updates or failed checks mean incomplete."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def read(args):
    result = subprocess.run(args, check=True, text=True, capture_output=True)
    return result.stdout


def audit(dry_run=False):
    pending = 0
    errors = []
    try:
        data = json.loads(read(["brew", "outdated", "--json=v2"]))
        formulas = data["formulae"]
        pinned = [item for item in formulas if item.get("pinned")]
        print(f"Brew: {len(formulas)} fórmulas pendentes, {len(pinned)} com pin; {len(data['casks'])} casks pendentes", flush=True)
        for item in formulas:
            installed = ", ".join(item["installed_versions"])
            reason = "pin; exige permitir compilações" if item.get("pinned") else "atualização não aplicada"
            print(f"  {item['name']}: {installed} → {item['current_version']} ({reason})", flush=True)
        for item in data["casks"]:
            print(f"  cask:{item['name']}: atualização pendente", flush=True)
        pending += len(formulas) + len(data["casks"])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
            raise KeyboardInterrupt from error
        errors.append("Brew")
        print(f"Não foi possível conferir Brew: {error}", flush=True)
    if shutil.which("port"):
        try:
            lines = read(["port", "-q", "outdated"]).splitlines()
            outdated = [line for line in lines if "<" in line.split()]
            pending += len(outdated)
            print(f"MacPorts: {len(outdated)} pacotes pendentes", flush=True)
            for line in outdated:
                print("  " + line, flush=True)
        except (OSError, subprocess.CalledProcessError) as error:
            if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
                raise KeyboardInterrupt from error
            errors.append("MacPorts")
            print(f"Não foi possível conferir MacPorts: {error}", flush=True)
    # The generated local formula has no remote, so Brew cannot discover new AI releases alone.
    try:
        import importlib.util
        path = Path(__file__).with_name("ai-tools-brew.py")
        spec = importlib.util.spec_from_file_location("ai_tools", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for tool in ("ai-jail", "ai-memory"):
            version, _ = module.latest(tool)
            executable = shutil.which(tool)
            if not executable:
                pending += 1
                print(f"{tool}: executável ausente; estável {version}", flush=True)
                continue
            output = read([executable, "--version"]).strip()
            if output != f"{tool} {version}":
                pending += 1
                print(f"{tool}: {output}; estável {version} pendente", flush=True)
            else:
                print(f"{tool}: {version}, estável atual confirmada", flush=True)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.returncode in (130, -2):
            raise KeyboardInterrupt from error
        errors.append("AI releases")
        print(f"Não foi possível conferir releases de AI: {error}", flush=True)
    label = "Dry run" if dry_run else "Conferência final"
    print(f"{label}: {pending} pendências; {len(errors)} verificações falharam. Catálogos locais de Brew/MacPorts; releases AI consultadas online.", flush=True)
    if pending or errors:
        print("Atualização completa NÃO confirmada", flush=True)
        return 1
    print("Brew/MacPorts e ferramentas AI conferidos sem pendências; Herdr/Hermes mantêm fluxo manual", flush=True)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        raise SystemExit(audit(args.dry_run))
    except KeyboardInterrupt:
        raise SystemExit(130)
