#!/usr/bin/env bash

# Quitting an agent but keeping its pane used to leave the hook-written
# .agent/.status markers behind forever, so the pane kept showing up as a
# phantom agent row wearing its last status. collect_data now retires those
# markers, without touching panes whose agent is merely unrecognised.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
CACHE_DIR="$TEST_HOME/.cache/tmux-agent-status"
TEST_PANE_DIR="$CACHE_DIR/panes"

mkdir -p "$FAKE_BIN" "$TEST_PANE_DIR"

# repo:  %1 bare shell (agent quit), %2 running claude, %3 nvim (foreground is
#        not a shell, so an unrecognised agent could still be in there)
# gone:  %4 bare shell, the session's only agent pane
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
    list-sessions)
        exit 0
        ;;
    list-windows)
        echo 1
        ;;
    list-panes)
        if [ "${2:-}" = "-a" ]; then
            cat <<'OUT'
repo	%1	/home/test/repo	100	1	zsh	zsh
repo	%2	/home/test/repo	200	1	zsh	claude
repo	%3	/home/test/repo	300	1	zsh	nvim
gone	%4	/home/test/gone	400	1	zsh	zsh
OUT
        else
            case "${3:-}" in
                repo*) printf '%s\n' %1 %2 %3 ;;
                gone*) printf '%s\n' %4 ;;
            esac
        fi
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash

case "${2:-}" in
    pid=,ppid=)
        cat <<'OUT'
100 1
200 1
201 200
300 1
400 1
OUT
        ;;
    pid=,args=)
        cat <<'OUT'
100 -zsh
200 -zsh
201 claude
300 nvim
400 -zsh
OUT
        ;;
    pid=,ppid=,args=)
        cat <<'OUT'
100 1 -zsh
200 1 -zsh
201 200 claude
300 1 nvim
400 1 -zsh
OUT
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/ps"

fail() {
    echo "Assertion failed: $1" >&2
    echo "--- panes/ ---" >&2
    ls -1 "$TEST_PANE_DIR" >&2
    echo "--- status files ---" >&2
    ls -1 "$CACHE_DIR" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "$2"
}

assert_no_file() {
    [ -e "$1" ] && fail "$2"
    return 0
}

seed_state() {
    rm -rf "$TEST_PANE_DIR"
    mkdir -p "$TEST_PANE_DIR"
    local pane
    for pane in repo_%1 repo_%3 gone_%4; do
        echo "claude" > "$TEST_PANE_DIR/${pane}.agent"
        echo "done" > "$TEST_PANE_DIR/${pane}.status"
    done
    echo "claude" > "$TEST_PANE_DIR/repo_%2.agent"
    echo "working" > "$TEST_PANE_DIR/repo_%2.status"
    echo "working" > "$CACHE_DIR/repo.status"
    echo "done" > "$CACHE_DIR/gone.status"
}

export PATH="$FAKE_BIN:$PATH"
export HOME="$TEST_HOME"

# shellcheck source=../scripts/lib/session-status.sh
source "$REPO_DIR/scripts/lib/session-status.sh"
# shellcheck source=../scripts/lib/collect.sh
source "$REPO_DIR/scripts/lib/collect.sh"

declare -A KNOWN_AGENTS=()
declare -A LIVE_PANES=()
declare -A PID_PPID=()
declare -A PANE_COUNTS=()
ENTRIES=()
SEL_NAMES=()
SEL_TYPES=()
SESS_START=0
_COLLECT_TICK=0
_LAST_STATUS_MTIME=""
_COLLECT_CHANGED=0

cycle() {
    # Cheap change detection would skip the rebuild when nothing on disk moved;
    # the tick counter forces one periodically in the daemon, so do the same.
    _LAST_STATUS_MTIME=""
    collect_data
}

seed_state

cycle
assert_file "$TEST_PANE_DIR/repo_%1.agent" \
    "a single agent-less cycle must not retire a marker (debounce)"
assert_file "$CACHE_DIR/gone.status" \
    "session status must survive the first agent-less cycle"

cycle
assert_no_file "$TEST_PANE_DIR/repo_%1.agent" \
    "marker for a live pane whose agent exited should be retired"
assert_no_file "$TEST_PANE_DIR/repo_%1.status" \
    "stale pane status should be retired with its marker"
assert_file "$TEST_PANE_DIR/repo_%2.agent" \
    "pane with a running claude process must keep its marker"
assert_file "$TEST_PANE_DIR/repo_%2.status" \
    "pane with a running claude process must keep its status"
assert_file "$TEST_PANE_DIR/repo_%3.agent" \
    "pane whose foreground is not a shell must keep its marker"
assert_no_file "$TEST_PANE_DIR/gone_%4.agent" \
    "marker in a single-agent session should be retired too"
assert_no_file "$CACHE_DIR/gone.status" \
    "session status should be dropped once its last agent marker is retired"
assert_file "$CACHE_DIR/repo.status" \
    "session with agents left must keep its session status"

echo "collect stale agent marker regression checks passed"
