#!/usr/bin/env bash

[[ -n "${_STATUS_SUMMARY_LOADED:-}" ]] && return 0
_STATUS_SUMMARY_LOADED=1

_STATUS_SUMMARY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pins.sh
source "$_STATUS_SUMMARY_LIB_DIR/pins.sh"

# The status bar is a watchlist, not a census: it shows the agents you pinned,
# each as its tag, coloured by state. Nothing on the bar varies with time —
# no durations and no animation — so a glance costs nothing when nothing has
# changed. Age lives in the picker instead.
#
#     bug  rfc✓  perf   ·6
#
# The trailing "·N" counts the agents you did not pin, and turns green when
# one of them is done or asking. It is the insurance against an opt-in
# watchlist quietly losing a finished agent.

# Per-state tmux style prefix.
agent_status_style() {
    case "$1" in
        working) echo "#[fg=yellow,bold]" ;;
        ask)     echo "#[fg=magenta,bold]" ;;
        wait)    echo "#[fg=cyan,dim]" ;;
        dead)    echo "#[fg=colour244]" ;;
        *)       echo "#[fg=green]" ;;
    esac
}

# Per-state mark appended to the tag. Working and waiting agents stay bare so
# the two states that need you stand out without reading colour.
agent_status_mark() {
    case "$1" in
        ask)  echo "?" ;;
        done) echo "✓" ;;
        *)    echo "" ;;
    esac
}

# render_status_summary [pane_id<TAB>state ...]
# One tag per pinned agent, in pin order, plus the unpinned overflow count.
render_status_summary() {
    local resolved=()
    mapfile -t resolved < <(printf '%s\n' "$@" | pins_render_specs)

    local overflow=0 alert=0
    IFS=':' read -r overflow alert <<< "${resolved[0]:-0:0}"

    # Two spaces between tags; a wider gap before the overflow count so the
    # watchlist and the counter read as two separate things.
    local out="" spec tag state
    local i=1
    while (( i < ${#resolved[@]} )); do
        spec="${resolved[$i]}"
        i=$((i + 1))
        [ -n "$spec" ] || continue
        tag="${spec%:*}"
        state="${spec##*:}"
        [ -n "$out" ] && out+="  "
        out+="$(agent_status_style "$state")${tag}$(agent_status_mark "$state")#[default]"
    done

    if (( overflow > 0 )); then
        local overflow_style="#[fg=colour244]"
        (( alert )) && overflow_style="#[fg=green]"
        [ -n "$out" ] && out+="   "
        out+="${overflow_style}·${overflow}#[default]"
    fi

    printf '%s\n' "$out"
}

# write_status_summary_cache <working> <waiting> <done> <total> [pane_id<TAB>state ...]
# The counts feed the counts file (used for done-notification diffing); the
# agents feed the rendered cache. The cache is a single pre-rendered line —
# nothing on the bar depends on the clock, so there is nothing to pick between.
write_status_summary_cache() {
    local working="$1"
    local waiting="$2"
    local done="$3"
    local total_agents="$4"
    shift 4

    printf '%s\n' "$working:$waiting:$done:$total_agents" > "${STATUS_LINE_COUNTS_FILE}.tmp"
    mv -f "${STATUS_LINE_COUNTS_FILE}.tmp" "$STATUS_LINE_COUNTS_FILE"
    render_status_summary "$@" > "${STATUS_LINE_CACHE_FILE}.tmp"
    mv -f "${STATUS_LINE_CACHE_FILE}.tmp" "$STATUS_LINE_CACHE_FILE"
}
