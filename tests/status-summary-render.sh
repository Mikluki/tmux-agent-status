#!/usr/bin/env bash
# render_status_summary: the status bar is a watchlist. Only pinned agents
# appear, in pin order, and everything unpinned collapses into one "·N"
# counter that takes the ask colour when one of them is asking. Colours come
# from @agent-status-color-* (tmux formats allowed) with fixed defaults.
set -euo pipefail

unset TMUX TMUX_PANE

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
    display-message)
        # The expanded @agent-status-color-* line, when a test sets one.
        [ -f "${TMUX_FAKE_COLORS:?}" ] && cat "$TMUX_FAKE_COLORS"
        ;;
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
export TMUX_FAKE_COLORS="$TMP_DIR/colors"
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

assert_eq "#[fg=brightblack]·2#[default]" \
    "$(render_status_summary "%1${tab}working" "%2${tab}wait")" \
    "unpinned agents should collapse into a dim overflow count"

# Done is the resting state, so a finished unpinned agent must not light the
# counter: with many agents something unpinned is always done.
assert_eq "#[fg=brightblack]·3#[default]" \
    "$(render_status_summary "%1${tab}done" "%2${tab}done" "%3${tab}done")" \
    "the overflow count should stay grey when unpinned agents are only done"

assert_eq "#[fg=brightblack]·2#[default]" \
    "$(render_status_summary "%1${tab}working" "%2${tab}done")" \
    "a finished unpinned agent should not light the overflow count"

assert_eq "#[fg=magenta]·3#[default]" \
    "$(render_status_summary "%1${tab}done" "%2${tab}ask" "%3${tab}done")" \
    "the overflow count should take the ask colour when an unpinned agent is asking"

pin_set "%1" "bug"
pin_set "%2" "rfc"
pin_set "%3" "perf"

watchlist="$(render_status_summary \
    "%1${tab}working" "%2${tab}done" "%3${tab}ask" "%4${tab}working" "%5${tab}done")"
assert_eq \
"#[fg=yellow,bold]bug#[default]  #[fg=green]rfc✓#[default]  #[fg=magenta,bold]perf?#[default]   #[fg=brightblack]·2#[default]" \
    "$watchlist" "pinned agents should render as tags in pin order, with the rest counted"

assert_eq "$watchlist" "$(render_status_summary \
    "%1${tab}working" "%2${tab}done" "%3${tab}ask" "%4${tab}working" "%5${tab}done")" \
    "an unchanged watchlist should render identically on every call"

# %1 is still alive and waiting; %2 and %3 are gone. %2 finished before it
# vanished so its pin goes with it, while %3 was still asking, so its tag is
# held in dim grey until it is unpinned by hand.
assert_eq \
"#[fg=cyan]bug#[default]  #[fg=brightblack]perf#[default]" \
    "$(render_status_summary "%1${tab}wait")" \
    "a dead pin should be dropped when it finished and held dim otherwise"

assert_eq "bug	perf" "$(pins_read | cut -f1 | paste -sd '\t' -)" \
    "the store should keep only the pins that survived"

# The watchlist keeps pin order rather than re-sorting by state: where a tag
# sits is part of how it is read.
pin_set "%9" "zzz"
assert_eq \
"#[fg=cyan]bug#[default]  #[fg=brightblack]perf#[default]  #[fg=yellow,bold]zzz#[default]" \
    "$(render_status_summary "%1${tab}wait" "%9${tab}working")" \
    "a newly pinned agent should append rather than re-sort the watchlist"

# ── Theme colours ──────────────────────────────────────────────────
# Each state reads its colour from @agent-status-color-*, expanded as a tmux
# format at render time; an empty expansion falls back to the default.
pins_write < /dev/null

printf '%s\n' 'colour1|#ff0000|colour2|colour3|colour4' > "$TMUX_FAKE_COLORS"
pin_set "%1" "aa"
pin_set "%2" "bb"
pin_set "%3" "cc"
pin_set "%4" "dd"
pin_set "%5" "ee"
assert_eq \
"#[fg=colour1,bold]aa#[default]  #[fg=#ff0000,bold]bb?#[default]  #[fg=colour2]cc✓#[default]  #[fg=colour3]dd#[default]  #[fg=colour4]ee#[default]   #[fg=#ff0000]·1#[default]" \
    "$(render_status_summary "%1${tab}working" "%2${tab}ask" "%3${tab}done" "%4${tab}wait" "%6${tab}ask")" \
    "every state, the dead pin, and the lit overflow should take the configured colours"

printf '%s\n' '|colour9||colour3|' > "$TMUX_FAKE_COLORS"
assert_eq \
"#[fg=yellow,bold]aa#[default]  #[fg=colour9,bold]bb?#[default]  #[fg=green]cc✓#[default]  #[fg=colour3]dd#[default]  #[fg=brightblack]ee#[default]   #[fg=brightblack]·1#[default]" \
    "$(render_status_summary "%1${tab}working" "%2${tab}ask" "%3${tab}done" "%4${tab}wait" "%6${tab}working")" \
    "colours that expand to nothing should fall back to the defaults"
rm -f "$TMUX_FAKE_COLORS"

# The same lookup against a real, isolated tmux server proves that a colour
# given as a format ('#{@base0A}') is expanded, and an empty one falls back.
REAL_TMUX=$(PATH="${PATH#"$FAKE_BIN:"}" command -v tmux || true)
if [ -n "$REAL_TMUX" ]; then
    REAL_DIR="$(mktemp -d /tmp/tas-colors.XXXXXX)"
    cleanup_real() {
        (cd "$REAL_DIR" && "$REAL_TMUX" -S ./sock kill-server >/dev/null 2>&1) || true
        rm -rf "$REAL_DIR"
    }
    trap 'cleanup_real; rm -rf "$TMP_DIR"' EXIT
    cat > "$FAKE_BIN/tmux" <<TMUX_EOF
#!/usr/bin/env bash
cd "$REAL_DIR" || exit 1
exec "$REAL_TMUX" -S ./sock "\$@"
TMUX_EOF
    (
        export HOME="$REAL_DIR" TMUX_TMPDIR="$REAL_DIR"
        tmux -f /dev/null new-session -d -s colors 'sleep 60'
        tmux set-option -g @base0A colour214
        tmux set-option -g @agent-status-color-working '#{@base0A}'
        tmux set-option -g @agent-status-color-ask ''
        tmux set-option -g @agent-status-color-wait '#{@unset-theme-var}'
        pin_set "%1" "aa"
        pin_set "%2" "bb"
        pin_set "%4" "dd"
        assert_eq \
"#[fg=colour214,bold]aa#[default]  #[fg=magenta,bold]bb?#[default]  #[fg=cyan]dd#[default]" \
            "$(render_status_summary "%1${tab}working" "%2${tab}ask" "%4${tab}wait")" \
            "real tmux should expand format colours and fall back on empty ones"

        # A theme switch shows up on the next render without a restart.
        tmux set-option -g @base0A colour33
        assert_eq "#[fg=colour33,bold]aa#[default]  #[fg=magenta,bold]bb?#[default]  #[fg=cyan]dd#[default]" \
            "$(render_status_summary "%1${tab}working" "%2${tab}ask" "%4${tab}wait")" \
            "a changed theme variable should recolour the next render"
    )
fi

echo "status summary render checks passed"
