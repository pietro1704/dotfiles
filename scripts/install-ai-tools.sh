#!/usr/bin/env bash
# Linux user installation; does not restart services or overwrite agent state.
set -euo pipefail
[[ $(uname -sm) == 'Linux x86_64' ]] || { echo 'Linux x86_64 required' >&2; exit 64; }
[[ -x $HOME/.local/bin/mise ]] || { echo 'Install and configure mise first' >&2; exit 66; }
"$HOME/.local/bin/mise" which codex >/dev/null
[[ -x $HOME/.local/bin/agent-guard ]] || { echo 'Install the Arch agent-guard first' >&2; exit 66; }
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
root="$HOME/.local/lib/ai-tools"
mkdir -p "$root/downloads" "$root/releases" "$HOME/.local/bin" "$HOME/.local/state"
backup=$(mktemp -d "$HOME/.local/state/ai-tools-install.XXXXXXXX")
chmod 700 "$backup"
for name in ai-memory ai-jail codex codex-native-path codex-code-mode-host codex-exec-server; do
    if [[ -e $HOME/.local/bin/$name || -L $HOME/.local/bin/$name ]]; then
        cp -a -- "$HOME/.local/bin/$name" "$backup/"
    fi
done
for spec in ai-memory:3.4.5 ai-jail:3.3.1; do
    name=${spec%%:*}; version=${spec#*:}
    asset="$name-linux-x86_64.tar.gz"
    url="https://github.com/akitaonrails/$name/releases/download/v$version/$asset"
    curl -fsSL "$url" -o "$root/downloads/$asset"
    curl -fsSL "$url.sha256" -o "$root/downloads/$asset.sha256"
    (cd "$root/downloads" && sha256sum -c "$asset.sha256")
    target="$root/releases/$name-$version"
    mkdir -p "$target"
    tar -xzf "$root/downloads/$asset" -C "$target"
    "$target/$name" --version
    install -m755 "$repo/dot_local/bin/executable_$name" "$HOME/.local/bin/$name.new"
    mv -f -- "$HOME/.local/bin/$name.new" "$HOME/.local/bin/$name"
done
for name in codex codex-native-path codex-code-mode-host codex-exec-server; do
    install -m755 "$repo/dot_local/bin/executable_$name" "$HOME/.local/bin/$name.new"
    mv -f -- "$HOME/.local/bin/$name.new" "$HOME/.local/bin/$name"
done
"$HOME/.local/bin/codex-native-path" >/dev/null
mkdir -p "$HOME/workspace/homelab"
marker="$HOME/workspace/homelab/.ai-memory.toml"
if [[ ! -e $marker ]]; then printf 'workspace = "default"\nproject = "pips"\n' > "$marker"; fi
printf 'Installed. Rollback copies: %s\n' "$backup"
