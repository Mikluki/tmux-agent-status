#!/usr/bin/env bash

# Pinned watchlist store.
#
# The status bar shows only the agents you pin, each as a short tag. Pins live
# in the global tmux option @agent-pins, so they last exactly as long as the
# tmux server: pane ids are recycled across restarts, and a persisted pin would
# latch onto an unrelated pane.
#
# One space-separated record per pin, in pin order:
#
#     <tag>:<pane_id>:<last_state>
#
# Order is append-on-pin and never re-sorted — where a tag sits is part of its
# identity, so re-sorting would force a re-read every glance. <last_state> is
# the last state seen while the pane was alive; it decides what happens when
# the pane dies (dropped if it finished, held dim otherwise).

[[ -n "${_PINS_LIB_LOADED:-}" ]] && return 0
_PINS_LIB_LOADED=1

PINS_OPTION="@agent-pins"
PINS_TAG_MAX=4

# One "tag<TAB>pane_id<TAB>last_state" line per pin, in pin order.
pins_read() {
    local raw record rest
    raw=$(tmux show-option -gqv "$PINS_OPTION" 2>/dev/null || echo "")
    for record in $raw; do
        [[ "$record" == *:*:* ]] || continue
        rest="${record#*:}"
        printf '%s\t%s\t%s\n' "${record%%:*}" "${rest%%:*}" "${rest#*:}"
    done
}

# Replace the store with the "tag<TAB>pane_id<TAB>last_state" lines on stdin.
pins_write() {
    local records=() tag pane state
    while IFS=$'\t' read -r tag pane state; do
        [ -n "$tag" ] && [ -n "$pane" ] || continue
        records+=("${tag}:${pane}:${state}")
    done

    if (( ${#records[@]} == 0 )); then
        tmux set-option -gu "$PINS_OPTION" >/dev/null 2>&1 || true
    else
        tmux set-option -gq "$PINS_OPTION" "${records[*]}" >/dev/null 2>&1 || true
    fi
}

# Tag currently pinned to a pane, if any.
pin_tag_for() {
    local wanted="$1" tag pane state
    while IFS=$'\t' read -r tag pane state; do
        if [ "$pane" = "$wanted" ]; then
            printf '%s\n' "$tag"
            return 0
        fi
    done < <(pins_read)
    return 1
}

# Tags are 1-4 characters with no whitespace and no ":" (the record separator).
pin_tag_valid() {
    local tag="$1"
    [ -n "$tag" ] || return 1
    (( ${#tag} <= PINS_TAG_MAX )) || return 1
    [[ "$tag" != *[[:space:]:]* ]]
}

# pin_derive_tag <window_name> <session_name> <pane_id>
# Tag to prefill the pin prompt with for an unpinned row: the window name
# trimmed to three characters, falling back to the session name. If another
# pane already holds that, the first free of base2..base9 instead, so Enter on
# the prefill pins even when several agents share a window name. If all are
# taken, the bare base, and pin_set's rejection reports it.
pin_derive_tag() {
    local window_name="$1"
    local session_name="$2"
    local pane_id="${3:-}"
    local base="$window_name"
    local -A held=()
    local tag pane state n

    [ -n "$base" ] || base="$session_name"
    base="${base//[[:space:]:]/}"
    base="${base:0:3}"

    if [ -n "$base" ]; then
        while IFS=$'\t' read -r tag pane state; do
            [ -n "$tag" ] && [ "$pane" != "$pane_id" ] && held[$tag]=1
        done < <(pins_read)

        if [ -n "${held[$base]:-}" ]; then
            for n in 2 3 4 5 6 7 8 9; do
                if [ -z "${held[$base$n]:-}" ]; then
                    printf '%s\n' "$base$n"
                    return 0
                fi
            done
        fi
    fi
    printf '%s\n' "$base"
}

# pin_set <pane_id> <tag> — pin, or rename an existing pin. Fails if another
# pane already holds the tag.
pin_set() {
    local pane_id="$1"
    local tag="$2"
    local records=() replaced=0
    local rtag rpane rstate

    while IFS=$'\t' read -r rtag rpane rstate; do
        [ -n "$rtag" ] || continue
        if [ "$rtag" = "$tag" ] && [ "$rpane" != "$pane_id" ]; then
            return 1
        fi
        if [ "$rpane" = "$pane_id" ]; then
            records+=("${tag}"$'\t'"${rpane}"$'\t'"${rstate}")
            replaced=1
        else
            records+=("${rtag}"$'\t'"${rpane}"$'\t'"${rstate}")
        fi
    done < <(pins_read)

    (( replaced )) || records+=("${tag}"$'\t'"${pane_id}"$'\t')

    printf '%s\n' "${records[@]}" | pins_write
}

pin_remove() {
    local pane_id="$1"
    local records=() rtag rpane rstate

    while IFS=$'\t' read -r rtag rpane rstate; do
        [ -n "$rtag" ] || continue
        [ "$rpane" = "$pane_id" ] && continue
        records+=("${rtag}"$'\t'"${rpane}"$'\t'"${rstate}")
    done < <(pins_read)

    if (( ${#records[@]} == 0 )); then
        printf '' | pins_write
    else
        printf '%s\n' "${records[@]}" | pins_write
    fi
}

# Resolve the watchlist against the agents that currently exist.
#
# Reads "pane_id<TAB>state" lines on stdin — every tracked agent, in any order.
# Writes "<overflow>:<alert>" as the first line, then one "tag:state" spec per
# visible pin, in pin order. State is the live state, or "dead" for a pinned
# pane that is gone but was not finished. Prunes and refreshes the store as a
# side effect, so a pin that finished and vanished disappears on its own.
pins_render_specs() {
    local -A live_state=()
    local -A pinned=()
    local pane state tag last
    local specs=() records=()
    local dirty=0 overflow=0 alert=0

    while IFS=$'\t' read -r pane state; do
        [ -n "$pane" ] || continue
        live_state[$pane]="$state"
    done

    while IFS=$'\t' read -r tag pane last; do
        [ -n "$tag" ] || continue
        pinned[$pane]=1
        state="${live_state[$pane]:-}"
        if [ -n "$state" ]; then
            [ "$state" != "$last" ] && dirty=1
            specs+=("${tag}:${state}")
            records+=("${tag}"$'\t'"${pane}"$'\t'"${state}")
        elif [ "$last" = "done" ]; then
            # Finished and gone: the pin has served its purpose.
            dirty=1
        else
            specs+=("${tag}:dead")
            records+=("${tag}"$'\t'"${pane}"$'\t'"${last}")
        fi
    done < <(pins_read)

    for pane in "${!live_state[@]}"; do
        [ -n "${pinned[$pane]:-}" ] && continue
        overflow=$((overflow + 1))
        case "${live_state[$pane]}" in
            ask) alert=1 ;;
        esac
    done

    if (( dirty )); then
        if (( ${#records[@]} == 0 )); then
            printf '' | pins_write
        else
            printf '%s\n' "${records[@]}" | pins_write
        fi
    fi

    printf '%s:%s\n' "$overflow" "$alert"
    (( ${#specs[@]} )) && printf '%s\n' "${specs[@]}"
    return 0
}
