#!/usr/bin/env bash

# The Claude hook names the pane's window after the session's latest /rename,
# on SessionStart, UserPromptSubmit and Stop, overwriting a hand-set name
# unless @agent-status-window-name is off. A session never renamed leaves its
# window alone. Drives a real tmux server, with jq and with the sed fallback.
#
# Isolation: TMUX/TMUX_PANE are unset, HOME and TMUX_TMPDIR live in a temp
# dir, and every tmux call goes through a wrapper that pins -S to the temp
# socket, so nothing here can reach the user's own server.

set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REAL_TMUX=$(command -v tmux || true)
if [ -z "$REAL_TMUX" ]; then
    echo "claude hook window-name real-tmux checks skipped (needs tmux)"
    exit 0
fi

# Short base dir: tmux socket paths are limited to ~107 bytes.
TMP_DIR="$(mktemp -d /tmp/tas-winname.XXXXXX)"

cleanup() {
    (cd "$TMP_DIR" && "$REAL_TMUX" -S ./sock kill-server >/dev/null 2>&1) || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

export HOME="$TMP_DIR/home"
export TMUX_TMPDIR="$TMP_DIR"
mkdir -p "$HOME" "$TMP_DIR/bin" "$TMP_DIR/nojq"

cat > "$TMP_DIR/bin/tmux" <<EOF
#!/usr/bin/env bash
cd "$TMP_DIR" || exit 1
exec "$REAL_TMUX" -S ./sock "\$@"
EOF
chmod +x "$TMP_DIR/bin/tmux"
export PATH="$TMP_DIR/bin:$PATH"

# A PATH with only what the hook needs, and no jq, for the sed fallback.
ln -s "$TMP_DIR/bin/tmux" "$TMP_DIR/nojq/tmux"
for tool in bash cat mkdir rm touch sed grep tail hostname basename dirname; do
    tool_path=$(command -v "$tool" || true)
    [ -n "$tool_path" ] && ln -s "$tool_path" "$TMP_DIR/nojq/$tool"
done

fail() {
    echo "Assertion failed: $*" >&2
    exit 1
}

run_hook() {
    local hook_type="$1" pane_id="$2" transcript="$3" path="${4:-$PATH}"

    printf '{"session_id":"s","transcript_path":"%s","hook_event_name":"%s"}\n' \
        "$transcript" "$hook_type" | \
        env PATH="$path" TMUX="$TMP_DIR/sock,1,0" TMUX_PANE="$pane_id" \
        "$REPO_DIR/hooks/better-hook.sh" "$hook_type"
}

window_of() {
    tmux display-message -p -t "$1" '#{window_name}'
}

title() {
    printf '{"type":"custom-title","customTitle":"%s","sessionId":"s"}\n' "$1"
}

tmux -f /dev/null new-session -d -s t -n worktree-a 'sleep 600'
pane_a=$(tmux display-message -p -t t: '#{pane_id}')
pane_b=$(tmux new-window -d -P -F '#{pane_id}' -t t: -n plain 'sleep 600')
pane_c=$(tmux new-window -d -P -F '#{pane_id}' -t t: -n fresh 'sleep 600')
pane_d=$(tmux new-window -d -P -F '#{pane_id}' -t t: -n other 'sleep 600')

{ title first.name; echo '{"type":"user"}'; title committer; } > "$TMP_DIR/a.jsonl"
echo '{"type":"user"}' > "$TMP_DIR/b.jsonl"
# A resume into a new file opens with the name it carries over.
{ title zen.mode; echo '{"type":"mode","mode":"normal"}'; } > "$TMP_DIR/c.jsonl"
title -dash > "$TMP_DIR/d.jsonl"

# The latest /rename names the window, replacing its hand-set name.
run_hook UserPromptSubmit "$pane_a" "$TMP_DIR/a.jsonl"
[ "$(window_of "$pane_a")" = "committer" ] \
    || fail "UserPromptSubmit should name the window after the latest /rename (got: $(window_of "$pane_a"))"

# A window renamed by hand is overwritten on the next report.
tmux rename-window -t "$pane_a" manual
run_hook Stop "$pane_a" "$TMP_DIR/a.jsonl"
[ "$(window_of "$pane_a")" = "committer" ] \
    || fail "Stop should overwrite a hand-set window name (got: $(window_of "$pane_a"))"

# A session never renamed leaves its window alone.
run_hook UserPromptSubmit "$pane_b" "$TMP_DIR/b.jsonl"
[ "$(window_of "$pane_b")" = "plain" ] \
    || fail "an unrenamed session should keep its window name (got: $(window_of "$pane_b"))"

# SessionStart names the window on resume, without touching the agent state.
run_hook SessionStart "$pane_c" "$TMP_DIR/c.jsonl"
[ "$(window_of "$pane_c")" = "zen.mode" ] \
    || fail "SessionStart should name the window (got: $(window_of "$pane_c"))"
[ ! -e "$HOME/.cache/tmux-agent-status/panes/t_${pane_c}.status" ] \
    || fail "SessionStart should not set the pane's status"

# The sed fallback, with a name tmux could mistake for a flag.
run_hook Stop "$pane_d" "$TMP_DIR/d.jsonl" "$TMP_DIR/nojq"
[ "$(window_of "$pane_d")" = "-dash" ] \
    || fail "the sed fallback should name the window (got: $(window_of "$pane_d"))"

# Off: the window keeps its name, even after a fresh /rename.
tmux set-option -g @agent-status-window-name off
tmux rename-window -t "$pane_a" manual
title next.one >> "$TMP_DIR/a.jsonl"
run_hook UserPromptSubmit "$pane_a" "$TMP_DIR/a.jsonl"
[ "$(window_of "$pane_a")" = "manual" ] \
    || fail "with the option off the window should keep its name (got: $(window_of "$pane_a"))"

# Back on, the next report catches up.
tmux set-option -g @agent-status-window-name on
run_hook Stop "$pane_a" "$TMP_DIR/a.jsonl"
[ "$(window_of "$pane_a")" = "next.one" ] \
    || fail "with the option back on the window should follow /rename (got: $(window_of "$pane_a"))"

echo "claude hook window-name real-tmux checks passed"
