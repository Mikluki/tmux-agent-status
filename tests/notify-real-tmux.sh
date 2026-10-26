#!/usr/bin/env bash

# n in the picker turns on a desktop notification for an agent's pane: when
# that agent goes from working to done, the collector sends one whose only
# text is the Claude session's /rename name, or the tmux session name when it
# has none, then " — done". An agent without the flag finishes silently, and n again turns it
# off.
#
# notify-send is a fake on PATH that appends its arguments to a log.
#
# Isolation: TMUX/TMUX_PANE are unset, HOME and TMUX_TMPDIR live in a temp
# dir, every tmux call goes through a wrapper that pins -S to the temp socket,
# and the collector started here is killed by pid.

set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REAL_TMUX=$(command -v tmux || true)
if [ -z "$REAL_TMUX" ]; then
    echo "notify real-tmux checks skipped (needs tmux)"
    exit 0
fi

# Short base dir: tmux socket paths are limited to ~107 bytes.
TMP_DIR="$(mktemp -d /tmp/tas-notify.XXXXXX)"
COLLECTOR_PID=""

cleanup() {
    [ -n "$COLLECTOR_PID" ] && kill "$COLLECTOR_PID" 2>/dev/null || true
    (cd "$TMP_DIR" && "$REAL_TMUX" -S ./sock kill-server >/dev/null 2>&1) || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

export HOME="$TMP_DIR/home"
export TMUX_TMPDIR="$TMP_DIR"
mkdir -p "$HOME" "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/tmux" <<EOF
#!/usr/bin/env bash
cd "$TMP_DIR" || exit 1
exec "$REAL_TMUX" -S ./sock "\$@"
EOF
NOTIFY_LOG="$TMP_DIR/notify.log"
cat > "$TMP_DIR/bin/notify-send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP_DIR/bin/tmux" "$TMP_DIR/bin/notify-send"
export PATH="$TMP_DIR/bin:$PATH"
: > "$NOTIFY_LOG"

STATUS_DIR="$HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$PANE_DIR" "$STATE_DIR"

fail() {
    echo "Assertion failed: $*" >&2
    echo "notify log:" >&2
    cat "$NOTIFY_LOG" >&2
    exit 1
}

# wait_for <expr> [timeout seconds]
wait_for() {
    local deadline=$(( SECONDS + ${2:-10} ))
    while (( SECONDS < deadline )); do
        if eval "$1"; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Two agents in one session, each in its own window. sleep is not a bare
# shell, so the collector keeps their markers.
tmux -f /dev/null new-session -d -s proj -n api -x 120 -y 20 'sleep 600'
tmux set-option -g exit-empty off
tmux new-window -d -t proj: -n web 'sleep 600'
loud=$(tmux display-message -p -t proj:api '#{pane_id}')
quiet=$(tmux display-message -p -t proj:web '#{pane_id}')

set_state() {
    echo "$2" > "$PANE_DIR/proj_$1.status"
    echo claude > "$PANE_DIR/proj_$1.agent"
    bash -c "source '$REPO_DIR/scripts/lib/session-status.sh'; source '$REPO_DIR/scripts/lib/sidebar-clients.sh'; wake_collector"
}

plain_rows() {
    bash "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --rows-agents \
        | sed 's/\x1b\[[0-9;]*m//g'
}

# The api agent's Claude session was renamed twice; the latest name counts.
# The hook records the transcript path in @agent-transcript.
transcript="$TMP_DIR/session.jsonl"
printf '%s\n' '{"type":"custom-title","customTitle":"old.name"}' \
    '{"type":"user"}' '{"type":"custom-title","customTitle":"0037.run"}' > "$transcript"
tmux set-option -pq -t "$loud" @agent-transcript "$transcript"

set_state "$loud" working
set_state "$quiet" working

# n on the api agent: the flag is set and its row is marked.
bash "$REPO_DIR/scripts/notify-target.sh" --toggle "proj:$loud"
[ "$(tmux show-option -pqv -t "$loud" @agent-notify)" = "on" ] || fail "n should set @agent-notify on the pane"
[ -z "$(tmux show-option -pqv -t "$quiet" @agent-notify)" ] || fail "n should touch only the selected pane"
plain_rows | grep -Fq "⣾• " || fail "the notifying row should carry a •: $(plain_rows)"
[ "$(plain_rows | grep -c '•')" = "1" ] || fail "only the notifying row should carry a •"

bash "$REPO_DIR/scripts/sidebar-collector.sh" > /dev/null 2>&1 &
COLLECTOR_PID=$!
wait_for '[ -s "$STATUS_DIR/.status-line-counts" ]' || fail "collector never published"

# Both agents finish. Only the flagged one notifies, with its Claude name.
set_state "$loud" done
set_state "$quiet" done
wait_for '[ -s "$NOTIFY_LOG" ]' || fail "finishing a notifying agent should send a notification"
sleep 1
[ "$(wc -l < "$NOTIFY_LOG")" = "1" ] || fail "exactly one notification should be sent"
grep -Fxq -- "-a tmux-agent-status -- 0037.run — done" "$NOTIFY_LOG" \
    || fail "the notification should carry only the Claude session's latest /rename name"

# Staying done is not a new finish.
set_state "$loud" done
sleep 1
[ "$(wc -l < "$NOTIFY_LOG")" = "1" ] || fail "a done agent should not notify again"

# Another turn notifies again: the flag lasts until n turns it off. Without
# a /rename name it falls back to the tmux session name.
tmux set-option -pqu -t "$loud" @agent-transcript
set_state "$loud" working
sleep 1.2
set_state "$loud" done
wait_for '[ "$(wc -l < "$NOTIFY_LOG")" = "2" ]' || fail "the flag should last across turns"
[ "$(tail -n1 "$NOTIFY_LOG")" = "-a tmux-agent-status -- proj — done" ] \
    || fail "an unnamed session should notify with the tmux session name"

# n again turns it off.
bash "$REPO_DIR/scripts/notify-target.sh" --toggle "proj:$loud"
[ -z "$(tmux show-option -pqv -t "$loud" @agent-notify)" ] || fail "n again should clear @agent-notify"
plain_rows | grep -q '•' && fail "no row should carry a • once notifications are off"
set_state "$loud" working
sleep 1.2
set_state "$loud" done
sleep 1.2
[ "$(wc -l < "$NOTIFY_LOG")" = "2" ] || fail "an agent with notifications off should finish silently"

echo "notify real-tmux checks passed"
