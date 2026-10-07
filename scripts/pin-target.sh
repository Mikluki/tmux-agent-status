#!/usr/bin/env bash

# Pin, rename, or unpin the watchlist tag for an agent pane.
#
# Invoked from the switcher's agents view:
#
#   --toggle <session:pane>   m / ctrl-i. Unpinned: pin under the derived tag,
#                             no prompt. Pinned: unpin. The picker stays open
#                             and reloads its rows.
#   --rename <session:pane>   r / ctrl-r. Opens a prompt prefilled with the
#                             current tag, or the derived one when unpinned;
#                             Enter pins or renames. Empty input or Esc leaves
#                             the pin as it was.
#   --apply <pane> <tag>      The prompt's callback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/pins.sh
source "$SCRIPT_DIR/lib/pins.sh"
# shellcheck source=lib/sidebar-clients.sh
source "$SCRIPT_DIR/lib/sidebar-clients.sh"

report() {
    tmux display-message "$1" 2>/dev/null || true
}

derived_tag_for() {
    local sel_name="$1"
    local pane_id="${sel_name##*:}"
    local window_name=""

    window_name=$(tmux display-message -p -t "$pane_id" '#{window_name}' 2>/dev/null || echo "")
    pin_derive_tag "$window_name" "${sel_name%%:*}" "$pane_id"
}

# Pin under the given tag, reporting a rejection instead of failing.
pin_checked() {
    local pane_id="$1"
    local tag="$2"

    if ! pin_tag_valid "$tag"; then
        report "Tag must be 1-$PINS_TAG_MAX characters with no spaces"
        return 0
    fi

    if ! pin_set "$pane_id" "$tag"; then
        report "Tag $tag is already taken"
        return 0
    fi

    wake_collector
}

toggle_pin() {
    local sel_name="$1"
    local pane_id="${sel_name##*:}"

    [[ "$pane_id" == %* ]] || return 0

    if pin_tag_for "$pane_id" >/dev/null; then
        pin_remove "$pane_id"
        wake_collector
        return 0
    fi

    pin_checked "$pane_id" "$(derived_tag_for "$sel_name")"
}

prompt_rename() {
    local sel_name="$1"
    local pane_id="${sel_name##*:}"
    local initial=""

    [[ "$pane_id" == %* ]] || return 0

    initial=$(pin_tag_for "$pane_id" || true)
    [ -n "$initial" ] || initial=$(derived_tag_for "$sel_name")

    # command-prompt substitutes the reply for the first %% and for every %1
    # in the template, so a pane id like %12 would be rewritten into the tag.
    # Keep % out of the template: pass the bare number and let --apply put
    # the % back.
    tmux command-prompt -b -p "tag:" -I "$initial" \
        "run-shell '$SCRIPT_DIR/pin-target.sh --apply \"${pane_id#%}\" \"%%\"'"
}

apply_pin() {
    local pane_id="$1"
    local tag="${2:-}"

    # The prompt hands over the pane number without its %; restore it.
    [[ "$pane_id" =~ ^[0-9]+$ ]] && pane_id="%$pane_id"

    # Empty input is "never mind", not "unpin": unpinning is m's job.
    [ -n "$tag" ] || return 0

    pin_checked "$pane_id" "$tag"
}

case "${1:-}" in
    --apply)
        apply_pin "${2:-}" "${3:-}"
        ;;
    --toggle)
        toggle_pin "${2:-}"
        ;;
    --rename)
        prompt_rename "${2:-}"
        ;;
    *)
        prompt_rename "${1:-}"
        ;;
esac
