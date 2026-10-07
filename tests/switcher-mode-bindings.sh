#!/usr/bin/env bash
# The picker is modal. It opens in normal mode (prompt "› "), where letters
# act on the selected row and nothing types into the query; i or / enters
# insert mode (prompt "/ "), where letters type; esc returns to normal with
# the query kept, and esc in normal quits. The ctrl binds work in both.
#
# Part one captures the fzf argv through a fake fzf. Part two, when real tmux
# and fzf are installed, drives the actual picker on an isolated tmux server.
set -euo pipefail

unset TMUX TMUX_PANE

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="$REPO_DIR/scripts/hook-based-switcher.sh"
TMP_DIR="$(mktemp -d /tmp/tas-modes.XXXXXX)"
REAL_TMUX=$(command -v tmux || true)
REAL_FZF=$(command -v fzf || true)

cleanup() {
    if [ -n "$REAL_TMUX" ]; then
        (cd "$TMP_DIR" && "$REAL_TMUX" -S ./sock kill-server >/dev/null 2>&1) || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

fail() {
    echo "Assertion failed: $1" >&2
    exit 1
}

export HOME="$TMP_DIR/home"
export TMUX_TMPDIR="$TMP_DIR"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$HOME" "$STATE_DIR" "$TMP_DIR/fake" "$TMP_DIR/real"

seed_rows() {
    printf 'tree' > "$STATE_DIR/mode"
    printf 'P\tt:%%1\tapple\nP\tt:%%2\tbanana\nP\tt:%%3\tavocado\n' > "$STATE_DIR/rows.seed"
}

# ── Part one: fzf argv ─────────────────────────────────────────────
cat > "$TMP_DIR/fake/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP_DIR/fake/fzf" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP_DIR/fzf.args"
cat > /dev/null
EOF
chmod +x "$TMP_DIR/fake/tmux" "$TMP_DIR/fake/fzf"

seed_rows
PATH="$TMP_DIR/fake:$PATH" TMUX_AGENT_SWITCHER_STATE_DIR="$STATE_DIR" bash "$SCRIPT_FILE"
ARGS="$TMP_DIR/fzf.args"

has_arg() {
    grep -Fxq -- "$1" "$ARGS"
}

bind_value() {
    # The value of a single-key --bind, e.g. bind_value ctrl-w
    sed -n "s/^--bind=$1://p" "$ARGS" | head -n 1
}

has_arg "--prompt=› " || fail "the picker should open in normal mode with the › prompt"
has_arg "--highlight-line" || fail "the selected row should be highlighted across its full width"
grep -q -- '^--color' "$ARGS" && fail "an unset @agent-switcher-colors should add no --color"
grep -Fq -- "--header=" "$ARGS" && grep -Fq "i search  m pin  r rename  p preview  x close  q quit" "$ARGS" \
    || fail "the opening header should be the normal-mode hint"

normal_line=$(grep -- '^--bind=j:down,k:up,' "$ARGS" || true)
[ -n "$normal_line" ] || fail "normal mode should bind j/k to move"

for pair in "i:unbind(" "/:unbind(" "q:abort" \
            "m:$(bind_value tab)" "r:$(bind_value ctrl-r)" "p:$(bind_value ctrl-p)" "x:$(bind_value ctrl-x)"; do
    case "$normal_line" in
        *",$pair"*) ;;
        *) fail "normal mode should bind $pair" ;;
    esac
done
case "$normal_line" in
    *",a:ignore"*",z:ignore"*",space:ignore"*) ;;
    *) fail "unused letters should be swallowed in normal mode" ;;
esac
case "$normal_line" in
    *",w:ignore"*) ;;
    *) fail "w should be inert in normal mode now that wait is off the picker" ;;
esac
case "$normal_line" in
    *"change-prompt(/ )"*"change-header("*"esc normal  C-i pin  C-r rename  C-p preview  C-x close"*) ;;
    *) fail "entering insert mode should switch the prompt and header" ;;
esac

# The ctrl binds stay bound in both modes.
for key in tab ctrl-r ctrl-p ctrl-f ctrl-x; do
    [ -n "$(bind_value "$key")" ] || fail "$key should stay bound"
done
[ -z "$(bind_value ctrl-w)" ] || fail "ctrl-w should no longer be bound in the picker"
has_arg "--bind=ctrl-j:down,ctrl-k:up" || fail "ctrl-j/k should move in both modes"
case "$(bind_value esc)" in
    *--esc-action*) ;;
    *) fail "esc should route through the mode-aware transform" ;;
esac

# esc: insert -> normal (rebind, › prompt, normal hint); normal -> quit.
esc_insert=$(FZF_PROMPT='/ ' bash "$SCRIPT_FILE" --esc-action)
case "$esc_insert" in
    rebind\(*"change-prompt(› )"*"i search"*) ;;
    *) fail "esc in insert mode should return to normal: $esc_insert" ;;
esac
case "$esc_insert" in
    *clear-query*|*change-query*) fail "esc in insert mode should keep the query" ;;
esac
[ "$(FZF_PROMPT='› ' bash "$SCRIPT_FILE" --esc-action)" = "abort" ] \
    || fail "esc in normal mode should quit"

# @agent-switcher-colors reaches fzf as one --color, as tmux expanded it.
cat > "$TMP_DIR/fake/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = display-message ] && [ "$3" = '#{E:@agent-switcher-colors}' ]; then
    echo 'bg+:#112233,fg+:#445566:bold,pointer:#778899,gutter:-1'
fi
exit 0
EOF
seed_rows
PATH="$TMP_DIR/fake:$PATH" TMUX_AGENT_SWITCHER_STATE_DIR="$STATE_DIR" bash "$SCRIPT_FILE"
has_arg "--color=bg+:#112233,fg+:#445566:bold,pointer:#778899,gutter:-1" \
    || fail "@agent-switcher-colors should be passed to fzf as --color"

# ── Part two: the real picker ──────────────────────────────────────
if [ -z "$REAL_TMUX" ] || [ -z "$REAL_FZF" ]; then
    echo "switcher mode binding checks passed (real fzf drive skipped: needs tmux and fzf)"
    exit 0
fi

cat > "$TMP_DIR/real/tmux" <<EOF
#!/usr/bin/env bash
cd "$TMP_DIR" || exit 1
exec "$REAL_TMUX" -S ./sock "\$@"
EOF
chmod +x "$TMP_DIR/real/tmux"
export PATH="$TMP_DIR/real:$PATH"

seed_rows
cp "$STATE_DIR/rows.seed" "$TMP_DIR/rows"
cat > "$TMP_DIR/tmux.conf" <<'EOF'
set -g @base02 '#112233'
set -g @agent-switcher-colors 'bg+:#{@base02},gutter:-1'
EOF
tmux -f "$TMP_DIR/tmux.conf" new-session -d -s t -x 80 -y 12 \
    "env TMUX_AGENT_SWITCHER_STATE_DIR='$STATE_DIR' bash '$SCRIPT_FILE'; echo PICKER-EXITED; sleep 600"

screen() {
    tmux capture-pane -p -t t
}

expect_screen() {
    local pattern="$1" message="$2" i
    for i in $(seq 1 30); do
        screen | grep -Eq -- "$pattern" && return 0
        sleep 0.1
    done
    screen >&2
    fail "$message"
}

reject_screen() {
    local pattern="$1" message="$2"
    sleep 0.3
    if screen | grep -Eq -- "$pattern"; then
        screen >&2
        fail "$message"
    fi
}

expect_screen '^› *$' "the picker should open in normal mode with an empty › prompt"
expect_screen 'i search  m pin' "normal mode should show the normal hint"
expect_screen 'avocado' "the seeded rows should be listed"
ps -eo args= | grep -F -- "--listen=$STATE_DIR/fzf.sock" | grep -Fq -- "--color=bg+:#112233,gutter:-1" \
    || fail "the tmux formats in @agent-switcher-colors should be expanded at launch"

tmux send-keys -t t a z w
reject_screen '^› .*[azw]' "letters should not type into the query in normal mode"
expect_screen 'avocado' "w should not act on the picker"

tmux send-keys -t t j
expect_screen '^▌ banana|^> banana' "j should move down in normal mode"

tmux send-keys -t t i
expect_screen '^/ *$' "i should enter insert mode with the / prompt"
expect_screen 'esc normal  C-i pin' "insert mode should show the insert hint"

tmux send-keys -t t a v
expect_screen '^/ av' "letters should type in insert mode"
reject_screen 'banana' "typing should filter in insert mode"

tmux send-keys -t t Escape
expect_screen '^› av' "esc should return to normal mode keeping the query"
expect_screen 'i search  m pin' "esc should restore the normal hint"
reject_screen 'banana' "the filtered list should survive the return to normal mode"

# Agents mode reloads the rows every 2s; the filter must outlive a reload.
if command -v curl >/dev/null 2>&1; then
    curl --silent --unix-socket "$STATE_DIR/fzf.sock" -X POST http://localhost \
        -d "reload(cat '$TMP_DIR/rows')" >/dev/null || fail "could not reach the picker's listen socket"
    sleep 0.5
    expect_screen '^› av' "a reload should keep the query"
    expect_screen 'avocado' "a reload should keep the matching rows"
    reject_screen 'banana' "a reload in normal mode should keep the list filtered"
fi

tmux send-keys -t t /
expect_screen '^/ av' "/ should also enter insert mode"
tmux send-keys -t t Escape
expect_screen '^› av' "esc should return to normal mode again"

tmux send-keys -t t Escape
expect_screen 'PICKER-EXITED' "esc in normal mode should quit the picker"

echo "switcher mode binding checks passed"
