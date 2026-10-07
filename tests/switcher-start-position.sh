#!/usr/bin/env bash
# Where the picker's cursor starts, and that it stays put afterwards.
#
# It opens on the pane the picker was opened from; failing that, the first row
# in the same window, then the same session, then the top row. A preview
# relaunch reopens on the row the cursor was on. The start position holds on
# the first load only: reloads (the 2s refresh, the one after m) keep the
# cursor on the same target via --track --id-nth.
#
# Part one runs the picker in a pane of an isolated tmux server with seeded
# rows and reads the cursor through fzf's --listen socket. Part two drives
# the real popup loop from a key binding on an attached client.
#
# Isolation: TMUX/TMUX_PANE are unset, HOME, TMUX_TMPDIR and TMPDIR live in a
# temp dir, and every tmux call goes through a wrapper that pins -S to the
# temp socket, so nothing here can reach the user's own server.
set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="$REPO_DIR/scripts/hook-based-switcher.sh"
LOOP_FILE="$REPO_DIR/scripts/switcher-popup-loop.sh"

REAL_TMUX=$(command -v tmux || true)
if [ -z "$REAL_TMUX" ] || ! command -v fzf >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "switcher start position checks skipped (needs tmux, fzf and curl)"
    exit 0
fi

# Short base dir: tmux socket paths are limited to ~107 bytes.
TMP_DIR="$(mktemp -d /tmp/tas-start.XXXXXX)"
CLIENT_PID=""

cleanup() {
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
    (cd "$TMP_DIR" && "$REAL_TMUX" -S ./sock kill-server >/dev/null 2>&1) || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

export HOME="$TMP_DIR/home"
export TMUX_TMPDIR="$TMP_DIR"
export TMPDIR="$TMP_DIR"
mkdir -p "$HOME" "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/tmux" <<EOF
#!/usr/bin/env bash
cd "$TMP_DIR" || exit 1
exec "$REAL_TMUX" -S ./sock "\$@"
EOF
chmod +x "$TMP_DIR/bin/tmux"
export PATH="$TMP_DIR/bin:$PATH"

PANE_DIR="$HOME/.cache/tmux-agent-status/panes"
mkdir -p "$PANE_DIR"

fail() {
    echo "Assertion failed: $*" >&2
    exit 1
}

wait_for() {
    local i
    for i in $(seq 1 50); do
        if eval "$1"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Window t:0 holds panes A and B, t:1 holds C, session u holds D.
tmux -f /dev/null new-session -d -s t -x 100 -y 30 'sleep 600'
tmux set-option -g exit-empty off
A=$(tmux display-message -p -t t:0 '#{pane_id}')
B=$(tmux split-window -d -P -F '#{pane_id}' -t t:0 'sleep 600')
C=$(tmux new-window -d -P -F '#{pane_id}' -t t: 'sleep 600')
tmux new-session -d -s u 'sleep 600'
D=$(tmux display-message -p -t u: '#{pane_id}')

# ── Part one: the picker in a pane ─────────────────────────────────
STATE_DIR="$TMP_DIR/state"
mkdir -p "$STATE_DIR"
SOCK="$STATE_DIR/fzf.sock"

row() {
    printf 'P\t%s\trow %s\n' "$1" "$1"
}

current() {
    curl --silent --unix-socket "$SOCK" http://localhost 2>/dev/null \
        | sed -n 's/.*"current":{[^}]*"text":"P\\t\([^"\\]*\)\\t.*/\1/p'
}

# open_picker <origin> [focus] — rows come from rows.seed (tree mode, so the
# 2s refresh stays idle and the test drives every reload itself).
open_picker() {
    printf 'tree' > "$STATE_DIR/mode"
    printf '1' > "$STATE_DIR/preview-hidden"
    printf '%s\n' "$1" > "$STATE_DIR/origin"
    rm -f "$STATE_DIR/focus"
    [ -n "${2:-}" ] && printf '%s\n' "$2" > "$STATE_DIR/focus"
    tmux new-window -d -n picker -t t: \
        "env TMUX_AGENT_SWITCHER_STATE_DIR='$STATE_DIR' bash '$SCRIPT_FILE'"
    wait_for '[ -S "$SOCK" ] && [ -n "$(current)" ]' || fail "the picker did not start"
}

close_picker() {
    tmux kill-window -t t:picker 2>/dev/null || true
    wait_for '[ ! -S "$SOCK" ]' || rm -f "$SOCK"
}

expect_start() {
    local want="$1" message="$2"
    local got
    got=$(current)
    [ "$got" = "$want" ] || fail "$message (cursor on '$got', want '$want')"
}

# The origin's own row.
{ row "u:$D"; row "t:$A"; row "t:$B"; row "t:$C"; } > "$STATE_DIR/rows.seed"
open_picker "t:$B"
expect_start "t:$B" "the cursor should start on the origin pane"
close_picker

# The origin is not listed (not an agent): an agent in the same window.
{ row "u:$D"; row "t:$C"; row "t:$A"; } > "$STATE_DIR/rows.seed"
open_picker "t:$B"
expect_start "t:$A" "the cursor should fall back to an agent in the same window"
close_picker

# None in the window: the same session.
{ row "u:$D"; row "t:$C"; } > "$STATE_DIR/rows.seed"
open_picker "t:$B"
expect_start "t:$C" "the cursor should fall back to an agent in the same session"
close_picker

# Nothing in the session: the top row.
{ row "u:$D"; row "u:%999"; } > "$STATE_DIR/rows.seed"
open_picker "t:$B"
expect_start "u:$D" "the cursor should fall back to the top row"
close_picker

# A relaunch (preview toggle) reopens on the row the cursor was on.
{ row "u:$D"; row "t:$A"; row "t:$B"; row "t:$C"; } > "$STATE_DIR/rows.seed"
open_picker "t:$B" "t:$C"
expect_start "t:$C" "a relaunch should reopen on the focused row, not the origin"
[ ! -f "$STATE_DIR/focus" ] || fail "the focus should be used once"

# Reloads track the target instead of snapping back to the start row.
tmux send-keys -t t:picker k
wait_for '[ "$(current)" = "t:$B" ]' || fail "k should move up"
{ row "t:$C"; row "t:$A"; row "u:$D"; row "t:$B"; } > "$TMP_DIR/rows.moved"
curl --silent --unix-socket "$SOCK" -X POST http://localhost -d "reload(cat '$TMP_DIR/rows.moved')" >/dev/null
sleep 0.5
expect_start "t:$B" "a reload should keep the cursor on the same target"
{ row "t:$B"; row "t:$C"; row "t:$A"; row "u:$D"; } > "$TMP_DIR/rows.moved2"
curl --silent --unix-socket "$SOCK" -X POST http://localhost -d "reload(cat '$TMP_DIR/rows.moved2')" >/dev/null
sleep 0.5
expect_start "t:$B" "a second reload should still track, not snap back"

# Typing a query still lands on the top match.
tmux send-keys -t t:picker i
sleep 0.2
tmux send-keys -t t:picker -l "$C"
wait_for '[ "$(current)" = "t:$C" ]' || fail "a query change should move to the top match (cursor on '$(current)')"
close_picker

# ── Part two: the real popup loop ──────────────────────────────────
if ! command -v script >/dev/null 2>&1; then
    echo "switcher start position checks passed (popup loop drive skipped: needs script)"
    exit 0
fi

# A and C run agents in agents mode; B is the plain pane we open from.
for p in "$A" "$C"; do
    echo done > "$PANE_DIR/t_${p}.status"
    echo claude > "$PANE_DIR/t_${p}.agent"
done
echo done > "$PANE_DIR/u_${D}.status"
echo claude > "$PANE_DIR/u_${D}.agent"
tmux set-option -g @agent-switcher-preview-default hidden

mkfifo "$TMP_DIR/keys"
script -qfc "env TERM=xterm-256color tmux attach -t t:0" /dev/null < "$TMP_DIR/keys" > /dev/null 2>&1 &
CLIENT_PID=$!
exec 3> "$TMP_DIR/keys"
wait_for '[ -n "$(tmux list-clients -F x 2>/dev/null)" ]' || fail "client never attached"
tmux select-pane -t "$B"

# The plugin's binding, verbatim apart from the key and the mode.
grep -Fq "env TMUX_AGENT_SWITCHER_ORIGIN=#{pane_id} TMUX_AGENT_SWITCHER_MODE=" "$REPO_DIR/tmux-agent-status.tmux" \
    || fail "the popup binding should pass the origin pane"
tmux bind-key -n F5 run-shell -b \
    "env TMUX_AGENT_SWITCHER_ORIGIN=#{pane_id} TMUX_AGENT_SWITCHER_MODE=agents '$LOOP_FILE'"

loop_sock() {
    local s
    for s in "$TMP_DIR"/tmux-agent-status-switcher.*/fzf.sock; do
        [ -S "$s" ] && { printf '%s\n' "$s"; return 0; }
    done
    return 1
}

printf '\033[15~' >&3
wait_for 'SOCK=$(loop_sock) && [ -n "$(current)" ]' || fail "the popup picker did not start"
# Agents rows, priority order: B is not an agent, so its window-mate A wins.
expect_start "t:$A" "the popup should open on the agent beside the origin pane"

# Survives the 2s refresh without snapping back.
printf 'j' >&3
wait_for '[ "$(current)" != "t:$A" ]' || fail "j should move down"
moved=$(current)
sleep 2.5
expect_start "$moved" "the 2s refresh should keep the cursor where it was"

# m pins in place and the reload keeps the row.
printf 'm' >&3
wait_for '[ -n "$(tmux show-option -gqv @agent-pins)" ]' || fail "m should pin"
sleep 0.5
expect_start "$moved" "the reload after m should keep the cursor on the pinned row"

# p relaunches the popup; it reopens on the same row.
old_sock="$SOCK"
printf 'p' >&3
wait_for '! [ -S "$old_sock" ] || [ "$(current)" = "" ]' || true
sleep 0.5
wait_for 'SOCK=$(loop_sock) && [ -n "$(current)" ]' || fail "the popup did not relaunch"
expect_start "$moved" "the relaunched popup should reopen on the same row"

printf 'q' >&3
wait_for '! loop_sock >/dev/null' || fail "q should close the popup"

echo "switcher start position checks passed"
