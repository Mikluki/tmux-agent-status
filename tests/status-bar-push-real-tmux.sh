#!/usr/bin/env bash

# Renaming a pin must show on the status bar at once, not on the next poll.
# Two polls used to stack: the collector noticed the pin change on its next
# ~1s collect, then tmux re-ran the status-right #() only every
# status-interval. Now pin-target.sh wakes the collector with a signal, and
# the collector pushes a changed status line to every client with
# refresh-client -S. Here status-interval is 15s, so only that push can make
# the bar show the new tag within the bound asserted below.
#
# The bar is read from the terminal output of a real attached client running
# under `script`.
#
# Isolation: TMUX/TMUX_PANE are unset, HOME and TMUX_TMPDIR live in a temp
# dir, every tmux call goes through a wrapper that pins -S to the temp socket,
# and the collector started here is killed by pid.

set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REAL_TMUX=$(command -v tmux || true)
if [ -z "$REAL_TMUX" ] || ! command -v script >/dev/null 2>&1; then
    echo "status bar push real-tmux checks skipped (needs tmux and script)"
    exit 0
fi

# The push must land well inside this; the fallback polls take 1s and 15s.
PUSH_BOUND_MS=800

# Short base dir: tmux socket paths are limited to ~107 bytes.
TMP_DIR="$(mktemp -d /tmp/tas-push.XXXXXX)"
CLIENT_PID=""
COLLECTOR_PID=""

cleanup() {
    [ -n "$COLLECTOR_PID" ] && kill "$COLLECTOR_PID" 2>/dev/null || true
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
    (cd "$TMP_DIR" && "$REAL_TMUX" -S ./sock kill-server >/dev/null 2>&1) || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

export HOME="$TMP_DIR/home"
export TMUX_TMPDIR="$TMP_DIR"
mkdir -p "$HOME" "$TMP_DIR/bin"

# Every tmux call - ours, the scripts', the collector's, and the server's #()
# jobs (which inherit PATH) - lands on the isolated socket.
cat > "$TMP_DIR/bin/tmux" <<EOF
#!/usr/bin/env bash
cd "$TMP_DIR" || exit 1
exec "$REAL_TMUX" -S ./sock "\$@"
EOF
chmod +x "$TMP_DIR/bin/tmux"
export PATH="$TMP_DIR/bin:$PATH"

STATUS_DIR="$HOME/.cache/tmux-agent-status"
TYPESCRIPT="$TMP_DIR/typescript"

fail() {
    echo "Assertion failed: $*" >&2
    exit 1
}

now_ms() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local us="${EPOCHREALTIME/[.,]/}"
        echo $(( us / 1000 ))
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

# wait_for <expr> [timeout seconds]
wait_for() {
    local deadline=$(( $(now_ms) + ${2:-10} * 1000 ))
    while (( $(now_ms) < deadline )); do
        if eval "$1"; then
            return 0
        fi
        sleep 0.02
    done
    return 1
}

# Terminal output after byte offset $2 contains $1.
screen_shows_since() {
    tail -c "+$(( $2 + 1 ))" "$TYPESCRIPT" 2>/dev/null | grep -qF "$1"
}

tmux -f /dev/null new-session -d -s t -x 120 -y 20 'sleep 600'
tmux set-option -g exit-empty off
tmux set-option -g status-interval 15
tmux set-option -g status-right "#($REPO_DIR/scripts/status-line.sh)"
tmux set-option -g status-right-length 80

# A tracked agent pane. sleep is not a bare shell, so the collector keeps
# its markers.
pane_id=$(tmux display-message -p -t t: '#{pane_id}')
mkdir -p "$STATUS_DIR/panes"
echo done > "$STATUS_DIR/panes/t_${pane_id}.status"
echo claude > "$STATUS_DIR/panes/t_${pane_id}.agent"

bash "$REPO_DIR/scripts/pin-target.sh" --apply "${pane_id#%}" old1
[ "$(tmux show-option -gqv @agent-pins)" = "old1:$pane_id:" ] || fail "initial pin was not stored"

bash "$REPO_DIR/scripts/sidebar-collector.sh" > /dev/null 2>&1 &
COLLECTOR_PID=$!
wait_for 'grep -qF old1 "$STATUS_DIR/.status-line" 2>/dev/null' \
    || fail "collector never published the initial pin"
[ "$(cat "$STATUS_DIR/.sidebar-collector.pid")" = "$COLLECTOR_PID" ] || fail "collector did not record its pid"

# Attached client whose keyboard is a FIFO held open on fd 3, so it never
# sees EOF; its screen goes to the typescript.
mkfifo "$TMP_DIR/keys"
script -qfc "env TERM=xterm-256color tmux attach -t t" "$TYPESCRIPT" < "$TMP_DIR/keys" > /dev/null 2>&1 &
CLIENT_PID=$!
exec 3> "$TMP_DIR/keys"
wait_for '[ -n "$(tmux list-clients -F x 2>/dev/null)" ]' || fail "client never attached"
wait_for 'screen_shows_since old1 0' || fail "the bar never showed the initial tag"

# Rename, then time how long until the client's screen shows the new tag.
offset=$(wc -c < "$TYPESCRIPT")
start=$(now_ms)
bash "$REPO_DIR/scripts/pin-target.sh" --apply "${pane_id#%}" new2
wait_for 'screen_shows_since new2 "$offset"' 10 \
    || fail "the bar never showed the renamed tag (status-line cache: $(cat "$STATUS_DIR/.status-line"))"
elapsed=$(( $(now_ms) - start ))
echo "  bar updated ${elapsed}ms after the rename"

(( elapsed < PUSH_BOUND_MS )) \
    || fail "the bar took ${elapsed}ms to show the renamed tag (bound ${PUSH_BOUND_MS}ms): the collector was not woken, or did not push"

# A second rename right away, usually within the same second: the mtime the
# collector compares has one-second resolution, so a poll alone would not
# see this change until its forced rebuild ~10 collects later.
offset=$(wc -c < "$TYPESCRIPT")
start=$(now_ms)
bash "$REPO_DIR/scripts/pin-target.sh" --apply "${pane_id#%}" zq3x
wait_for 'screen_shows_since zq3x "$offset"' 10 \
    || fail "the bar never showed the second renamed tag"
elapsed=$(( $(now_ms) - start ))
echo "  bar updated ${elapsed}ms after the rename"
(( elapsed < PUSH_BOUND_MS )) \
    || fail "the second rename took ${elapsed}ms to show (bound ${PUSH_BOUND_MS}ms)"

echo "status bar push real-tmux checks passed"
