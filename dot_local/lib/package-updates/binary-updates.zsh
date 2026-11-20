# Shared Codex updater and verification of the executable selected in each context.
source "${${(%):-%x}:A:h}/codex-updates.zsh"

updatePackagesRuntime() {
  command python3 "$HOME/.local/lib/package-updates/runtime-updates.py" "$@"
}

updateMiseBinaryOnly() {
  local -x MISE_ALL_COMPILE=0 MISE_NODE_COMPILE=0 MISE_PYTHON_COMPILE=0 MISE_RUBY_COMPILE=0
  local -a exclusions=(--exclude npm:@openai/codex)
  [[ $(command uname -m) != x86_64 ]] || exclusions+=(--exclude ruby)
  command mise -C "$HOME" upgrade --yes "${exclusions[@]}" "$@"
}

updateRubyFromSource() {
  local cfg="$HOME/.config/mise/config.toml" cur latest tool actual free
  [[ -r $cfg ]] && command -v mise >/dev/null 2>&1 || return 0
  [[ $(command uname -m) == x86_64 ]] || return 0
  cur=$(command sed -nE 's/^ruby = "([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$cfg") || return $?
  [[ -n $cur ]] || return 0
  latest=$(MISE_RUBY_COMPILE=1 command mise -C "$HOME" ls-remote ruby "${cur%.*}") || return $?
  latest=$(print -r -- "$latest" | command grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | command tail -1)
  if [[ -z $latest ]]; then
    print -u2 -- "Ruby: não foi possível listar versões da série ${cur%.*}"
    return 1
  fi
  [[ $latest != "$cur" ]] || return 0
  if [[ ${1:-} == --dry-run ]]; then
    print -- "  mise Ruby $cur → $latest (compilação no Mac Intel)"
    return 0
  fi
  free=$(command df -k "$HOME" | command awk 'NR==2 {print $4}')
  if (( free < 8 * 1024 * 1024 )); then
    print -u2 'Ruby: a compilação exige pelo menos 8 GiB livres'
    return 1
  fi
  tool="ruby@$latest"
  print -- "→ Compilando $tool via mise..."
  MISE_RUBY_COMPILE=1 command mise -C "$HOME" install "$tool" || return $?
  actual=$(MISE_AUTO_INSTALL=0 MISE_EXEC_AUTO_INSTALL=0 MISE_NOT_FOUND_AUTO_INSTALL=0 \
    command mise -C "$HOME" exec "$tool" -- ruby -e 'puts RUBY_VERSION') || return $?
  if [[ $actual != "$latest" ]]; then
    print -u2 -- "Ruby: esperado $latest, recebido $actual; configuração preservada"
    return 1
  fi
  command sed -i '' -E "s/^ruby = \"${cur//./[.]}\"/ruby = \"$latest\"/" "$cfg" || return $?
  print -- "✓ Ruby $latest compilado e verificado"
}
# Final read-only inventory. Pending packages make updateAll incomplete.
updatePackagesAudit() {
  command python3 "$HOME/.local/lib/package-updates/audit-updates.py" "$@"
}

# Called only as the last updateAll phase after explicit consent.
updatePackagesFromSource() {
  command python3 "$HOME/.local/lib/package-updates/source-updates.py" --allow-compile "$@"
}

_update_brew_binary_exclusions() {
  print 'edencommon,fb303,fbthrift,fizz,folly,mvfst,wangle,llvm,llvm@22,watchman,xcodes,mise,herdr,ai-memory,ai-jail'
}

updatePackagesPreview() {
  local -x HOMEBREW_BINARY_UPDATE_SKIP_FORMULAE="$(_update_brew_binary_exclusions)"
  command python3 "$HOME/.local/lib/package-updates/source-updates.py" --preview
}

# Stable AI archives; source builds require explicit opt-in.
updateAiToolsBrew() {
  command python3 "$HOME/.local/lib/package-updates/ai-tools-brew.py" "$@"
}

# Shared by updateAll and ~/.updateBrew.sh. No shell startup side effects.
updateBrewBinaryOnly() {
  local failed=0 mode=apply rc
  local helper="$HOME/.local/lib/package-updates/homebrew-binary-upgrade.rb"
  local -x HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  local -x HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_ENV_HINTS=1
  local -x HOMEBREW_NO_INSTALL_UPGRADE=1
  local -x HOMEBREW_BINARY_UPDATE_SKIP_FORMULAE="$(_update_brew_binary_exclusions)"
  if [[ ${1:-} == --dry-run && $# == 1 ]]; then
    mode=dry-run
  elif (( $# )); then
    print -u2 'Usage: updateBrewBinaryOnly [--dry-run]'
    return 2
  fi
  if [[ ! -r "$helper" ]]; then
    print -u2 "Binary-only Homebrew updater missing: $helper"
    return 1
  fi
  if [[ $mode == apply ]]; then
    command brew update || {
      rc=$?
      UPDATE_PACKAGES_METADATA_FAILED=1
      return "$rc"
    }
  fi
  # Prefer MacPorts binary alternatives for independent CLI apps before Brew source fallback.
  command python3 "$HOME/.local/lib/package-updates/macports-binary-fallback.py" "$@"
  rc=$?
  (( rc == 130 )) && return "$rc"
  (( rc )) && failed=1
  print '→ Homebrew: compatible bottles and casks only; source builds disabled'
  HOMEBREW_BINARY_UPDATE_MODE="$mode" command brew ruby "$helper"
  rc=$?
  (( rc == 130 )) && return "$rc"
  (( rc )) && failed=1
  HOMEBREW_BINARY_UPDATE_MODE="cask-$mode" command brew ruby "$helper"
  rc=$?
  (( rc == 130 )) && return "$rc"
  (( rc )) && failed=1
  # Stable AI archives are not Brew bottles. Only ai-jail has an Intel source exception.
  updateAiToolsBrew "$@"
  rc=$?
  (( rc == 130 )) && return "$rc"
  (( rc )) && failed=1
  if [[ $mode == apply && $failed == 0 ]]; then
    command brew cleanup --prune=30 || failed=1
  fi
  return "$failed"
}

updatePackagesBinaryOnly() {
  local failed=0 mode=apply rc macports_log_dir macports_log
  UPDATE_PACKAGES_METADATA_FAILED=0
  if [[ ${1:-} == --dry-run && $# == 1 ]]; then
    mode=dry-run
  elif (( $# )); then
    print -u2 'Usage: updatePackagesBinaryOnly [--dry-run]'
    return 2
  fi
  print '→ MacPorts: binary archives only; source builds disabled'
  # selfupdate can compile MacPorts; update its base only with an official .pkg.
  if [[ $mode == dry-run ]]; then
    command port -N -b -y upgrade outdated
    rc=$?
  else
    macports_log_dir="$HOME/.local/state/updateAll"
    if ! command mkdir -p "$macports_log_dir"; then
      print -u2 "✗ Não foi possível criar diretório de logs do updateAll: $macports_log_dir"
      failed=1
    else
      macports_log="$macports_log_dir/macports-$(command date '+%Y%m%d-%H%M%S').log"
      print "· Log MacPorts: $macports_log"
    fi
    if (( failed == 0 )); then
      (set -o pipefail; command sudo port -N sync 2>&1 | command tee -a "$macports_log")
      rc=$?
    else
      rc=1
    fi
    (( rc == 130 )) && return "$rc"
    if (( rc )); then
      print -u2 "✗ MacPorts sync falhou (código $rc); saída: ${macports_log:-indisponível}"
      UPDATE_PACKAGES_METADATA_FAILED=1
      failed=1
    fi
    if (( rc == 0 )); then
      (set -o pipefail; command sudo port -N -b upgrade outdated 2>&1 | command tee -a "$macports_log")
      rc=$?
      (( rc == 130 )) && return "$rc"
      if (( rc )); then
        print -u2 "✗ MacPorts upgrade binário falhou (código $rc); saída: $macports_log"
        failed=1
      fi
    fi
  fi
  (( rc == 130 )) && return "$rc"
  (( rc )) && failed=1
  updateBrewBinaryOnly "$@"
  rc=$?
  (( rc == 130 )) && return "$rc"
  (( rc )) && failed=1
  return "$failed"
}
