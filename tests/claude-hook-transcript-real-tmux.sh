#!/usr/bin/env bash

# The Claude hook records the pane's transcript in the pane option
# @agent-transcript, and pin-target.sh names a pin after the latest /rename
# found there. Drives a real tmux server so the set-option -p and the
# #{@agent-transcript} format are tmux's own, with jq and with the sed
# fallback.
#
# Isolation: TMUX/TMUX_PANE are unset, HOME and TMUX_TMPDIR live in a temp
# dir, and every tmux call goes through a wrapper that pins -S to the temp
# socket, so nothing here can reach the user's own server.

set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REAL_TMUX=$(command -v tmux || true)
if [ -z "$REAL_TMUX" ]; then
    echo "claude hook transcript real-tmux checks skipped (needs tmux)"
    exit 0
fi

# Short base dir: tmux socket paths are limited to ~107 bytes.
TMP_DIR="$(mktemp -d /tmp/tas-transcript.XXXXXX)"

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
for tool in bash cat mkdir rm touch sed hostname basename dirname; do
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

transcript_of() {
    tmux display-message -p -t "$1" '#{@agent-transcript}'
}

tmux -f /dev/null new-session -d -s t -n worktree-a 'sleep 600'
pane_a=$(tmux display-message -p -t t: '#{pane_id}')
pane_b=$(tmux split-window -d -P -F '#{pane_id}' -t t: 'sleep 600')

cat > "$TMP_DIR/a.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"first.name","sessionId":"s"}
{"type":"custom-title","customTitle":"committer","sessionId":"s"}
EOF
echo '{"type":"user"}' > "$TMP_DIR/b.jsonl"

if command -v jq >/dev/null 2>&1; then
    run_hook UserPromptSubmit "$pane_a" "$TMP_DIR/a.jsonl"
    [ "$(transcript_of "$pane_a")" = "$TMP_DIR/a.jsonl" ] \
        || fail "UserPromptSubmit should record the transcript on its pane (jq)"
    tmux set-option -pu -t "$pane_a" @agent-transcript
fi

run_hook Stop "$pane_a" "$TMP_DIR/a.jsonl" "$TMP_DIR/nojq"
[ "$(transcript_of "$pane_a")" = "$TMP_DIR/a.jsonl" ] \
    || fail "Stop should record the transcript on its pane (sed fallback)"
[ -z "$(transcript_of "$pane_b")" ] || fail "the transcript should not leak to another pane"

run_hook UserPromptSubmit "$pane_b" "$TMP_DIR/b.jsonl"
[ "$(transcript_of "$pane_b")" = "$TMP_DIR/b.jsonl" ] \
    || fail "the second pane should record its own transcript"

bash "$REPO_DIR/scripts/pin-target.sh" --toggle "t:$pane_a"
bash "$REPO_DIR/scripts/pin-target.sh" --toggle "t:$pane_b"
pins=$(tmux show-option -gqv @agent-pins)
[ "$pins" = "commi:$pane_a: wor:$pane_b:" ] \
    || fail "pins should take the latest /rename name, else the window name (got: $pins)"

echo "claude hook transcript real-tmux checks passed"
