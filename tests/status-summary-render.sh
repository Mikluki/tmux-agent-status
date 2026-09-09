#!/usr/bin/env bash
# render_status_summary: the status bar is a watchlist. Only pinned agents
# appear, in pin order, and everything unpinned collapses into one "·N"
# counter that turns green when one of them wants attention.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

# Minimal global-option store, so the pin library has a tmux to live in.
cat > "$FAKE_BIN/tmux" <<'TMUX_EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    show-option)
        [ -f "${TMUX_FAKE_OPTIONS:?}" ] && cat "$TMUX_FAKE_OPTIONS"
        ;;
    set-option)
        if [ "${2:-}" = "-gu" ]; then
            : > "${TMUX_FAKE_OPTIONS:?}"
        else
            printf '%s\n' "${4:-}" > "${TMUX_FAKE_OPTIONS:?}"
        fi
        ;;
esac
exit 0
TMUX_EOF
chmod +x "$FAKE_BIN/tmux"

export PATH="$FAKE_BIN:$PATH"
export TMUX_FAKE_OPTIONS="$TMP_DIR/options"
: > "$TMUX_FAKE_OPTIONS"

# shellcheck source=../scripts/lib/status-summary.sh
source "$REPO_DIR/scripts/lib/status-summary.sh"

tab=$'\t'

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

assert_eq "" "$(render_status_summary)" "no agents should render an empty summary"

assert_eq "#[fg=colour244]·2#[default]" \
    "$(render_status_summary "%1${tab}working" "%2${tab}wait")" \
    "unpinned agents should collapse into a dim overflow count"

assert_eq "#[fg=green]·2#[default]" \
    "$(render_status_summary "%1${tab}working" "%2${tab}done")" \
    "the overflow count should turn green when an unpinned agent finished"

assert_eq "#[fg=green]·2#[default]" \
    "$(render_status_summary "%1${tab}working" "%2${tab}ask")" \
    "the overflow count should turn green when an unpinned agent is asking"

pin_set "%1" "bug"
pin_set "%2" "rfc"
pin_set "%3" "perf"

watchlist="$(render_status_summary \
    "%1${tab}working" "%2${tab}done" "%3${tab}ask" "%4${tab}working" "%5${tab}done")"
assert_eq \
"#[fg=yellow,bold]bug#[default]  #[fg=green]rfc✓#[default]  #[fg=magenta,bold]perf?#[default]   #[fg=green]·2#[default]" \
    "$watchlist" "pinned agents should render as tags in pin order, with the rest counted"

assert_eq "$watchlist" "$(render_status_summary \
    "%1${tab}working" "%2${tab}done" "%3${tab}ask" "%4${tab}working" "%5${tab}done")" \
    "an unchanged watchlist should render identically on every call"

# %1 is still alive and waiting; %2 and %3 are gone. %2 finished before it
# vanished so its pin goes with it, while %3 was still asking, so its tag is
# held in dim grey until it is unpinned by hand.
assert_eq \
"#[fg=cyan,dim]bug#[default]  #[fg=colour244]perf#[default]" \
    "$(render_status_summary "%1${tab}wait")" \
    "a dead pin should be dropped when it finished and held dim otherwise"

assert_eq "bug	perf" "$(pins_read | cut -f1 | paste -sd '\t' -)" \
    "the store should keep only the pins that survived"

# The watchlist keeps pin order rather than re-sorting by state: where a tag
# sits is part of how it is read.
pin_set "%9" "zzz"
assert_eq \
"#[fg=cyan,dim]bug#[default]  #[fg=colour244]perf#[default]  #[fg=yellow,bold]zzz#[default]" \
    "$(render_status_summary "%1${tab}wait" "%9${tab}working")" \
    "a newly pinned agent should append rather than re-sort the watchlist"

echo "status summary render checks passed"
