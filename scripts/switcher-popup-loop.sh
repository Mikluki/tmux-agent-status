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
    rm -f "$state_dir/relaunch" "$state_dir/rows.seed"

    mode=$(<"$state_dir/mode")
    preview_hidden=$(<"$state_dir/preview-hidden")

    # When preview is hidden, use the original fixed 60×14 popup — that
    # size worked well in practice. When preview is visible we need room
    # for the 65%-wide preview pane, so use a percent of the screen.
    # LOCAL PATCH (not upstream): popup size was hardcoded. Read it from
    # tmux.conf so the knob lives in user-owned config.
    if [ "$preview_hidden" = "1" ]; then
        W=$(tmux show-option -gqv "@agent-switcher-popup-width-bare" 2>/dev/null)
        H=$(tmux show-option -gqv "@agent-switcher-popup-height-bare" 2>/dev/null)
        [ -z "$W" ] && W=60
        [ -z "$H" ] && H=14

        # LOCAL PATCH (not upstream): the bare popup was a fixed box holding a
        # much smaller list — 5 agents in a 16-row frame left 7 blank rows. In
        # the flat agents view the row count is known before launch and cannot
        # change while the popup is open, so size the box to it.
        #
        # Tree mode is deliberately excluded: `tab` expands a session in place
        # and a tmux popup cannot be resized in flight, so it keeps the fixed
        # height and has somewhere to grow into.
        autosize=$(tmux show-option -gqv "@agent-switcher-popup-autosize" 2>/dev/null)
        if [ "$mode" = "agents" ] && [ "$autosize" != "off" ]; then
            hmin=$(tmux show-option -gqv "@agent-switcher-popup-height-min" 2>/dev/null)
            hmax=$(tmux show-option -gqv "@agent-switcher-popup-height-max" 2>/dev/null)
            [ -z "$hmin" ] && hmin=6
            [ -z "$hmax" ] && hmax=20

            # Keep the rows we just computed: the inner script picks the seed
            # up as fzf's initial input, so sizing the box costs no extra
            # ps/tmux sweep (that sweep is 0.2-0.4s on a busy server).
            "$INNER" --rows-agents > "$state_dir/rows.seed" 2>/dev/null || :
            rows=$(wc -l < "$state_dir/rows.seed")
            # popup border 2 + fzf header 1 + prompt 1
            H=$((rows + 4))
            [ "$H" -lt "$hmin" ] && H=$hmin
            [ "$H" -gt "$hmax" ] && H=$hmax
        fi
    else
        W=$(tmux show-option -gqv "@agent-switcher-popup-width" 2>/dev/null)
        H=$(tmux show-option -gqv "@agent-switcher-popup-height" 2>/dev/null)
        [ -z "$W" ] && W="75%"
        [ -z "$H" ] && H="60%"
    fi

    tmux display-popup -E \
        -w "$W" -h "$H" \
        -T " Switch Pane " \
        -S fg=colour250 -s fg=colour250 \
        "env TMUX_AGENT_SWITCHER_STATE_DIR='$state_dir' '$INNER'" \
        || true

    [ -f "$state_dir/relaunch" ] || break
done
