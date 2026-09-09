#!/usr/bin/env bash
# ctrl-i (the same byte as tab) branches on mode: structural expand in tree,
# pin in agents. ctrl-p toggles the preview in both modes, under both display
# methods — in a popup by relaunching it, in a window in place.
set -euo pipefail

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
    *pin-target.sh*abort*) ;;
    *) fail "agents mode should pin on ctrl-i: $agents_action" ;;
esac
case "$agents_action" in
    *--toggle-expand*) fail "agents mode should not expand: $agents_action" ;;
esac

# ── ctrl-p, window display method (in place) ──────────────────────
grep -Fq 'ctrl_p_bind="change-preview-window(right,65%,border-left,wrap|right,65%,border-left,wrap,hidden)"' "$SCRIPT_FILE" \
    || fail "ctrl-p should toggle the preview in place under the window display method"
grep -Fq -- '--bind="ctrl-p:$ctrl_p_bind"' "$SCRIPT_FILE" \
    || fail "ctrl-p should be bound to the preview toggle"

# ── ctrl-p, popup display method (relaunch) ───────────────────────
grep -Fq "ctrl_p_bind=\"execute-silent(bash '\$0' --state-dir '\$state_dir' --request-relaunch toggle-preview)+abort\"" "$SCRIPT_FILE" \
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

echo "switcher tab and preview checks passed"
