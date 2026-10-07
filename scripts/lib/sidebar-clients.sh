#!/usr/bin/env bash

[[ -n "${_SIDEBAR_CLIENTS_LOADED:-}" ]] && return 0
_SIDEBAR_CLIENTS_LOADED=1

SIDEBAR_TITLE="${SIDEBAR_TITLE:-agent-sidebar}"

# The collector's wake signal (see wake_collector). Sidebar clients take
# USR1/USR2 on their own pids; the collector traps this one on its pid.
COLLECTOR_WAKE_SIGNAL=USR1

register_sidebar_client() {
    local pane_id="${1:-}"
    [ -n "$pane_id" ] || pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
    [ -n "$pane_id" ] || return 1

    mkdir -p "$SIDEBAR_CLIENT_DIR"
    printf '%s\n' "$$" > "$SIDEBAR_CLIENT_DIR/${pane_id}.pid"
    printf '%s\n' "$pane_id"
}

unregister_sidebar_client() {
    local pane_id="$1"
    [ -n "$pane_id" ] || return 0
    rm -f "$SIDEBAR_CLIENT_DIR/${pane_id}.pid"
}

# Ask the collector daemon for an immediate rebuild. Touching REFRESH_FILE
# alone waits for the collector's next poll, and the mtime it compares has
# one-second resolution, so a second change within the same second is missed;
# the signal makes it collect now and ignore the mtimes. Without a running
# collector the touch is all there is, for whoever collects next.
wake_collector() {
    local pid=""

    touch "$REFRESH_FILE" 2>/dev/null || true

    pid=$(cat "$COLLECTOR_PID_FILE" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0

    # A pid file left by a killed collector may name a recycled pid; never
    # signal anything but the collector.
    case "$(ps -p "$pid" -o args= 2>/dev/null || true)" in
        *sidebar-collector.sh*)
            kill -s "$COLLECTOR_WAKE_SIGNAL" "$pid" 2>/dev/null || true
            ;;
    esac
    return 0
}

signal_sidebar_clients() {
    local signal_name="$1"
    local scope="${2:-all}"
    local pane_file pane_id pid
    local -A pane_titles=()
    local -A pane_active=()

    for pane_file in "$SIDEBAR_CLIENT_DIR/"*.pid; do
        [ -f "$pane_file" ] || return 0
        break
    done

    while IFS=$'\t' read -r pane_id pane_title pane_is_active; do
        [ -n "$pane_id" ] || continue
        pane_titles[$pane_id]="$pane_title"
        pane_active[$pane_id]="${pane_is_active:-0}"
    done < <(tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_title}'$'\t''#{pane_active}' 2>/dev/null)

    for pane_file in "$SIDEBAR_CLIENT_DIR/"*.pid; do
        [ -f "$pane_file" ] || continue

        pane_id="$(basename "$pane_file" .pid)"
        pid="$(cat "$pane_file" 2>/dev/null || echo "")"

        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pane_file"
            continue
        fi

        if [ "${pane_titles[$pane_id]:-}" != "$SIDEBAR_TITLE" ]; then
            rm -f "$pane_file"
            continue
        fi

        if [ "$scope" = "active" ] && [ "${pane_active[$pane_id]:-0}" != "1" ]; then
            continue
        fi

        kill -s "$signal_name" "$pid" 2>/dev/null || rm -f "$pane_file"
    done
}
