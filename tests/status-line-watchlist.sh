#!/usr/bin/env bash
# status-line.sh end to end: only pinned panes reach the bar, a pane that dies
# while working is held dim, and the rest are counted.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
LIVE_PANES="$TMP_DIR/live-panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<'TMUX_EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-sessions)
        echo "api"
        ;;
    list-panes)
        cat "${TMUX_LIVE_PANES:?}"
        ;;
    show-option)
        if [ "${3:-}" = "@agent-notification-sound" ]; then
            echo "none"
        elif [ -f "${TMUX_FAKE_OPTIONS:?}" ]; then
            cat "$TMUX_FAKE_OPTIONS"
        fi
        ;;
    set-option)
        if [ "${2:-}" = "-gu" ]; then
            : > "${TMUX_FAKE_OPTIONS:?}"
        else
            printf '%s\n' "${4:-}" > "${TMUX_FAKE_OPTIONS:?}"
        fi
        ;;
esac
exit 0
TMUX_EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
exit 1
PGREP_EOF
chmod +x "$FAKE_BIN/pgrep"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TEST_HOME"
export TMUX_FAKE_OPTIONS="$TMP_DIR/options"
export TMUX_LIVE_PANES="$LIVE_PANES"
: > "$TMUX_FAKE_OPTIONS"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

printf '%s\n' "%12" "%14" "%16" > "$LIVE_PANES"
echo "working" > "$PANE_DIR/api_%12.status"
echo "done"    > "$PANE_DIR/api_%14.status"
echo "ask"     > "$PANE_DIR/api_%16.status"

assert_eq "#[fg=magenta]·3#[default]" "$("$REPO_DIR/scripts/status-line.sh")" \
    "with nothing pinned the bar is just the overflow count, in the ask colour for the asking %16"

"$REPO_DIR/scripts/pin-target.sh" --apply "%12" "bug" >/dev/null 2>&1
"$REPO_DIR/scripts/pin-target.sh" --apply "%16" "web" >/dev/null 2>&1

pinned="$("$REPO_DIR/scripts/status-line.sh")"
assert_eq "#[fg=yellow,bold]bug#[default]  #[fg=magenta,bold]web?#[default]   #[fg=brightblack]·1#[default]" \
    "$pinned" "pinned panes should render as tags in pin order, the done %14 counted dim"
assert_eq "$pinned" "$("$REPO_DIR/scripts/status-line.sh")" \
    "the bar should be byte-identical while no agent changes state"

# %12 dies while still working: its tag is held in dim grey. %16 finished
# first and then died, so its pin goes with it.
echo "done" > "$PANE_DIR/api_%16.status"
"$REPO_DIR/scripts/status-line.sh" >/dev/null
printf '%s\n' "%14" > "$LIVE_PANES"
assert_eq "#[fg=brightblack]bug#[default]   #[fg=brightblack]·1#[default]" \
    "$("$REPO_DIR/scripts/status-line.sh")" \
    "a pane that died while working should hold its tag dim, a finished one should drop"

echo "status-line watchlist checks passed"
