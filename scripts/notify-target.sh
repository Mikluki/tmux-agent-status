#!/usr/bin/env bash

# Desktop notification when an agent finishes.
#
# The flag is the pane option @agent-notify, so like a pin it dies with the
# pane and a recycled pane id never inherits it.
#
#   --toggle <session:pane>   n in the switcher's agents view: turn
#                             notifications on or off for the agent's pane.
#   --send <pane> <state>     The collector's callback when a pane goes from
#                             working to done or ask. Notifies only when the
#                             pane has the flag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"

NOTIFY_OPTION="@agent-notify"

toggle_notify() {
    local sel_name="$1"
    local pane_id="${sel_name##*:}"

    [[ "$pane_id" == %* ]] || return 0

    if [ -n "$(tmux show-option -pqv -t "$pane_id" "$NOTIFY_OPTION" 2>/dev/null)" ]; then
        tmux set-option -pu -t "$pane_id" "$NOTIFY_OPTION" 2>/dev/null || true
    else
        tmux set-option -pq -t "$pane_id" "$NOTIFY_OPTION" on 2>/dev/null || true
    fi
}

# One line, no body: the Claude session's /rename name, or the tmux session
# name for a session never renamed or another agent, then what happened:
# "0037.run — done", or "— asking" for an agent blocked on you.
send_notify() {
    local pane_id="$1"
    local state="${2:-done}"
    local info="" flag="" name="" agent_name=""

    [[ "$pane_id" == %* ]] || return 0

    # The flag is never empty, since read would collapse an empty field, and
    # comes first, so a tab inside the name cannot shift it.
    info=$(tmux display-message -p -t "$pane_id" \
        "#{?${NOTIFY_OPTION},1,0}"$'\t'"#{session_name}" 2>/dev/null) || return 0
    IFS=$'\t' read -r flag name <<< "$info"
    [ "$flag" = "1" ] || return 0

    agent_name=$(agent_name_for "$pane_id")
    [ -n "$agent_name" ] && name="$agent_name"
    [ -n "$name" ] || return 0

    case "$state" in
        ask) name+=" — asking" ;;
        *)   name+=" — done" ;;
    esac

    # Hooks and the collector may lack the desktop session's environment.
    : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR

    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a tmux-agent-status -- "$name" 2>/dev/null || true
    elif command -v osascript >/dev/null 2>&1; then
        osascript - "$name" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
    display notification "" with title (item 1 of argv)
end run
APPLESCRIPT
    fi
}

case "${1:-}" in
    --toggle)
        toggle_notify "${2:-}"
        ;;
    --send)
        send_notify "${2:-}" "${3:-}"
        ;;
esac
