#!/usr/bin/env zsh
source "$HOME/.local/lib/package-updates/binary-updates.zsh" || exit $?
updateBrewBinaryOnly "$@"
