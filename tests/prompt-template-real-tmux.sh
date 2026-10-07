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
# The command log is how we see a prompt open (below), and every poll of it
# logs a show-messages of its own. Keep the log from rotating, or the
# command-prompt entries fall off the end and the count goes down.
tmux set-option -g message-limit 100000
# Root-table key used as a barrier on the client's command queue: see
# flush_client_queue.
tmux bind-key -n Q set-option -g @tas-flushed 1

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

# The scripts open their prompts with -b, so they return at once; the reply
# is typed afterwards. There is no format for "prompt open", so the server's
# command log stands in for it: command-prompt sets the prompt while it runs,
# so once it is logged, keys typed from here on reach the prompt.
prompts_seen=0

# A prompt opened without -b would block here; fail instead of hanging.
run_script() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 bash "$@" || true
    else
        bash "$@"
    fi
}

prompt_count() {
    tmux show-messages 2>/dev/null | grep -c 'command: command-prompt' || true
}

wait_prompt() {
    wait_for '[ "$(prompt_count)" -gt "$prompts_seen" ]' || fail "command-prompt did not open"
    prompts_seen=$(prompt_count)
}

# Wait until every command the attached client has queued so far - a prompt
# callback and the run-shell it starts, which blocks the queue until the
# script exits - has finished. Key bindings queue behind them on the same
# client queue, so the barrier key's command runs only after they are done.
flush_client_queue() {
    tmux set-option -gu @tas-flushed
    printf 'Q' >&3
    wait_for '[ "$(tmux show-option -gqv @tas-flushed)" = 1 ]' || fail "the client's command queue did not drain"
}

type_reply() {
    printf '%s\r' "$1" >&3
}

reset_waits() {
    rm -f "$STATUS_DIR/wait/"*.wait "$STATUS_DIR/panes/"*.status "$STATUS_DIR/"*.status
}

# ── pin: tag prompt ─────────────────────────────────────────────────
run_script "$REPO_DIR/scripts/pin-target.sh" "t:$pane_id"
wait_prompt
# Clear the prefilled tag, then type ours.
printf '\025' >&3
type_reply "abc"
wait_for '[ "$(tmux show-option -gqv @agent-pins)" = "abc:$pane_id:" ]' \
    || fail "pin should store abc:$pane_id: (got '$(tmux show-option -gqv @agent-pins)')"

# ── wait: pane target ───────────────────────────────────────────────
run_script "$REPO_DIR/scripts/wait-target.sh" "t:$pane_id" "P"
wait_prompt
type_reply "5"
flush_client_queue
[ -f "$STATUS_DIR/wait/t_${pane_id}.wait" ] \
    || fail "pane wait should write t_${pane_id}.wait (have: $(ls "$STATUS_DIR/wait" 2>/dev/null | tr '\n' ' '))"
[ "$(cat "$STATUS_DIR/panes/t_${pane_id}.status" 2>/dev/null)" = "wait" ] || fail "pane status should be wait"
reset_waits

# ── wait: window target ─────────────────────────────────────────────
run_script "$REPO_DIR/scripts/wait-target.sh" "t:w$win_idx" "P"
wait_prompt
type_reply "5"
flush_client_queue
[ -f "$STATUS_DIR/wait/t_${pane_id}.wait" ] || fail "window wait should cover $pane_id"
reset_waits

# ── wait: session target ────────────────────────────────────────────
run_script "$REPO_DIR/scripts/wait-target.sh" "t" "S"
wait_prompt
type_reply "5"
flush_client_queue
[ -f "$STATUS_DIR/wait/t.wait" ] || fail "session wait should write t.wait"
reset_waits

# ── pin and rename from inside the popup picker ─────────────────────
# The real flow, agents mode: m pins under the derived tag (or unpins) and
# the picker stays open; r runs pin-target.sh --rename through execute-silent
# and aborts, closing the popup. The prompt must survive the popup closing -
# without -b it is dropped.
if command -v fzf >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    STATE_DIR="$TMP_DIR/state"
    mkdir -p "$STATE_DIR" "$STATUS_DIR/panes"
    # Make the pane a listed agent so the 2s reloads keep its row.
    echo done > "$STATUS_DIR/panes/t_${pane_id}.status"
    echo claude > "$STATUS_DIR/panes/t_${pane_id}.agent"
    tmux set-option -gu @agent-pins
    client=$(tmux list-clients -F '#{client_name}' | head -n 1)
    derived=$(tmux display-message -p -t "$pane_id" '#{window_name}')
    derived="${derived:0:3}"

    open_picker() {
        printf 'agents' > "$STATE_DIR/mode"
        printf '1' > "$STATE_DIR/preview-hidden"
        bash "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --rows-agents > "$STATE_DIR/rows.seed"
        rm -f "$STATE_DIR/rows.refresh"
        grep -q "t:$pane_id" "$STATE_DIR/rows.seed" || fail "the agent pane should be listed in agents mode"
        tmux display-popup -c "$client" -E -w 60 -h 10 \
            "env TMUX_AGENT_SWITCHER_STATE_DIR='$STATE_DIR' '$REPO_DIR/scripts/hook-based-switcher.sh'" \
            > /dev/null 2>&1 &
        wait_for '[ -S "$STATE_DIR/fzf.sock" ]' || fail "the popup picker did not start"
        # The socket comes up before the rows load, and the agents-mode
        # refresher reloads once right away. A key pressed while a reload
        # streams in is dropped (--track blocks input until it finds the
        # tracked row), so wait for that first reload's rows to be built and
        # for fzf to sit idle on a row.
        wait_for '[ -f "$STATE_DIR/rows.refresh" ]' || fail "the picker's refresher never ran"
        wait_picker_idle
    }

    picker_state() {
        curl --silent --unix-socket "$STATE_DIR/fzf.sock" http://localhost 2>/dev/null
    }

    picker_current() {
        picker_state | sed -n 's/.*"current":{[^}]*"text":"\([^"]*\)".*/\1/p'
    }

    # Idle: not reading a reload, and on a row whose text matches $1 (any
    # row when omitted, or "!pattern" for a row that does not match).
    picker_idle_on() {
        local state current
        state=$(picker_state)
        [[ "$state" == *'"reading":false'* ]] || return 1
        current=$(sed -n 's/.*"current":{[^}]*"text":"\([^"]*\)".*/\1/p' <<< "$state")
        [ -n "$current" ] || return 1
        case "${1:-}" in
            "") return 0 ;;
            !*) [[ "$current" != *"${1#!}"* ]] ;;
            *) [[ "$current" == *"$1"* ]] ;;
        esac
    }

    wait_picker_idle() {
        # wait_for evals in its own frame, where $1 is the expression.
        idle_want="${1:-}"
        wait_for 'picker_idle_on "$idle_want"' \
            || fail "the picker did not settle on a row${1:+ matching $1} (current: $(picker_current))"
    }

    open_picker
    printf 'm' >&3
    wait_for '[ "$(tmux show-option -gqv @agent-pins)" = "$derived:$pane_id:" ]' \
        || fail "m should pin under the derived tag $derived (got '$(tmux show-option -gqv @agent-pins)')"
    [ -S "$STATE_DIR/fzf.sock" ] || fail "the picker should stay open after m"
    # The reload after m must land before the next key, or fzf drops it.
    wait_picker_idle "  $derived "
    printf 'm' >&3
    wait_for '[ -z "$(tmux show-option -gqv @agent-pins)" ]' || fail "m on a pinned row should unpin it"
    [ -S "$STATE_DIR/fzf.sock" ] || fail "the picker should stay open after unpinning"
    wait_picker_idle "!  $derived "

    printf 'r' >&3
    wait_prompt
    wait_for '[ ! -S "$STATE_DIR/fzf.sock" ]' || fail "the picker should close after r"
    printf '\025' >&3
    type_reply "xyz"
    wait_for '[ "$(tmux show-option -gqv @agent-pins)" = "xyz:$pane_id:" ]' \
        || fail "r should pin under the typed tag (got '$(tmux show-option -gqv @agent-pins)')"

    # An empty reply leaves the pin alone.
    open_picker
    printf 'r' >&3
    wait_prompt
    wait_for '[ ! -S "$STATE_DIR/fzf.sock" ]' || fail "the picker should close after r"
    printf '\025' >&3
    type_reply ""
    flush_client_queue
    [ "$(tmux show-option -gqv @agent-pins)" = "xyz:$pane_id:" ] \
        || fail "an empty rename should leave the pin alone (got '$(tmux show-option -gqv @agent-pins)')"
else
    echo "(popup picker check skipped: needs fzf and curl)"
fi

echo "prompt template real-tmux checks passed"
