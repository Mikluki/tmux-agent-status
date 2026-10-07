#!/usr/bin/env bash
# ctrl-i (the same byte as tab) branches on mode: structural expand in tree,
# pin toggle in agents (the picker stays open and reloads). ctrl-r renames in
# agents and does nothing in tree. ctrl-p toggles the preview in both modes, under both display
# methods — in a popup by relaunching it, in a window in place.
set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="$REPO_DIR/scripts/hook-based-switcher.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATE_DIR="$TMP_DIR/state"

mkdir -p "$FAKE_BIN" "$TEST_HOME" "$STATE_DIR"

cat > "$FAKE_BIN/tmux" <<'TMUX_EOF'
#!/usr/bin/env bash
exit 0
TMUX_EOF
chmod +x "$FAKE_BIN/tmux"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TEST_HOME"

switcher() {
    "$SCRIPT_FILE" --state-dir "$STATE_DIR" "$@"
}

fail() {
    echo "Assertion failed: $1" >&2
    exit 1
}

# ── ctrl-i ────────────────────────────────────────────────────────
switcher --set-mode tree
tree_action="$(switcher --tab-action)"
case "$tree_action" in
    *--toggle-expand*reload*) ;;
    *) fail "tree mode should keep expand/collapse on ctrl-i: $tree_action" ;;
esac
case "$tree_action" in
    *pin-target.sh*) fail "tree mode should not pin: $tree_action" ;;
esac

switcher --set-mode agents
agents_action="$(switcher --tab-action)"
case "$agents_action" in
    execute-silent\(*pin-target.sh*--toggle*\{2\}*\)+reload\(*--rows\)) ;;
    *) fail "agents mode should toggle the pin and reload on ctrl-i: $agents_action" ;;
esac
case "$agents_action" in
    *--toggle-expand*) fail "agents mode should not expand: $agents_action" ;;
    *abort*) fail "pinning should keep the picker open: $agents_action" ;;
esac

# ── ctrl-r ────────────────────────────────────────────────────────
rename_action="$(switcher --rename-action)"
case "$rename_action" in
    execute-silent\(*pin-target.sh*--rename*\{2\}*\)+abort) ;;
    *) fail "agents mode should open the rename prompt and close the picker: $rename_action" ;;
esac
switcher --set-mode tree
[ "$(switcher --rename-action)" = "ignore" ] || fail "rename should do nothing in tree mode"

# ── ctrl-p, window display method (in place) ──────────────────────
grep -Fq 'ctrl_p_bind="change-preview-window($(preview_window_spec)|$(preview_window_spec),hidden)"' "$SCRIPT_FILE" \
    || fail "ctrl-p should toggle the preview in place under the window display method"
grep -Fq -- '--bind="ctrl-p:$ctrl_p_bind"' "$SCRIPT_FILE" \
    || fail "ctrl-p should be bound to the preview toggle"

# ── ctrl-p, popup display method (relaunch) ───────────────────────
grep -Fq "ctrl_p_bind=\"execute-silent(bash '\$0' --state-dir '\$state_dir' --request-relaunch toggle-preview --focus {2})+abort\"" "$SCRIPT_FILE" \
    || fail "ctrl-p should request a popup relaunch when wrapped by the popup loop"

for mode in tree agents; do
    switcher --set-mode "$mode"
    printf '1' > "$STATE_DIR/preview-hidden"
    rm -f "$STATE_DIR/relaunch"
    switcher --request-relaunch toggle-preview
    [ "$(<"$STATE_DIR/preview-hidden")" = "0" ] || fail "ctrl-p should reveal the preview in $mode mode"
    [ -f "$STATE_DIR/relaunch" ] || fail "ctrl-p should ask the popup loop to relaunch in $mode mode"

    switcher --request-relaunch toggle-preview
    [ "$(<"$STATE_DIR/preview-hidden")" = "1" ] || fail "ctrl-p should hide the preview again in $mode mode"
done

# The relaunched picker reopens on the row the cursor was on.
rm -f "$STATE_DIR/focus"
switcher --request-relaunch toggle-preview --focus 'api:%12'
[ "$(<"$STATE_DIR/focus")" = "api:%12" ] || fail "the preview relaunch should remember the focused row"

# ── normal-mode letters share the same actions ───────────────────
grep -Fq 'm:$tab_bind' "$SCRIPT_FILE" || fail "m should pin through the same mode-aware action as ctrl-i"
grep -Fq 'r:$rename_bind' "$SCRIPT_FILE" || fail "r should rename through the same action as ctrl-r"
grep -Fq 'p:$ctrl_p_bind' "$SCRIPT_FILE" || fail "p should toggle the preview like ctrl-p"

# The preview toggle aborts and the popup loop starts a fresh picker, which
# always opens in normal mode.
grep -Fq -- '--prompt="$PICKER_NORMAL_PROMPT"' "$SCRIPT_FILE" \
    || fail "a relaunched picker should open in normal mode"

echo "switcher tab and preview checks passed"
