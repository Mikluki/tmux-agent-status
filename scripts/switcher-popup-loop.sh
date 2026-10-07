#!/usr/bin/env bash

# Popup-loop wrapper for hook-based-switcher.sh.
# tmux popups can't be resized in-flight, so when the user toggles mode
# (ctrl-f) or preview (tab in agents mode), the inner script writes a
# relaunch sentinel and aborts fzf — we then relaunch the popup with
# dimensions matched to the new (mode, preview_hidden) state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER="$SCRIPT_DIR/hook-based-switcher.sh"

state_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-status-switcher.XXXXXX")
trap 'rm -rf "$state_dir"' EXIT

# The pane the picker was opened from, where its cursor starts. Recorded once,
# here, before any popup opens: inside a popup there is no TMUX_PANE, and a
# relaunch must not re-resolve it. The key binding passes it in (run-shell
# expands #{pane_id} in the invoking pane's context); otherwise ask tmux,
# which run-shell resolves the same way.
origin_pane="${TMUX_AGENT_SWITCHER_ORIGIN:-}"
[[ "$origin_pane" =~ ^%[0-9]+$ ]] || origin_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
if [ -n "$origin_pane" ]; then
    tmux display-message -p -t "$origin_pane" '#{session_name}:#{pane_id}' \
        > "$state_dir/origin" 2>/dev/null || rm -f "$state_dir/origin"
fi

initial_mode="${TMUX_AGENT_SWITCHER_MODE:-tree}"
case "$initial_mode" in tree|agents) ;; *) initial_mode=tree ;; esac
printf '%s' "$initial_mode" > "$state_dir/mode"

# Preview defaults: upstream hides it in tree mode and shows it in agents mode,
# which also forces the large popup geometry. LOCAL PATCH (not upstream): let
# tmux.conf pin the initial state so the agents list can open in the compact
# centred popup. `tab` still toggles the preview on demand either way.
preview_default=$(tmux show-option -gqv "@agent-switcher-preview-default" 2>/dev/null)

# The agents-mode preview preference outlives mode toggles (ctrl-f), so that
# ctrl-f is a plain two-state toggle and does not resurrect the preview - and
# with it the large popup - on the way back. `tab` updates this too.
case "$preview_default" in
    hidden)  agents_pref=1 ;;
    visible) agents_pref=0 ;;
    *)       agents_pref=0 ;;   # upstream: agents mode shows the preview
esac
printf '%s' "$agents_pref" > "$state_dir/preview-hidden-agents"

if [ "$initial_mode" = "agents" ]; then
    printf '%s' "$agents_pref" > "$state_dir/preview-hidden"
else
    case "$preview_default" in
        visible) printf '0' > "$state_dir/preview-hidden" ;;
        *)       printf '1' > "$state_dir/preview-hidden" ;;
    esac
fi

while true; do
    rm -f "$state_dir/relaunch" "$state_dir/rows.seed" "$state_dir/rows.refresh"

    mode=$(<"$state_dir/mode")
    preview_hidden=$(<"$state_dir/preview-hidden")

    # LOCAL PATCH (not upstream): popup size was hardcoded (75%x60%, or a fixed
    # 60x14 once the preview was hidden). Both are computed here now, and the
    # row list that drives the computation is handed to the inner script as a
    # seed so it is not rebuilt - that sweep is 0.2-0.4s on a busy server.
    autosize=$(tmux show-option -gqv "@agent-switcher-popup-autosize" 2>/dev/null)
    rows=""
    if [ "$mode" = "agents" ] && [ "$autosize" != "off" ]; then
        "$INNER" --rows-agents > "$state_dir/rows.seed" 2>/dev/null || :
        rows=$(wc -l < "$state_dir/rows.seed")
    fi

    prev_lines=""

    if [ "$preview_hidden" = "1" ]; then
        # Bare: the list is all there is, so the box is exactly the list.
        W=$(tmux show-option -gqv "@agent-switcher-popup-width-bare" 2>/dev/null)
        H=$(tmux show-option -gqv "@agent-switcher-popup-height-bare" 2>/dev/null)
        [ -z "$W" ] && W=60
        [ -z "$H" ] && H=14

        if [ -n "$rows" ]; then
            hmin=$(tmux show-option -gqv "@agent-switcher-popup-height-min" 2>/dev/null)
            hmax=$(tmux show-option -gqv "@agent-switcher-popup-height-max" 2>/dev/null)
            [ -z "$hmin" ] && hmin=6
            [ -z "$hmax" ] && hmax=20
            # popup border 2 + fzf header 1 + prompt 1
            H=$((rows + 4))
            [ "$H" -lt "$hmin" ] && H=$hmin
            [ "$H" -gt "$hmax" ] && H=$hmax
        fi
    else
        # Preview: two stacked bands, list on top and pane capture below. The
        # list band is still exactly the list, so the popup is only as tall as
        # it needs to be and the preview gets a fixed, predictable slice rather
        # than a percentage that swings with the agent count.
        W=$(tmux show-option -gqv "@agent-switcher-popup-width" 2>/dev/null)
        H=$(tmux show-option -gqv "@agent-switcher-popup-height" 2>/dev/null)
        [ -z "$W" ] && W="75%"
        [ -z "$H" ] && H="60%"

        prev_lines=$(tmux show-option -gqv "@agent-switcher-preview-lines" 2>/dev/null)
        [ -z "$prev_lines" ] && prev_lines=20

        if [ -n "$rows" ]; then
            # + preview band and its border-top, on top of the bare chrome
            H=$((rows + 4 + prev_lines + 1))

            # Do not outgrow the client: shrink the preview band, not the list.
            client_h=$(tmux display-message -p '#{client_height}' 2>/dev/null) || client_h=""
            case "$client_h" in
                ''|*[!0-9]*) client_h=0 ;;
            esac
            if [ "$client_h" -gt 8 ] && [ "$H" -gt $((client_h - 2)) ]; then
                H=$((client_h - 2))
                prev_lines=$((H - rows - 5))
                [ "$prev_lines" -lt 4 ] && prev_lines=4
            fi
        fi
    fi

    tmux display-popup -E \
        -w "$W" -h "$H" \
        -T " Switch Pane " \
        -S fg=colour250 -s fg=colour250 \
        "env TMUX_AGENT_SWITCHER_STATE_DIR='$state_dir' TMUX_AGENT_PREVIEW_LINES='$prev_lines' '$INNER'" \
        || true

    [ -f "$state_dir/relaunch" ] || break
done
