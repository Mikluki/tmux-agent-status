#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
LOG_FILE="$TMP_DIR/tmux.log"

mkdir -p "$FAKE_BIN" "$STATUS_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "tmux-called" >> "${TMUX_LOG:?}"
exit 99
EOF
chmod +x "$FAKE_BIN/tmux"

sleep 30 &
collector_pid="$!"
trap 'kill "$collector_pid" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT

printf '%s\n' "$collector_pid" > "$STATUS_DIR/.sidebar-collector.pid"

run_status_line() {
    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    TMUX_LOG="$LOG_FILE" \
    "$REPO_DIR/scripts/status-line.sh"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

# The cache is a single pre-rendered line: nothing on the bar depends on the
# clock, so there is no frame to pick.
printf '%s\n' "#[fg=green,bold]cached summary#[default]" > "$STATUS_DIR/.status-line"
assert_eq "#[fg=green,bold]cached summary#[default]" "$(run_status_line)" "the cache line should render as-is"
assert_eq "$(run_status_line)" "$(run_status_line)" "consecutive reads of an unchanged cache should be identical"

# Legacy two-line cache left behind by an older collector: the first line is
# a complete summary, so it renders until the collector republishes.
printf '%s\n%s\n' "stale frame zero" "stale frame one" > "$STATUS_DIR/.status-line"
assert_eq "stale frame zero" "$(run_status_line)" "a stale multi-line cache should render its first line"

if [ -f "$LOG_FILE" ]; then
    echo "status-line should not invoke tmux when collector cache is live" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "status-line cache regression checks passed"
