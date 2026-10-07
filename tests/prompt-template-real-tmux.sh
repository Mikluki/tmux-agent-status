#!/usr/bin/env bash

# The pin and wait prompts go through a real tmux command-prompt, whose
# template substitution replaces the first %% and every %1 with the reply.
# A pane id such as %12 inside the template used to be rewritten into the
# reply. Mocks cannot show that, so this drives a real, isolated tmux server:
# an attached client runs under `script` with a FIFO as its keyboard, the
# scripts open their prompts on it, and the reply is typed into the FIFO.
#
# Isolation: TMUX/TMUX_PANE are unset, HOME and TMUX_TMPDIR live in a temp
# dir, and every tmux call goes through a wrapper that pins -S to the temp
# socket, so nothing here can reach the user's own server.

set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REAL_TMUX=$(command -v tmux || true)
if [ -z "$REAL_TMUX" ] || ! command -v script >/dev/null 2>&1; then
    echo "prompt template real-tmux checks skipped (needs tmux and script)"
    exit 0
fi

# Short base dir: tmux socket paths are limited to ~107 bytes.
TMP_DIR="$(mktemp -d /tmp/tas-prompt.XXXXXX)"
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
mkdir -p "$HOME" "$TMP_DIR/bin"

# Every tmux call - ours, the scripts', and run-shell jobs inside the server
# (which inherit PATH) - lands on the isolated socket.
cat > "$TMP_DIR/bin/tmux" <<EOF
#!/usr/bin/env bash
cd "$TMP_DIR" || exit 1
exec "$REAL_TMUX" -S ./sock "\$@"
EOF
chmod +x "$TMP_DIR/bin/tmux"
export PATH="$TMP_DIR/bin:$PATH"

STATUS_DIR="$HOME/.cache/tmux-agent-status"

fail() {
    echo "Assertion failed: $*" >&2
    tmux show-messages 2>/dev/null | tail -n 5 >&2 || true
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

tmux -f /dev/null new-session -d -s t -x 120 -y 40 'sleep 600'
tmux set-option -g exit-empty off

# Burn pane ids until one contains "%1" followed by more digits: that is the
# shape the template substitution used to corrupt (%1 -> reply).
pane_id=""
while :; do
    pane_id=$(tmux new-window -d -P -F '#{pane_id}' -t t: 'sleep 600')
    [[ "$pane_id" == %1? ]] && break
    tmux kill-pane -t "$pane_id"
done
win_idx=$(tmux display-message -p -t "$pane_id" '#{window_index}')

# Attached client whose keyboard is a FIFO.
# The background open blocks until fd 3 opens the write end; fd 3 then stays
# open so the client never sees EOF.
mkfifo "$TMP_DIR/keys"
script -qfc "env TERM=xterm-256color tmux attach -t t" /dev/null < "$TMP_DIR/keys" > /dev/null 2>&1 &
CLIENT_PID=$!
exec 3> "$TMP_DIR/keys"
wait_for '[ -n "$(tmux list-clients -F x 2>/dev/null)" ]' || fail "client never attached"

# command-prompt (without -b) holds the invoking client until the prompt is
# answered, so each script runs in the background while the reply is typed,
# and its exit marks the prompt as dismissed. There is no format for "prompt
# open", so the server's command log stands in for it.
BG_PID=""
prompts_seen=0

run_bg() {
    "$@" > /dev/null 2>&1 &
    BG_PID=$!
}

prompt_count() {
    tmux show-messages 2>/dev/null | grep -c 'command: command-prompt' || true
}

wait_prompt() {
    wait_for '[ "$(prompt_count)" -gt "$prompts_seen" ]' || fail "command-prompt did not open"
    prompts_seen=$(prompt_count)
    sleep 0.2
}

type_reply() {
    printf '%s\r' "$1" >&3
    wait_for '! kill -0 "$BG_PID" 2>/dev/null' || fail "command-prompt did not close"
}

reset_waits() {
    rm -f "$STATUS_DIR/wait/"*.wait "$STATUS_DIR/panes/"*.status "$STATUS_DIR/"*.status
}

# ── pin: tag prompt ─────────────────────────────────────────────────
run_bg bash "$REPO_DIR/scripts/pin-target.sh" "t:$pane_id"
wait_prompt
# Clear the prefilled tag, then type ours.
printf '\025' >&3
type_reply "abc"
wait_for '[ "$(tmux show-option -gqv @agent-pins)" = "abc:$pane_id:" ]' \
    || fail "pin should store abc:$pane_id: (got '$(tmux show-option -gqv @agent-pins)')"

# ── wait: pane target ───────────────────────────────────────────────
run_bg bash "$REPO_DIR/scripts/wait-target.sh" "t:$pane_id" "P"
wait_prompt
type_reply "5"
wait_for '[ -f "$STATUS_DIR/wait/t_${pane_id}.wait" ]' \
    || fail "pane wait should write t_${pane_id}.wait (have: $(ls "$STATUS_DIR/wait" 2>/dev/null | tr '\n' ' '))"
[ "$(cat "$STATUS_DIR/panes/t_${pane_id}.status")" = "wait" ] || fail "pane status should be wait"
reset_waits

# ── wait: window target ─────────────────────────────────────────────
run_bg bash "$REPO_DIR/scripts/wait-target.sh" "t:w$win_idx" "P"
wait_prompt
type_reply "5"
wait_for '[ -f "$STATUS_DIR/wait/t_${pane_id}.wait" ]' || fail "window wait should cover $pane_id"
reset_waits

# ── wait: session target ────────────────────────────────────────────
run_bg bash "$REPO_DIR/scripts/wait-target.sh" "t" "S"
wait_prompt
type_reply "5"
wait_for '[ -f "$STATUS_DIR/wait/t.wait" ]' || fail "session wait should write t.wait"

echo "prompt template real-tmux checks passed"
