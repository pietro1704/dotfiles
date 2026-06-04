#!/bin/sh
# Switch tmux status between 1 line and 2 lines.
# 1 line when the collapsed window list + right widgets probably fit;
# 2 lines when the right widgets would crowd/clip the windows.

width=${TMUX_STATUS_WIDTH:-$(tmux display-message -p '#{client_width}' 2>/dev/null)}
[ -n "$width" ] || width=$(tmux list-clients -F '#{client_width}' 2>/dev/null | sort -nr | head -n1)
[ -n "$width" ] || exit 0

session=$(tmux display-message -p '#S' 2>/dev/null)
current=$(tmux display-message -p '#W' 2>/dev/null)
windows=$(tmux list-windows -F '#I' 2>/dev/null | wc -l | tr -d ' ')

# Approximate rendered widths after Catppuccin styling:
# session pill + inactive numbered pills + current numbered title + right widgets.
session_w=$(( ${#session} + 8 ))
windows_w=$(( windows * 5 + ${#current} + 8 ))
right_w=105
needed=$(( session_w + windows_w + right_w + 4 ))

if [ "$needed" -le "$width" ]; then
  tmux set -gq status on
  tmux set -gq status-format[0] '#{E:@tmux_status_format_oneline}'
else
  tmux set -gq status 2
  tmux set -gq status-format[0] '#{E:@tmux_status_format_windows}'
fi
