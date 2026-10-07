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
# The trailing "·N" counts the agents you did not pin, and takes the ask
# colour when one of them is asking. It is the insurance against an opt-in
# watchlist quietly losing an agent that is blocked on you. Done does not
# count: it is the resting state, so with many agents something unpinned is
# always done and the counter would be lit all the time.

# Colours are themeable through @agent-status-color-{working,ask,done,wait,
# muted}. A value may be a tmux format (e.g. '#{@base0A}'), so it is expanded
# with #{E:} on every render: a theme switch recolours the bar on the next
# rebuild, and the collector forces one at least every ~10 seconds. An option
# that is unset or expands to nothing falls back to the default below.
STATUS_COLOR_DEFAULT_WORKING="yellow"
STATUS_COLOR_DEFAULT_ASK="magenta"
STATUS_COLOR_DEFAULT_DONE="green"
STATUS_COLOR_DEFAULT_WAIT="cyan"
STATUS_COLOR_DEFAULT_MUTED="default"

STATUS_COLOR_WORKING="$STATUS_COLOR_DEFAULT_WORKING"
STATUS_COLOR_ASK="$STATUS_COLOR_DEFAULT_ASK"
STATUS_COLOR_DONE="$STATUS_COLOR_DEFAULT_DONE"
STATUS_COLOR_WAIT="$STATUS_COLOR_DEFAULT_WAIT"
STATUS_COLOR_MUTED="$STATUS_COLOR_DEFAULT_MUTED"

# One tmux round-trip for all five colours.
load_status_colors() {
    local raw="" working="" ask="" done="" wait="" muted=""
    raw=$(tmux display-message -p \
        '#{E:@agent-status-color-working}|#{E:@agent-status-color-ask}|#{E:@agent-status-color-done}|#{E:@agent-status-color-wait}|#{E:@agent-status-color-muted}' \
        2>/dev/null || true)
    IFS='|' read -r working ask done wait muted <<< "$raw"

    STATUS_COLOR_WORKING="${working:-$STATUS_COLOR_DEFAULT_WORKING}"
    STATUS_COLOR_ASK="${ask:-$STATUS_COLOR_DEFAULT_ASK}"
    STATUS_COLOR_DONE="${done:-$STATUS_COLOR_DEFAULT_DONE}"
    STATUS_COLOR_WAIT="${wait:-$STATUS_COLOR_DEFAULT_WAIT}"
    STATUS_COLOR_MUTED="${muted:-$STATUS_COLOR_DEFAULT_MUTED}"
}

# Per-state tmux style prefix. Muted covers dead pins and the overflow count.
agent_status_style() {
    case "$1" in
        working) echo "#[fg=$STATUS_COLOR_WORKING,bold]" ;;
        ask)     echo "#[fg=$STATUS_COLOR_ASK,bold]" ;;
        wait)    echo "#[fg=$STATUS_COLOR_WAIT]" ;;
        dead)    echo "#[fg=$STATUS_COLOR_MUTED]" ;;
        *)       echo "#[fg=$STATUS_COLOR_DONE]" ;;
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
    load_status_colors

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
        local overflow_style="#[fg=$STATUS_COLOR_MUTED]"
        (( alert )) && overflow_style="#[fg=$STATUS_COLOR_ASK]"
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
