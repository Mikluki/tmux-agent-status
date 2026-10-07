#!/usr/bin/env bash
# The agents view carries two extra columns: the pin tag (blank when
# unpinned, so it doubles as the pin indicator) and the age of the current
# state. Row order must stay exactly what it was before the columns existed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
STATE_DIR="$TMP_DIR/state"
BASELINE_DIR="$TMP_DIR/baseline"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR" "$STATE_DIR" "$BASELINE_DIR"

tab=$'\t'
cat > "$FAKE_BIN/tmux" <<TMUX_EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    list-sessions)
        printf '%s\n' api web ml
        ;;
    list-panes)
        printf 'api${tab}%%12${tab}1${tab}worktree-a${tab}node${tab}\n'
        printf 'api${tab}%%14${tab}2${tab}worktree-b${tab}node${tab}\n'
        printf 'web${tab}%%3${tab}0${tab}web${tab}node${tab}\n'
        printf 'ml${tab}%%22${tab}1${tab}train${tab}python${tab}\n'
        ;;
    show-option)
        [ -f "\${TMUX_FAKE_OPTIONS:?}" ] && cat "\$TMUX_FAKE_OPTIONS"
        ;;
    set-option)
        if [ "\${2:-}" = "-gu" ]; then
            : > "\${TMUX_FAKE_OPTIONS:?}"
        else
            printf '%s\n' "\${4:-}" > "\${TMUX_FAKE_OPTIONS:?}"
        fi
        ;;
esac
exit 0
TMUX_EOF
chmod +x "$FAKE_BIN/tmux"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TEST_HOME"
export TMUX_FAKE_OPTIONS="$TMP_DIR/options"
: > "$TMUX_FAKE_OPTIONS"

echo "working" > "$PANE_DIR/api_%12.status"
echo "claude"  > "$PANE_DIR/api_%12.agent"
echo "done"    > "$PANE_DIR/api_%14.status"
echo "ask"     > "$PANE_DIR/web_%3.status"
echo "wait"    > "$PANE_DIR/ml_%22.status"
# Hooks write an .agent marker for every agent pane; the agents view lists
# only panes that actually run an agent.
for pane in api_%14 web_%3 ml_%22; do echo "claude" > "$PANE_DIR/${pane}.agent"; done

# Age comes from the status file's mtime, with no extra bookkeeping.
touch -d "@$(( $(date +%s) - 240 ))" "$PANE_DIR/api_%12.status"

rows() {
    "$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --rows-agents
}

# Columns are easier to assert on without the colour escapes.
plain_rows() {
    rows | sed 's/\x1b\[[0-9;]*m//g'
}

fail() {
    echo "Assertion failed: $1" >&2
    plain_rows >&2
    exit 1
}

"$REPO_DIR/scripts/pin-target.sh" --apply "%12" "bug" >/dev/null 2>&1

plain_rows | grep -Fq '⣾  bug   working  4m    api  worktree-a' \
    || fail "a pinned row should show its tag and the age of its state"
plain_rows | grep -Fq '?        ask      ' \
    || fail "an unpinned row should leave the tag column blank"
plain_rows | grep -Eq '⏸ +wait +[0-9]+s +ml +' \
    || fail "every agent pane should still be listed, with its age"

# Order is the existing priority sort — ask, done, working, wait — and it must
# match what the switcher produced before the columns were added.
order="$(rows | cut -f2 | paste -sd ' ' -)"
[ "$order" = "web:%3 api:%14 api:%12 ml:%22" ] || fail "rows should keep the ask/done/working/wait priority order"

ln -s "$REPO_DIR/scripts/lib" "$BASELINE_DIR/lib"
git -C "$REPO_DIR" show a323f10:scripts/hook-based-switcher.sh > "$BASELINE_DIR/hook-based-switcher.sh"
baseline_order="$(bash "$BASELINE_DIR/hook-based-switcher.sh" --state-dir "$STATE_DIR" --rows-agents | cut -f2 | paste -sd ' ' -)"
[ "$order" = "$baseline_order" ] || {
    echo "Assertion failed: row order should be unchanged from a323f10" >&2
    echo "Now:      $order" >&2
    echo "Baseline: $baseline_order" >&2
    exit 1
}

# --rows is what every reload runs. In agents mode it must emit the agents
# rows, never fall back to the tree's session rows.
"$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --set-mode agents
mode_rows="$("$REPO_DIR/scripts/hook-based-switcher.sh" --state-dir "$STATE_DIR" --rows)"
# Targets only: the age column can tick over between the two listings.
[ "$(cut -f1,2 <<< "$mode_rows")" = "$(rows | cut -f1,2)" ] || fail "--rows in agents mode should emit the agents rows"
printf '%s\n' "$mode_rows" | grep -Fq "[session]" && fail "--rows in agents mode should not emit tree session rows"

echo "switcher agents column checks passed"
