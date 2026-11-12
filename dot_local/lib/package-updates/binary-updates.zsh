# Final read-only inventory. Pending packages make updateAll incomplete.
updatePackagesAudit() {
  command python3 "$HOME/.local/lib/package-updates/audit-updates.py" "$@"
}

# Called only as the last updateAll phase after explicit consent.
updatePackagesFromSource() {
  command python3 "$HOME/.local/lib/package-updates/source-updates.py" --allow-compile "$@"
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
  local skip_formulae=(edencommon fb303 fbthrift fizz folly mvfst wangle llvm llvm@22 watchman xcodes mise herdr ai-memory ai-jail)
  local -x HOMEBREW_BINARY_UPDATE_SKIP_FORMULAE="${(j:,:)skip_formulae}"
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
    command brew update || return $?
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
  local failed=0 mode=apply rc
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
    command sudo port -N sync
    rc=$?
    if (( rc == 0 )); then
      command sudo port -N -b upgrade outdated
      rc=$?
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
