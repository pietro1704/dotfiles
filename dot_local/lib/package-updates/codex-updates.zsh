# Only update Codex installations already managed by standalone, npm or mise.
_ua_codex_contexts() {
  [[ -d "$HOME/Developer" ]] || return 0
  command find "$HOME/Developer" -maxdepth 4 -name mise.toml -not -path '*/node_modules/*' \
    -exec command grep -lE '^"npm:@openai/codex" = "latest"' {} + 2>/dev/null |
    command sed 's#/mise.toml$##' | command sort
}

_ua_codex_version() {
  local expected=$1 actual rc
  shift
  actual=$("$@")
  rc=$?
  (( rc )) && return "$rc"
  [[ $actual == "codex-cli $expected" ]] && return 0
  print -u2 -- "Codex: esperado $expected, recebido $actual ($*)"
  return 1
}

updateAllCodex() {
  local -x MISE_AUTO_INSTALL=0 MISE_EXEC_AUTO_INSTALL=0 MISE_NOT_FOUND_AUTO_INSTALL=0
  local mode=${1:-} standalone="$HOME/.local/bin/codex" latest context prefix rc resolved
  local -a contexts=("$HOME" ${(f)"$(_ua_codex_contexts)"})
  local -A checked_prefixes
  if [[ ! -x "$standalone" ]] && ! command -v mise >/dev/null 2>&1; then return 0; fi

  # A running npm/pnpm Codex may pass these flags to the standalone updater.
  latest=$(command mise -C "${contexts[2]:-$HOME}" exec -- npm view @openai/codex@latest version) || return $?
  if [[ ! $latest =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 -- "Versão estável inválida do Codex: $latest"
    return 1
  fi
  if [[ -x "$standalone" ]]; then
    _ua_codex_version "$latest" env -u CODEX_MANAGED_BY_NPM -u CODEX_MANAGED_BY_PNPM "$standalone" --version
    rc=$?
    (( rc == 130 )) && return 130
    if (( rc )); then
      [[ $mode == --verify ]] && return 1
      env -u CODEX_MANAGED_BY_NPM -u CODEX_MANAGED_BY_PNPM "$standalone" update || return $?
      _ua_codex_version "$latest" env -u CODEX_MANAGED_BY_NPM -u CODEX_MANAGED_BY_PNPM "$standalone" --version || return $?
    fi
  fi

  resolved=$(command mise -C "$HOME" ls --installed --json npm:@openai/codex) || return $?
  if [[ $resolved != *'"installed": true'* ]]; then
    [[ ${#contexts} -gt 1 ]] || return 0
  fi
  local tool="npm:@openai/codex@$latest"
  _ua_codex_version "$latest" command mise -C "$HOME" exec "$tool" -- codex --version 2>/dev/null
  rc=$?
  (( rc == 130 )) && return 130
  if (( rc )); then
    [[ $mode == --verify ]] && return 1
    command mise cache clear npm:@openai/codex || return $?
    command mise -C "$HOME" install --force --minimum-release-age 0 "$tool" || return $?
    _ua_codex_version "$latest" command mise -C "$HOME" exec "$tool" -- codex --version || return $?
  fi

  for context in "${contexts[@]}"; do
    prefix=$(command mise -C "$context" where node) || return $?
    if [[ -z ${checked_prefixes[$prefix]} && -f "$prefix/lib/node_modules/@openai/codex/package.json" ]]; then
      checked_prefixes[$prefix]=1
      _ua_codex_version "$latest" command mise -C "$context" exec -- "$prefix/bin/codex" --version 2>/dev/null
      rc=$?
      (( rc == 130 )) && return 130
      if (( rc )); then
        [[ $mode == --verify ]] && { print -u2 -- "Codex npm inválido em $prefix"; return 1; }
        command mise -C "$context" exec -- npm install --global --ignore-scripts --include=optional --prefer-online \
          --prefix "$prefix" "@openai/codex@$latest" || return $?
        _ua_codex_version "$latest" command mise -C "$context" exec -- "$prefix/bin/codex" --version || return $?
      fi
    fi
    if [[ $mode != --verify ]]; then
      resolved=$(command mise -C "$context" where npm:@openai/codex 2>/dev/null)
      rc=$?
      (( rc == 130 )) && return 130
      if (( rc )) || [[ ${resolved:t} != "$latest" ]]; then
        if [[ $context == "$HOME" ]]; then
          command mise -C "$context" use --global --fuzzy --minimum-release-age 0 npm:@openai/codex@latest || return $?
        else
          command mise -C "$context" use --fuzzy --minimum-release-age 0 npm:@openai/codex@latest || return $?
        fi
      fi
    fi
    _ua_codex_version "$latest" command mise -C "$context" exec -- codex --version || return $?
  done
  print -- "✓ Codex $latest verificado (standalone, npm e contextos mise disponíveis)"
}
