# Fix p10k/gitstatus showing stale git status when switching between worktrees.
# All worktrees share the same .git dir, so gitstatusd gets confused.
# This restarts the daemon whenever we cd into a worktree (detected by .git being a file).

gitstatus_refresh_on_chpwd() {
  [[ -f .git && -r .git ]] || return 0
  gitstatus_stop POWERLEVEL9K 2>/dev/null
  gitstatus_start -s -1 -u -1 -c -1 -d -1 POWERLEVEL9K 2>/dev/null
}
chpwd_functions+=(gitstatus_refresh_on_chpwd)
