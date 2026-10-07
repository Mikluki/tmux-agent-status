#!/usr/bin/env bash

set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="$REPO_DIR/scripts/hook-based-switcher.sh"

assert_contains() {
    local needle="$1"
    local message="$2"

    if ! grep -Fq -- "$needle" "$SCRIPT_FILE"; then
        echo "Assertion failed: $message" >&2
        exit 1
    fi
}

assert_not_contains() {
    local needle="$1"
    local message="$2"

    if grep -Fq -- "$needle" "$SCRIPT_FILE"; then
        echo "Assertion failed: $message" >&2
        exit 1
    fi
}

assert_contains '--bind="ctrl-x:' "switcher should use ctrl-x for close"
assert_not_contains '--bind="ctrl-w:' "wait is off the picker: ctrl-w should not be bound"
assert_not_contains 'wait-target.sh' "the picker should not start waits (prefix+W does)"
assert_contains '--bind="ctrl-p:' "switcher should use ctrl-p for the preview toggle"
assert_not_contains '--reset' "the reset action is gone"
assert_contains '--bind="ctrl-j:down,ctrl-k:up"' "ctrl-j/k should move in both picker modes"

# Plain letters act only in normal mode: they live in one bind set that
# entering insert mode unbinds (see switcher-mode-bindings.sh), never as
# standalone binds that would stop them typing into the query.
assert_contains 'PICKER_NORMAL_HINT='"'"'i search  m pin  p preview  x close  q quit'"'" \
    "normal mode should advertise its letter actions"
assert_contains 'PICKER_INSERT_HINT='"'"'esc normal  C-i pin  C-p preview  C-x close'"'" \
    "insert mode should advertise esc and the control-key actions"
assert_contains 'normal_binds+=",m:$tab_bind,p:$ctrl_p_bind,x:$close_bind"' \
    "normal-mode letters should reuse the control-key actions"
assert_contains '--bind="$normal_binds"' "normal-mode letters should be bound as one set"

assert_not_contains '--bind="x:' "plain x should not be bound outside the normal-mode set"
assert_not_contains '--bind="p:' "plain p should not be bound outside the normal-mode set"
assert_not_contains '--bind="w:' "plain w should not be bound outside the normal-mode set"
assert_not_contains '--bind="alt-x:' "alt-x should no longer be bound in the switcher"

assert_contains '--tab-action' "ctrl-i should route through the mode-aware action"

echo "switcher action binding regression checks passed"
