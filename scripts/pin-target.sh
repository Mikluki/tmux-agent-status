#!/usr/bin/env bash

# Pin, rename, or unpin the watchlist tag for an agent pane.
#
# Invoked from the switcher's agents view. One key, one path: ctrl-i opens a
# prompt prefilled with the row's current tag (or a derived one when the row
# is unpinned); entering text pins or renames, entering nothing unpins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/pins.sh
source "$SCRIPT_DIR/lib/pins.sh"

force_status_dir_refresh() {
    touch "$REFRESH_FILE" 2>/dev/null || true
}

prompt_pin() {
    local sel_name="$1"
    local pane_id="${sel_name##*:}"
    local initial=""

    initial=$(pin_tag_for "$pane_id" || true)
    if [ -z "$initial" ]; then
        local window_name=""
        window_name=$(tmux display-message -p -t "$pane_id" '#{window_name}' 2>/dev/null || echo "")
        initial=$(pin_derive_tag "$window_name" "${sel_name%%:*}" "$pane_id")
    fi

    # command-prompt substitutes the reply for the first %% and for every %1
    # in the template, so a pane id like %12 would be rewritten into the tag.
    # Keep % out of the template: pass the bare number and let --apply put
    # the % back.
    tmux command-prompt -p "tag:" -I "$initial" \
        "run-shell '$SCRIPT_DIR/pin-target.sh --apply \"${pane_id#%}\" \"%%\"'"
}

apply_pin() {
    local pane_id="$1"
    local tag="${2:-}"

    # The prompt hands over the pane number without its %; restore it.
    [[ "$pane_id" =~ ^[0-9]+$ ]] && pane_id="%$pane_id"

    if [ -z "$tag" ]; then
        pin_remove "$pane_id"
        force_status_dir_refresh
        tmux display-message "Unpinned $pane_id" 2>/dev/null || true
        return 0
    fi

    if ! pin_tag_valid "$tag"; then
        tmux display-message "Tag must be 1-$PINS_TAG_MAX characters with no spaces" 2>/dev/null || true
        return 0
    fi

    if ! pin_set "$pane_id" "$tag"; then
        tmux display-message "Tag $tag is already taken" 2>/dev/null || true
        return 0
    fi

    force_status_dir_refresh
    tmux display-message "Pinned $pane_id as $tag" 2>/dev/null || true
}

case "${1:-}" in
    --apply)
        apply_pin "${2:-}" "${3:-}"
        ;;
    *)
        prompt_pin "${1:-}"
        ;;
esac
