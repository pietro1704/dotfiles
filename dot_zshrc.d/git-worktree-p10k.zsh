# Fix p10k/gitstatus showing stale git status when switching between worktrees.
# Restart daemon whenever the git working-tree context changes (worktree ↔ main,
# or between linked worktrees). Pure-shell walk-up: no git fork on every cd.

_p10k_git_ctx=""

_gitstatus_refresh_on_chpwd() {
  local ctx="" dir="$PWD"
  while [[ "$dir" != "/" && "$dir" != "." ]]; do
    if [[ -f "$dir/.git" ]]; then
      ctx="$(< "$dir/.git")"   # "gitdir: ../../.git/worktrees/foo" — unique per worktree
      break
    elif [[ -d "$dir/.git" ]]; then
      ctx="main:$dir/.git"
      break
    fi
    dir="${dir:h}"
  done

  if [[ "$ctx" != "$_p10k_git_ctx" ]]; then
    _p10k_git_ctx="$ctx"
    gitstatus_stop POWERLEVEL9K 2>/dev/null
    gitstatus_start -s -1 -u -1 -c -1 -d -1 POWERLEVEL9K 2>/dev/null
  fi
}

# chpwd: fires on directory change
chpwd_functions=("${(@)chpwd_functions:#gitstatus_refresh_on_chpwd}")
chpwd_functions=("${(@)chpwd_functions:#_gitstatus_refresh_on_chpwd}")
chpwd_functions+=(_gitstatus_refresh_on_chpwd)

# precmd: fires before every prompt — catches shell init and post-exec redraws
# Only restarts daemon when context actually changes, so overhead is minimal.
precmd_functions=("${(@)precmd_functions:#_gitstatus_refresh_on_chpwd}")
precmd_functions=(_gitstatus_refresh_on_chpwd $precmd_functions)
